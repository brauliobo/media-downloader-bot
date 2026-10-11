require 'rails_helper'

RSpec.describe Audiobook, '.generate_uploads hashtags' do
  let(:text)   { 'A guia da filosofia hermética e dos princípios do universo. ' * 400 }
  let(:prompt) { [] }

  before do
    allow(Language).to receive(:book_metadata).and_return('lang' => 'pt', 'title' => 'Caibalion', 'author' => 'Iniciados', 'gender' => 'male')
    allow(AI::Codex).to receive(:json_prompt) { |text, **| prompt << text; %w[Hermetismo Filosofia Universo] }
  end

  def uploads(opts)
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'book.txt')
      File.write(source, text)
      described_class.generate_uploads(source, dir: dir, stl: nil, opts: SymMash.new(opts.merge(onlyyml: 1)))
    end
  end

  it 'puts the hashtags of the opening text, in the book language, in every upload info' do
    result = uploads(hashtags: 1)

    expect(result.map { |upload| upload.info.hashtags }).to all(eq('#Hermetismo #Filosofia #Universo'))
    expect(prompt.first).to include('Write every hashtag in pt.', 'filosofia hermética')
    expect(prompt.first.size).to be < described_class::HASHTAG_EXCERPT_CHARS + 2_000
  end

  it 'asks for hashtags in the caption language option when given' do
    uploads(hashtags: 1, clang: 'es')

    expect(prompt.first).to include('Write every hashtag in es.')
  end

  it 'generates nothing without the hashtags option' do
    result = uploads({})

    expect(result.map { |upload| upload.info.hashtags }).to all(be_nil)
    expect(AI::Codex).not_to have_received(:json_prompt)
  end
end
