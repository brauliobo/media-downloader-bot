require 'rails_helper'
require 'tmpdir'
require_relative '../support/replaying_manager'

RSpec.describe Replay::PostedYml do
  let(:job)  { Job.create(kind: 'replay', state: 'completed', parallel: 1, params: Sequel.pg_jsonb(chat_id: -200)) }
  let(:item) { JobItem.create(job_id: job.id, kind: 'replay', key: '-200:1', status: 'done') }

  around { |example| Job.db.transaction(rollback: :always, auto_savepoint: true) { example.run } }

  def post(message_id, kind) = item.record_messages(item.messages.map(&:values) + [{ chat_id: -200, message_id: message_id, kind: kind, failed: false }])

  it 'downloads the yml posted with the book' do
    post(1, 'Audio')
    post(2, 'Document')
    manager = ReplayingManager.new(files: { 2 => { name: 'book.yml', path: '/tmp/book.yml' } })

    expect(described_class.new(manager).path(item.refresh)).to eq('/tmp/book.yml')
  end

  it 'finds none when the documents posted are not a yml' do
    post(2, 'Document')
    manager = ReplayingManager.new(files: { 2 => { name: 'book.pdf', path: '/tmp/book.pdf' } })

    expect(described_class.new(manager).path(item.refresh)).to be_nil
  end
end
