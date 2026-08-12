require 'spec_helper'
require_relative '../../lib/processors/document'

RSpec.describe Processors::Document do
  def doc(file_name:, mime_type: nil)
    SymMash.new(file_name: file_name, mime_type: mime_type)
  end

  it 'recognizes plain text audiobook documents' do
    expect(described_class.document_kind(doc(file_name: 'book.txt', mime_type: 'text/plain'))).to eq(:txt)
    expect(described_class.txt_document?(doc(file_name: 'notes.TXT'))).to eq(true)
    expect(described_class.can_handle?(SymMash.new(document: doc(file_name: 'story.txt')))).to eq(true)
  end

  it 'still recognizes pdf epub and yaml documents' do
    expect(described_class.document_kind(doc(file_name: 'a.pdf'))).to eq(:pdf)
    expect(described_class.document_kind(doc(file_name: 'a.epub'))).to eq(:epub)
    expect(described_class.document_kind(doc(file_name: 'a.yml'))).to eq(:yaml)
  end

  it 'uses the shared audiobook upload flow for plain text documents' do
    Dir.mktmpdir do |dir|
      message = SymMash.new(document: doc(file_name: 'book.txt', mime_type: 'text/plain'))
      processor = described_class.new(Context.new(dir: dir, msg: message))
      input = SymMash.new(fn_in: File.join(dir, 'book.txt'), opts: SymMash.new)
      uploads = [SymMash.new(fn_out: File.join(dir, 'book.aac'))]

      expect(Audiobook).to receive(:generate_uploads).with(
        input.fn_in, dir: dir, stl: nil, opts: input.opts
      ).and_return(uploads)

      expect(processor.handle_input(input)).to equal(input)
      expect(input.uploads).to eq(uploads)
    end
  end
end
