require 'spec_helper'
require_relative '../../lib/processors/shorts'

RSpec.describe Processors::Shorts do
  let(:source_srt) do
    <<~SRT
      1
      00:00:01,000 --> 00:00:03,000
      First useful excerpt.

      2
      00:00:05,000 --> 00:00:07,000
      Outside excerpt.
    SRT
  end

  it 'carries Subtitle slices through cutting and renders VTT only at zipper options' do
    Dir.mktmpdir do |dir|
      source_path = File.join(dir, 'source.srt')
      video_path  = File.join(dir, 'video.mp4')
      output_path = File.join(dir, 'short.mp4')
      File.write(source_path, source_srt)
      File.write(video_path, '')
      processor = described_class.new(dir: dir)
      input = SymMash.new(
        fn_in:  video_path,
        durat:  8,
        format: SymMash.new(ext: 'mp4'),
        info:   SymMash.new(title: 'Original title', language: 'en'),
        opts:   SymMash.new(genshorts: source_path, slang: 'pt'),
        probe:  SymMash.new(format: SymMash.new(duration: 8))
      )
      cut = ::Shorts::Cut.new(start: '00:00:01', finish: '00:00:04', title: 'Planned title')
      expect(::Shorts).to receive(:generate_cuts) do |subtitle, language:|
        expect(subtitle).to be_a(Subtitler::Subtitle)
        expect(subtitle.entries.map(&:text)).to eq(['First useful excerpt.', 'Outside excerpt.'])
        expect(language).to eq('pt')
        [cut]
      end
      allow(Output).to receive(:filename).and_return(output_path)
      allow(Zipper).to receive(:choose_format).and_return(SymMash.new(ext: 'mp4'))
      captured_opts = nil
      allow(Zipper).to receive(:zip_video) do |*, opts:, **|
        captured_opts = opts
        [nil, nil, double(success?: true)]
      end
      expect(::Shorts).to receive(:generate_titles) do |subtitles, language:|
        expect(language).to eq('pt')
        expect(subtitles.length).to eq(1)
        expect(subtitles.first).to be_a(Subtitler::Subtitle)
        expect(subtitles.first.entries.first).to have_attributes(start: 0.0, finish: 2.0, text: 'First useful excerpt.')
        ['Regenerated title']
      end

      processor.generate_and_upload_shorts(input)

      expect(captured_opts.sub_vtt).to include('WEBVTT', 'First useful excerpt.')
      expect(captured_opts.sub_vtt).not_to include('Outside excerpt.')
      expect(input.opts).not_to have_key(:_vtt_slices)
      expect(input.uploads.map(&:caption)).to eq(['Regenerated title'])
    end
  end

  it 'builds typed cuts for the fallback plan' do
    Dir.mktmpdir do |dir|
      source_path = File.join(dir, 'source.srt')
      File.write(source_path, source_srt)
      processor = described_class.new(dir: dir)
      input = SymMash.new(
        fn_in:  File.join(dir, 'video.mp4'),
        durat:  61,
        format: SymMash.new(ext: 'mp4'),
        info:   SymMash.new(title: 'Original title'),
        opts:   SymMash.new(genshorts: source_path),
        probe:  SymMash.new(format: SymMash.new(duration: 61))
      )
      allow(::Shorts).to receive(:generate_cuts).and_return([])
      cuts = []
      allow(processor).to receive(:process_cut) do |_input, cut, _index, _language, subtitle|
        cuts << cut
        expect(subtitle).to be_a(Subtitler::Subtitle)
        nil
      end

      processor.generate_and_upload_shorts(input)

      expect(cuts).to all(be_a(::Shorts::Cut))
      expect(cuts.map { |cut| [cut.start, cut.finish, cut.title] }).to eq([
        ['00:00:00', '00:01:00', 'Short 1'],
        ['00:01:00', '00:01:01', 'Short 2'],
      ])
    end
  end
end
