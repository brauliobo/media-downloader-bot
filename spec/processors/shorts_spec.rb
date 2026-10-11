require 'rails_helper'
require_relative '../support/media_files'

RSpec.describe Processors::Shorts do
  include MediaFiles

  let(:dir) { Dir.mktmpdir('shorts-spec-') }
  let(:processor) { described_class.new(dir: dir) }
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

  def input(seconds:, **opts)
    srt = File.join(dir, 'source.srt').tap { |path| File.write(path, source_srt) }
    video = media_file(File.join(dir, 'video.mp4'), seconds: seconds)
    SymMash.new(
      fn_in: video, durat: seconds, format: SymMash.new(ext: 'mp4'), info: SymMash.new(title: 'Original title', language: 'en'),
      opts: SymMash.new(genshorts: srt, **opts), probe: Prober.for(video)
    )
  end

  def duration_of(path) = Prober.for(path).format.duration.to_f

  after { FileUtils.remove_entry(dir) }

  # the language model plans the cuts and writes the titles
  def fake_planner(cuts: [], titles: [])
    asked = {}
    allow(::Shorts).to receive(:generate_cuts) { |subtitle, language:| asked.merge!(plan: subtitle, plan_language: language); cuts }
    allow(::Shorts).to receive(:generate_titles) { |subtitles, language:| asked.merge!(titled: subtitles, title_language: language); titles }
    asked
  end

  it 'carries Subtitle slices through cutting and renders VTT only at zipper options' do
    i     = input(seconds: 8, slang: 'pt')
    cut   = ::Shorts::Cut.new(start: '00:00:01', finish: '00:00:04', title: 'Planned title')
    asked = fake_planner(cuts: [cut], titles: ['Regenerated title'])

    processor.generate_and_upload_shorts(i)

    expect(asked[:plan]).to be_a(Subtitler::Subtitle)
    expect(asked[:plan].entries.map(&:text)).to eq(['First useful excerpt.', 'Outside excerpt.'])
    expect([asked[:plan_language], asked[:title_language]]).to eq(%w[pt pt])
    expect(asked[:titled].length).to eq(1)
    expect(asked[:titled].first.entries.first).to have_attributes(start: 0.0, finish: 2.0, text: 'First useful excerpt.')
    expect(i.opts).not_to have_key(:_vtt_slices)
    expect(i.uploads.map(&:caption)).to eq(['Regenerated title'])
    expect(i.uploads.first.opts.sub_vtt).to include('WEBVTT', 'First useful excerpt.')
    expect(i.uploads.first.opts.sub_vtt).not_to include('Outside excerpt.')
    expect(duration_of(i.uploads.first.fn_out)).to be_within(0.5).of(3)
  end

  it 'cuts the video into one short per minute for the fallback plan' do
    i = input(seconds: 61)
    fake_planner

    processor.generate_and_upload_shorts(i)

    expect(i.uploads.map(&:caption)).to eq(['Short 1', 'Short 2'])
    expect(i.uploads.map { |upload| duration_of(upload.fn_out).round }).to eq([60, 1])
  end
end
