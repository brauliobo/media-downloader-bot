require 'rails_helper'
require_relative '../support/media_files'

RSpec.describe Processors::Media do
  include MediaFiles

  let(:dir)       { Dir.mktmpdir('media-spec-') }
  let(:ctx)       { Context.new(dir: dir, opts: SymMash.new) }
  let(:processor) { described_class.new(ctx) }
  let(:updates)   { [] }
  let(:status)    { Bot::Status.new { |text| updates << text } }
  let(:stl)       { Bot::Status::Line.new('', prefix: 't', status: status) }

  def input(**attrs)
    SymMash.new(opts: SymMash.new, info: SymMash.new, stl: stl, **attrs)
  end

  def duration_of(path) = Prober.for(path).format.duration.to_f

  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

  describe '#download' do
    # Telegram: hands over the file the message announces
    let(:telegram) do
      source = media_file(File.join(dir, 'remote.mp4'))
      Class.new do
        define_method(:download_file) { |info, dir:| FileUtils.cp(source, File.join(dir, info.file_name)).then { File.join(dir, info.file_name) } }
      end.new
    end

    it 'stores remote input separately from the output directory' do
      info      = SymMash.new(file_name: 'video.mp4')
      processor = Processors::Video.new(Context.new(dir: dir, service: telegram))
      processor.ctx.msg = SymMash.new(video: info)

      downloaded = processor.download
      output = Output.filename(downloaded.info, dir: dir, ext: :mp4)

      expect(downloaded.fn_in).to eq(File.join(processor.tmp, 'video.mp4'))
      expect(File.exist?(downloaded.fn_in)).to be true
      expect(File.expand_path(downloaded.fn_in)).not_to eq(File.expand_path(output))
    end
  end

  describe '#handle_input' do
    it 'marks the line in error when probe leaves type unset' do
      i = input(fn_in: '')
      processor.handle_input(i)
      expect(stl.error?).to be true
      expect(stl.to_s).to include('Unknown type')
    end

    it 'raises when input is missing' do
      expect { processor.handle_input(nil) }.to raise_error(/no input provided/)
    end

    it 'raises when ffprobe can not read the file' do
      file = File.join(dir, 'fake.mp4')
      File.write(file, '')

      expect { processor.handle_input(input(fn_in: file)) }.to raise_error(Sh::Error, /ffprobe failed/)
    end
  end

  describe '.probe' do
    def probed(opts, seconds:, ext: 'mp3')
      input(fn_in: media_file(File.join(dir, "in.#{ext}"), seconds: seconds), opts: SymMash.new(opts)).tap { described_class.probe(_1) }
    end

    it 'takes the type and duration from the file' do
      expect(probed({}, seconds: 2).then { [_1.type.name, _1.durat.round] }).to eq([:audio, 2])
      expect(probed({}, seconds: 1, ext: 'mp4').type.name).to eq(:video)
    end

    it 'subtracts cuts from the projected media duration' do
      expect(probed({cuts: '10-20,30-35'}, seconds: 60).durat).to be_within(0.5).of(45.0)
    end

    it 'uses ss and to as an absolute clip window' do
      expect(probed({ss: '10s', to: '20'}, seconds: 60).durat).to eq(10.0)
    end

    it 'uses ss and t as a duration window' do
      expect(probed({ss: '1m', t: '30s'}, seconds: 120).durat).to eq(30.0)
    end
  end

  describe '#generate_hashtags' do
    let(:transcript) { Subtitler::Subtitle.new(language: 'en', text: 'Mindfulness and health.') }

    # the whisper service and the language model, which answer with the hashtag language they were asked for
    before do
      allow(Subtitler).to receive(:transcribe).and_return(transcript)
      allow(Hashtags).to receive(:generate) { |_transcript, lang:| "##{lang}" }
    end

    def hashtags_for(opts)
      input(fn_in: '/tmp/in.mp4', opts: SymMash.new(hashtags: 1, **opts)).tap { processor.generate_hashtags(_1) }.info.hashtags
    end

    it 'transcribes the input and uses an explicit language for hashtags' do
      expect(hashtags_for(slang: 'pt')).to eq('#pt')
    end

    it 'uses lang= as the hashtag language' do
      opts = SymMash.new(hashtags: 1, lang: 'pt')
      Processors::Base.normalize_options(opts)
      i = input(fn_in: '/tmp/in.mp4', opts: opts)

      processor.generate_hashtags(i)

      expect(i.info.hashtags).to eq('#pt')
    end

    it 'uses the dub language when slang is unset' do
      expect(hashtags_for(dub: 1, dub_lang: 'pt')).to eq('#pt')
    end

    it 'prefers caption language over dub language' do
      expect(hashtags_for(dub: 1, dub_lang: 'pt', clang: 'es')).to eq('#es')
    end

    it 'falls back to the transcript language' do
      expect(hashtags_for({})).to eq('#en')
    end
  end

  describe '#handle_input size limits' do
    let(:i) { input(fn_in: media_file(File.join(dir, 'in.mp4')), info: SymMash.new(title: 't', _filename: 'f.mp4')) }

    # a limit of 0MB is smaller than anything that gets encoded
    before { Zipper.size_mb_limit = 0 }
    after  { Zipper.size_mb_limit = nil }

    it 'marks the line with VID_TOO_BIG instead of raising' do
      processor.handle_input(i)
      expect(stl.error?).to be true
      expect(stl.to_s).to include('Video over')
    end

    it 'marks the line with TOO_BIG for audio' do
      i.fn_in = media_file(File.join(dir, 'in.mp3'))
      i.opts.audio = 1
      processor.handle_input(i)
      expect(stl.error?).to be true
      expect(stl.to_s).to include('File over')
    end
  end

  describe '#handle_input streaming' do
    let(:source) { media_file(File.join(dir, 'in.mp4')) }
    let(:i)      { input(fn_in: source, stream: '135+140', info: SymMash.new(title: 't', _filename: 'f.mp4')) }

    before { Zipper.size_mb_limit = 50 }
    after  { Zipper.size_mb_limit = nil }

    it 'uploads the downloaded file without transcoding' do
      original = File.binread(source)

      processor.handle_input(i)

      expect(File.binread(i.fn_out)).to eq(original)
      expect(File.dirname(i.fn_out)).to eq(File.expand_path(dir))
      expect(i.mime).to eq('video/mp4')
      expect(updates.join).not_to include('transcoding')
    end

    it 'uploads a downloaded audio track without transcoding' do
      audio = media_file(File.join(dir, 'in.m4a'))
      track = input(fn_in: audio, stream: '140', info: SymMash.new(title: 't', _filename: 'f.m4a'))
      original = File.binread(audio)

      processor.handle_input(track)

      expect(File.extname(track.fn_out)).to eq('.m4a')
      expect(File.binread(track.fn_out)).to eq(original)
      expect(track.mime).to eq('audio/aac')
      expect(updates.join).not_to include('transcoding')
    end

    it 'transcodes when the download does not fit the limit' do
      Zipper.size_mb_limit = 0

      processor.handle_input(i)

      expect(updates.join).to include('transcoding')
      expect(File.exist?(i.fn_out)).to be true
      expect(File.binread(i.fn_out)).not_to eq(File.binread(source))
    end
  end

  describe '#convert' do
    let(:source) { media_file(File.join(dir, 'in.mp4')) }
    let(:i) do
      input(
        fn_in: source,
        type:  Zipper::Types.video,
        durat: 1,
        info:  SymMash.new(title: 't', uploader: 'u', _filename: 'f.mp4'),
      ).tap { |x| x.probe = Prober.for(source) }
    end

    it 'marks the line in error when no format is chosen' do
      i.type = SymMash.new(name: :document)
      processor.convert(i)
      expect(stl.error?).to be true
      expect(stl.to_s).to include('Unsupported format')
    end

    it 'converts the file into the output directory' do
      i.opts.format = 'h264'

      out = processor.convert(i)

      expect(out).to eq(File.join(dir, 't by u.mp4'))
      expect(File.exist?(out)).to be true
      expect(stl.error?).to be_falsey
    end

    it 'marks the line in error when the zipper command fails' do
      i.opts.format = 'h264'
      i.opts.vf     = 'no_such_filter'

      processor.convert(i)

      expect(stl.error?).to be true
      expect(stl.to_s).to include('convert failed')
    end

    it 'applies camera defaults before choosing the video format' do
      i.opts = SymMash.new(camera: 1)

      processor.convert(i)

      expect(i.opts.cudaenc).to be_truthy
      expect(i.opts.format.mime).to eq('video/mp4')
      expect(i.opts.quality.to_i).to eq(32)
      expect(i.opts.acodec).to eq('aac')
    end

    # the whisper service, which hears the file and answers with what was said
    describe 'when transcribing subtitles' do
      before do
        srt = "1\n00:00:00,000 --> 00:00:01,000\nOlá.\n"
        allow(Subtitler).to receive(:transcribe).and_return(Subtitler::Subtitle.from_srt(srt).tap { |s| s.instance_variable_set(:@language, 'pt') })
      end

      it 'zips the original file' do
        i.opts = SymMash.new(gensubs: 1, slang: 'pt', format: 'h264')

        out = processor.convert(i)

        expect(File.exist?(out)).to be true
        expect(duration_of(out)).to be_within(0.3).of(1)
      end
    end

    # the dubbing pipeline calls out to the TTS and translation services; it hands back a dubbed video
    describe 'when dubbing' do
      let(:dubbed) { media_file(File.join(dir, 'dubbed.mp4'), seconds: 2) }
      let(:dub)    { SymMash.new(dub: 1, dub_lang: 'pt', sub_mode: 'language', sub_lang: 'pt', format: 'h264') }

      it 'dubs video inputs before the normal zipper conversion' do
        i.opts = dub
        allow(Dubbing::Pipeline).to receive(:apply) { |_, opts:, **| dubbed.tap { opts.sub_vtt = "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nOlá.\n" } }

        out = processor.convert(i)

        expect(i.opts.sub_vtt).to include('Olá.')
        expect(duration_of(out)).to be_within(0.3).of(2)
      end

      it 'does not dub audio inputs' do
        i.type   = Zipper::Types.audio
        i.fn_in  = media_file(File.join(dir, 'in.mp3'))
        i.opts   = SymMash.new(dub: 1, format: 'mp3')
        allow(Dubbing::Pipeline).to receive(:apply)

        out = processor.convert(i)

        expect(Dubbing::Pipeline).not_to have_received(:apply)
        expect(File.extname(out)).to eq('.mp3')
      end
    end
  end
end
