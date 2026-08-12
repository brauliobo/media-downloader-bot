require 'spec_helper'

RSpec.describe Audiobook::SourceFormats do
  describe '.document_kind' do
    it 'classifies supported audiobook document extensions' do
      expect(described_class.document_kind(file_name: 'book.pdf')).to eq(:pdf)
      expect(described_class.document_kind(file_name: 'book.epub')).to eq(:epub)
      expect(described_class.document_kind(file_name: 'book.yaml')).to eq(:yaml)
      expect(described_class.document_kind(file_name: 'book.TXT')).to eq(:txt)
    end

    it 'does not treat another named text format as a TXT audiobook' do
      expect(described_class.document_kind(file_name: 'notes.md', mime_type: 'text/plain')).to be_nil
    end

    it 'uses MIME type only when the filename is absent' do
      expect(described_class.document_kind(file_name: '', mime_type: 'text/plain')).to eq(:txt)
    end

    it 'keeps reliable MIME classification for generically named documents' do
      expect(described_class.document_kind(file_name: 'download', mime_type: 'application/pdf')).to eq(:pdf)
    end
  end

  describe '.yaml_path' do
    it 'replaces registered source extensions' do
      expect(described_class.yaml_path('/tmp/book.txt', '/output/audio.aac')).to eq('/tmp/book.yml')
    end

    it 'keeps YAML input immutable by writing beside the audio output' do
      expect(described_class.yaml_path('/tmp/book.yaml', '/output/audio.aac')).to eq('/output/audio.yml')
    end
  end
end
