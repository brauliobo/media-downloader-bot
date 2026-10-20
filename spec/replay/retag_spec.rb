require 'rails_helper'
require 'tmpdir'

RSpec.describe Replay::Retag do
  let(:dir)     { Dir.mktmpdir }
  let(:item)    { instance_double(JobItem) }
  let(:path)    { File.join(dir, 'book.yml') }
  let(:manager) { instance_double(Manager::Service) }
  let(:page)    { { 'page' => { 'number' => 1, 'items' => [{ 'paragraph' => { 'sentences' => [{ 'text' => 'A filosofia hermética.' }] } }] } } }

  before do
    File.write(path, { 'language' => 'pt', 'pages' => [page] }.to_yaml)
    allow(Replay::PostedYml).to receive(:new).with(manager).and_return(instance_double(Replay::PostedYml, path: path))
  end

  after { FileUtils.remove_entry(dir) }

  it 'generates the hashtags from the yml posted with the book' do
    allow(AI::ClaudeProxy).to receive(:json_prompt).and_return(%w[Hermetismo Filosofia Universo])

    expect(described_class.new(manager).call(item)).to eq('#Hermetismo #Filosofia #Universo')
  end

  it 'raises why they could not be generated' do
    allow(AI::ClaudeProxy).to receive(:json_prompt).and_raise(JSON::ParserError, 'the model refused')

    expect { described_class.new(manager).call(item) }.to raise_error(JSON::ParserError)
  end

  it 'raises when no yml was posted with the book' do
    allow(Replay::PostedYml).to receive(:new).with(manager).and_return(instance_double(Replay::PostedYml, path: nil))

    expect { described_class.new(manager).call(item) }.to raise_error('no yml was posted with the book')
  end

  it 'raises when nothing came out of the book' do
    allow(AI::ClaudeProxy).to receive(:json_prompt).and_return([])

    expect { described_class.new(manager).call(item) }.to raise_error('no hashtags came out of the book')
  end
end
