require 'rails_helper'
require 'tmpdir'
require_relative '../support/forwarding_bot'

RSpec.describe Forwarding::CLI do
  let(:dir)    { Dir.mktmpdir }
  let(:log)    { Forwarding::Log.new(path: File.join(dir, 'forwarded.jsonl')) }
  let(:output) { StringIO.new }
  let(:chats)  { [{ id: -100, title: 'Source Group' }, { id: -200, title: 'Biblioteca' }, { id: -300, title: 'Biblioteca Velha' }] }
  let(:topics) { [{ id: 7, name: 'Book_Section' }] }
  let(:bot)    { ForwardingBot.new(message_ids: [1, 2], chats: chats, topics: topics) }

  after { FileUtils.remove_entry(dir) }

  def cli(*argv) = described_class.new(argv, manager: bot, output: output, log: log)

  it 'resolves chats and topics by name and forwards with the caption' do
    state = cli('source=Source Group', 'source_topic=book_section', 'target=biblioteca', 'caption=lang=pt', 'leave=1').run

    expect(state).to include(sent: 2, left: true)
    expect(bot.copied).to all(include(to: -200, topic: nil, caption: 'lang=pt'))
    expect(bot.left).to eq([-100])
    expect(output.string).to include('Source Group (-100)', 'sent=2 skipped=0 errors=0 total=2')
  end

  it 'accepts ids and only plans with plan=1' do
    state = cli('source=-100', 'target=-200', 'plan=1').run

    expect(state).to include(total: 2, sent: 0)
    expect(bot.copied).to be_empty
  end

  it 'aborts on an unknown or ambiguous chat' do
    expect { cli('source=nope', 'target=-200').run }.to raise_error(SystemExit)
    expect { cli('source=Source', 'target=Biblio').run }.to raise_error(SystemExit)
  end

  it 'aborts on an unknown topic' do
    expect { cli('source=Source Group', 'source_topic=nope', 'target=-200').run }.to raise_error(SystemExit)
  end
end
