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

  it 'converts generated VTT to SRT through FFmpeg' do
    ffmpeg = instance_double FFmpeg
    info   = SymMash.new title: 'Example'
    opts   = SymMash.new onlysrt: true, nowords: false
    allow(described_class).to receive(:prepare_subtitle)
      .and_return ["WEBVTT\n\n<00:00:00.100>Hello", 'en', nil]
    expect(ffmpeg).to receive(:convert_subtitle).with(
      input: File.join(dir, 'sub.vtt'), format: :srt, label: 'srt conversion failed'
    ).and_return "1\n00:00:00,000 --> 00:00:01,000\nHello\n"

    output = described_class.generate_srt(
      'video.mp4', dir: dir, info: info, probe: nil, stl: nil, opts: opts, ffmpeg: ffmpeg
    )

    expect(output).to eq File.join(dir, 'Example.srt')
    expect(File.binread(output).bytes).to start_with 0xEF, 0xBB, 0xBF, 0x31, 0x0A
  end

  it 'preserves SRT conversion errors' do
    ffmpeg = instance_double FFmpeg
    info   = SymMash.new title: 'Example'
    opts   = SymMash.new onlysrt: true
    allow(described_class).to receive(:prepare_subtitle)
      .and_return ["WEBVTT\n\nInvalid", 'en', nil]
    allow(ffmpeg).to receive(:convert_subtitle)
      .and_raise Sh::Error.new('srt conversion failed', 'invalid subtitle')

    expect {
      described_class.generate_srt(
        'video.mp4', dir: dir, info: info, probe: nil, stl: nil, opts: opts, ffmpeg: ffmpeg
      )
    }.to raise_error Sh::Error, 'srt conversion failed: invalid subtitle'
  end

  it 'uses an authored locale variant without translating a base-language request' do
    vtt  = "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nOlá.\n"
    info = SymMash.new(subtitles: {
      en:      [{ext: 'vtt', url: 'https://example.com/en.vtt'}],
      :'pt-BR' => [{ext: 'vtt', url: 'https://example.com/pt-BR.vtt'}],
    })
    opts = SymMash.new(slang: 'pt', format: Zipper::Types.video.h264)
    ffmpeg = instance_double(FFmpeg)
    zipper = Zipper.new(
      'video.mp4', nil, info: info,
      probe: SymMash.new(format: {duration: 1}, streams: []), opts: opts, ffmpeg: ffmpeg
    )
    allow(Utils::HTTP).to receive(:get_public).with('https://example.com/pt-BR.vtt').and_return(vtt)
    allow(ffmpeg).to receive(:convert_subtitle).and_return(vtt)
    expect(Subtitler::VTT).not_to receive(:translate)

    fetched, lang, = described_class.prepare(zipper, translate_to: 'pt')

    expect(fetched).to include('Olá.')
    expect(lang).to eq('pt')
  end

  it 'keeps generated dubbing subtitles authoritative during final selection' do
    generated = "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nDublado.\n"
    opts      = SymMash.new(sub_vtt: generated, sub_mode: 'language', sub_lang: 'pt')
    zipper    = instance_double(Zipper, opts: opts)
    expect(Utils::HTTP).not_to receive(:get_public)

    selected, lang, = described_class.send(:source_vtt, zipper, translate_to: 'pt')

    expect(selected).to include('Dublado.')
    expect(lang).to eq('pt')
  end
end
