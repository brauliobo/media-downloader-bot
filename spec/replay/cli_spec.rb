require 'rails_helper'
require 'tmpdir'
require_relative '../support/replaying_manager'

RSpec.describe Replay::CLI do
  let(:dir)       { Dir.mktmpdir }
  let(:log)       { Replay::Log.new(path: File.join(dir, 'replayed.jsonl')) }
  let(:forwarded) { Forwarding::Log.new(path: File.join(dir, 'forwarded.jsonl')) }
  let(:output)    { StringIO.new }
  let(:manager)   { ReplayingManager.new(chats: [{ id: -200, title: 'Biblioteca' }]) }

  before { [1, 2].each { |id| forwarded.record({ chat_id: -100 }, { chat_id: -200 }, id, 10 + id) } }

  after { FileUtils.remove_entry(dir) }

  def cli(*argv) = described_class.new(argv, manager: manager, output: output, log: log, forwarded: forwarded)

  it 'resolves the chat by name and replays its forwarded messages' do
    state = cli('chat=biblio', 'parallel=1').run

    expect(state).to include(replayed: 2, errors: [])
    expect(manager.replayed).to eq([{ chat_id: -200, id: 11 }, { chat_id: -200, id: 12 }])
    expect(output.string).to include('Biblioteca (-200)', 'replayed=2 skipped=0 running=0 errors=0 total=2')
  end

  it 'only plans with plan=1' do
    state = cli('chat=-200', 'plan=1').run

    expect(state).to include(total: 2, replayed: 0)
    expect(manager.replayed).to be_empty
  end

  it 'aborts without a chat or with an unknown one' do
    expect { cli.run }.to raise_error(SystemExit)
    expect { cli('chat=nope').run }.to raise_error(SystemExit)
  end
end
