require 'rails_helper'
require 'tmpdir'
require_relative '../support/replaying_manager'

RSpec.describe Replay::LangCheck do
  let(:dir)     { Dir.mktmpdir }
  let(:yml)     { File.join(dir, 'book.yml').tap { |path| File.write(path, { 'metadata' => { 'language' => 'en' }, 'pages' => [] }.to_yaml) } }
  let(:files)   { [501, 503, 504].to_h { |id| [id, { name: 'book.yml', path: yml }] }.merge(502 => { name: 'book.pdf', path: yml }) }
  let(:manager) { ReplayingManager.new(files: files) }
  let(:job)     { Job.create(kind: 'replay', state: 'completed', parallel: 1, params: Sequel.pg_jsonb(chat_id: -200)) }

  before { ChatSetting.update_settings(-200, options: 'lang=pt hashtags') }

  after do
    Job.dataset.delete
    ChatSetting.where(chat_id: -200).delete
    FileUtils.remove_entry(dir)
  end

  def item(key, message_id, result: {})
    JobItem.create(job_id: job.id, kind: 'replay', key: "-200:#{key}", status: 'done', result: Sequel.pg_jsonb(result)).tap do |item|
      item.record_messages([{ chat_id: -200, message_id: message_id, kind: 'Document', failed: false }])
    end
  end

  it 'fills the language the book yml says in the books read without one and flags the ones that differ from the group' do
    missing = item(1, 501)

    expect(described_class.new(manager).call(job)).to eq(1)
    expect(missing.refresh.outcome).to include(input: { inputs: [{ opts: { lang: 'en' } }] }, lang_check: { lang: 'en', expected: 'pt', mismatch: true })
  end

  it 'adds the language to the options typed in the message and leaves the books that already have one alone' do
    typed  = item(1, 501, result: { input: { inputs: [{ opts: { hashtags: 1 } }] } })
    chat   = item(2, 503, result: { options: 'lang=pt hashtags' })
    inline = item(3, 504, result: { input: { inputs: [{ opts: { lang: 'pt' } }] } })

    expect(described_class.new(manager).call(job)).to eq(1)
    expect(typed.refresh.outcome[:input][:inputs]).to eq([{ opts: { hashtags: 1, lang: 'en' } }])
    expect([chat, inline].map { |other| other.refresh.outcome.key?(:lang_check) }).to eq([false, false])
  end

  it 'leaves a book without a yml for another check' do
    pdf_only = item(1, 502)

    expect(described_class.new(manager).call(job)).to eq(0)
    expect(pdf_only.refresh.outcome).not_to have_key(:lang_check)
  end
end
