require 'spec_helper'

RSpec.describe Zipper::Subtitle do
  let(:dir) { Dir.mktmpdir 'subtitle-spec-' }

  after { FileUtils.remove_entry dir if Dir.exist? dir }

  it 'sanitizes ASS filename prefix to avoid ffmpeg filter graph separators' do
    prefix = "1 Detox Expert Reviews Paul Saladino's $3,000 Blood Wash (Inuspheresis)"
    safe = described_class.send(:safe_ass_prefix, prefix)

    expect(safe).to match(/\A[0-9A-Za-z_]+\z/)
    expect(safe).not_to include(',', "'", '$')
    expect(safe).not_to be_empty
  end

  it 'renders external VTT to SRT directly through the subtitle model' do
    ffmpeg = instance_double FFmpeg
    info   = SymMash.new title: 'Example'
    opts   = SymMash.new onlysrt: true, nowords: false
    allow(described_class).to receive(:prepare_subtitle)
      .and_return Subtitler::Subtitle.from_vtt(
        "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n<00:00:00.100>Hello\n"
      ).replace_language!('en')
    expect(ffmpeg).not_to receive(:convert_subtitle)

    output = described_class.generate_srt(
      'video.mp4', dir: dir, info: info, probe: nil, stl: nil, opts: opts, ffmpeg: ffmpeg
    )

    expect(output).to eq File.join(dir, 'Example.srt')
    expect(File.binread(output).bytes).to start_with 0xEF, 0xBB, 0xBF, 0x31, 0x0A
  end

  it 'preserves external VTT parse errors' do
    ffmpeg = instance_double FFmpeg
    info   = SymMash.new title: 'Example'
    opts   = SymMash.new onlysrt: true
    probe  = SymMash.new(format: {duration: 1}, streams: [])
    opts.sub_vtt = "WEBVTT\n\n00:00:02.000 --> 00:00:01.000\nInvalid\n"

    expect {
      described_class.generate_srt(
        'video.mp4', dir: dir, info: info, probe: probe, stl: nil, opts: opts, ffmpeg: ffmpeg
      )
    }.to raise_error ArgumentError, 'invalid WEBVTT cue range'
  end

  it 'keeps generated transcription as the subtitle model' do
    subtitle = Subtitler::Subtitle.new(
      language: 'en', text: 'Hello.',
      entries: [Subtitler::Subtitle::Entry.new(text: 'Hello.', start: 0.0, finish: 1.0)]
    )
    zipper = instance_double(
      Zipper,
      infile: 'video.mp4',
      opts: SymMash.new(gensubs: true, nowords: false),
      stl: nil,
      info: SymMash.new
    )
    allow(Subtitler).to receive(:transcribe).with('video.mp4').and_return(subtitle)

    structured = described_class.prepare(zipper)

    expect(structured).to equal(subtitle)
    expect(structured).to have_attributes(language: 'en', text: 'Hello.')
  end

  it 'prefers exact and base-matching authored locales without translating them' do
    vtt    = "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nOlá.\n"
    ffmpeg = instance_double(FFmpeg)
    allow(ffmpeg).to receive(:convert_subtitle).and_return(vtt)
    expect(Subtitler::VTT).not_to receive(:translate)

    [
      ['pt-PT', [:en, :'pt-BR'], :'pt-BR'],
      ['PT_pt', [:en, :'pt-BR'], :'pt-BR'],
      ['pt-PT', [:en, :'pt-BR', :'pt-PT'], :'pt-PT'],
    ].each do |requested, keys, expected|
      subtitles = keys.to_h { |key| [key, [{ext: 'vtt', url: "https://example.com/#{key}.vtt"}]] }
      info       = SymMash.new(subtitles: subtitles)
      opts       = SymMash.new(sub: requested, lang: 'en', format: Zipper::Types.video.h264)
      Processors::Base.normalize_options(opts)
      allow(Utils::HTTP).to receive(:get_public).with("https://example.com/#{expected}.vtt").and_return(vtt)
      zipper = Zipper.new(
        'video.mp4', nil, info: info,
        probe: SymMash.new(format: {duration: 1}, streams: []), opts: opts, ffmpeg: ffmpeg
      )

      fetched = described_class.prepare(
        zipper, translate_to: described_class.subtitle_translation_target(opts)
      )

      expect(fetched).to have_attributes(language: 'pt', text: 'Olá.')
    end
  end

  it 'keeps generated dubbing subtitles authoritative during final selection' do
    generated = "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nDublado.\n"
    opts      = SymMash.new(sub_vtt: generated, sub_mode: 'language', sub_lang: 'pt')
    zipper    = instance_double(Zipper, opts: opts)
    expect(Utils::HTTP).not_to receive(:get_public)

    selected = described_class.prepare(zipper, translate_to: 'pt')

    expect(selected).to have_attributes(language: 'pt', text: 'Dublado.')
  end

  it 'selects embedded subtitles using the standalone subtitle language' do
    opts = SymMash.new(sub: 'pt', format: Zipper::Types.video.h264)
    Processors::Base.normalize_options(opts)
    probe = SymMash.new(
      format: {duration: 1},
      streams: [
        SymMash.new(codec_type: 'subtitle', tags: {language: 'en'}),
        SymMash.new(codec_type: 'subtitle', tags: {language: 'pt'}),
      ]
    )
    zipper = Zipper.new('video.mkv', nil, info: SymMash.new, probe: probe, opts: opts)
    allow(Subtitler::VTT).to receive(:extract_embedded).and_return(
      "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nOlá.\n"
    )

    subtitle = described_class.send(:fetch_embedded, zipper)

    expect(subtitle).to have_attributes(language: 'pt', text: 'Olá.')
    expect(Subtitler::VTT).to have_received(:extract_embedded).with(zipper, 1, ffmpeg: anything)
  end
end
