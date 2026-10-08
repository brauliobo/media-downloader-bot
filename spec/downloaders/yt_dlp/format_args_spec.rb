require 'rails_helper'

RSpec.describe Downloaders::YtDlp::FormatArgs do
  let(:opts) { SymMash.new }
  let(:url)  { 'https://example.com/v' }
  let(:args) { described_class.new(opts, url) }

  describe '#for' do
    it 'fetches the picked format as an mp4 that starts playing early when streaming' do
      expect(args.for('135+140')).to eq(
        "-f 135+140 --merge-output-format mp4 --postprocessor-args #{Sh.escape(described_class::FASTSTART)}"
      )
    end

    it 'fetches the best format when encoding' do
      expect(args.for(nil)).to eq("-f #{Sh.escape('bestvideo+bestaudio/best')}")
    end
  end

  describe '#encoded' do
    it 'extracts audio for audio requests' do
      opts.audio = 1
      expect(args.encoded).to eq("-f #{Sh.escape('bestaudio/best')} -x")
    end

    it 'prefers the requested audio language' do
      opts.alang = 'pt'
      expect(args.encoded).to include(Sh.escape('bestvideo+bestaudio[language^=pt]'))
    end

    it 'asks bandcamp for its mp3' do
      opts.audio = 1
      expect(described_class.new(opts, 'https://x.bandcamp.com/track/y').encoded).to eq("-f mp3-320 -x")
    end
  end
end
