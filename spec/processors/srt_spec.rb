require 'spec_helper'
require_relative '../../lib/processors/srt'

RSpec.describe Processors::Srt do
  it 'parses an uploaded SRT into Subtitle and renders the translated model' do
    Dir.mktmpdir do |dir|
      input_path = File.join(dir, 'captions.srt')
      File.write(input_path, "1\n00:00:01,000 --> 00:00:02,000\nHello world\n")
      processor = described_class.new(Context.new(dir: dir))
      input = SymMash.new(fn_in: input_path, opts: SymMash.new(slang: 'pt'))
      expect(Translator).to receive(:translate).with(['Hello world'], from: nil, to: 'pt').and_return(['Olá mundo'])

      result = processor.handle_input(input)

      expect(result).to equal(input)
      expect(input.fn_out).to eq(File.join(dir, 'captions.pt.srt'))
      expect(File.binread(input.fn_out).force_encoding(Encoding::UTF_8))
        .to eq("\uFEFF1\n00:00:01,000 --> 00:00:02,000\nOlá mundo\n")
    end
  end
end
