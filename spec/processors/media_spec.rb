require 'spec_helper'

RSpec.describe Processors::Media do
  let(:dir) { Dir.mktmpdir('media-spec-') }
  let(:ctx) { Context.new(dir: dir, opts: SymMash.new) }
  let(:processor) { described_class.new(ctx) }
  let(:status)    { Bot::Status.new { |_text| } }
  let(:stl)       { Bot::Status::Line.new('', prefix: 't', status: status) }

  def input(**attrs)
    SymMash.new(opts: SymMash.new, info: SymMash.new, stl: stl, **attrs)
  end

  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

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

    it 'raises when probe returns without a format section' do
      file = File.join(dir, 'fake.mp4')
      File.write(file, '')
      i = input(fn_in: file)
      allow(Prober).to receive(:for).and_return(SymMash.new(streams: []))

      expect { processor.handle_input(i) }.to raise_error(/probe missing format/)
    end
  end

  describe '#handle_input size limits' do
    let(:fixture) { File.join(dir, 'out.mp4') }
    let(:i) do
      f = File.join(dir, 'in.mp4')
      File.write(f, '')
      input(fn_in: f, info: SymMash.new(title: 't', _filename: 'f.mp4'))
    end

    before do
      Zipper.size_mb_limit = 50
      allow(Prober).to receive(:for).and_return(SymMash.new(format: SymMash.new(duration: 10), streams: [SymMash.new(codec_type: 'video')]))
      allow(Zipper).to receive(:choose_format).and_return(SymMash.new(ext: :mp4, mime: 'video/mp4'))
      ok = instance_double(Process::Status, success?: true)
      allow(Zipper).to receive(:zip_video).and_return(['', '', ok])
      File.write(fixture, '')
      allow(Output).to receive(:filename).and_return(fixture)
      allow(File).to receive(:size).and_call_original
      allow(File).to receive(:size).with(fixture).and_return(60 * 2**20)
      allow(processor).to receive(:tag)
    end
    after { Zipper.size_mb_limit = nil }

    it 'marks the line with VID_TOO_BIG instead of raising' do
      processor.handle_input(i)
      expect(stl.error?).to be true
      expect(stl.to_s).to include('Video over')
    end

    it 'marks the line with TOO_BIG for audio' do
      i.opts.audio = 1
      allow(Prober).to receive(:for).and_return(SymMash.new(format: SymMash.new(duration: 10), streams: [SymMash.new(codec_type: 'audio')]))
      allow(Zipper).to receive(:zip_audio).and_return(['', '', instance_double(Process::Status, success?: true)])
      processor.handle_input(i)
      expect(stl.error?).to be true
      expect(stl.to_s).to include('File over')
    end
  end

  describe '#convert' do
    let(:i) do
      input(
        fn_in: '/tmp/in.mp4',
        type:  SymMash.new(name: :video),
        durat: 60,
        info:  SymMash.new(title: 't', uploader: 'u', _filename: 'f.mp4'),
      ).tap { |x| x.opts.format = 'bogus_codec' }
    end

    it 'marks the line in error when no format is chosen' do
      allow(Zipper).to receive(:choose_format).and_return(nil)
      processor.convert(i)
      expect(stl.error?).to be true
      expect(stl.to_s).to include('Unsupported format')
    end

    it 'marks the line in error when the zipper command fails' do
      allow(Zipper).to receive(:choose_format).and_return(SymMash.new(ext: :mp4, mime: 'video/mp4'))
      bad_status = instance_double(Process::Status, success?: false)
      allow(Zipper).to receive(:zip_video).and_return(['out', 'a\nb\nc\nlast-err-line', bad_status])

      processor.convert(i)
      expect(stl.error?).to be true
      expect(stl.to_s).to include('convert failed')
      expect(stl.to_s).to include('last-err-line')
    end

    it 'applies camera defaults before choosing the video format' do
      i.opts = SymMash.new(camera: 1)
      allow(Zipper).to receive(:choose_format).and_return(SymMash.new(ext: :mp4, mime: 'video/mp4'))
      allow(Zipper).to receive(:zip_video).and_return(['', '', instance_double(Process::Status, success?: true)])
      allow(Output).to receive(:filename).and_return(File.join(dir, 'out.mp4'))

      processor.convert(i)

      expect(i.opts.cudaenc).to eq(1)
      expect(i.opts.format.mime).to eq('video/mp4')
      expect(i.opts.quality).to eq('32')
      expect(i.opts.acodec).to eq('aac')
      expect(i.opts.abrate).to eq('32')
    end

    it 'dubs video inputs before the normal zipper conversion' do
      i.opts = SymMash.new(dub: 1, slang: 'pt', alang: 'pt')
      dubbed = File.join(dir, 'dubbed.mp4')
      allow(Zipper).to receive(:choose_format).and_return(SymMash.new(ext: :mp4, mime: 'video/mp4'))
      allow(Dubbing::Pipeline).to receive(:apply).and_return(dubbed)
      allow(Zipper).to receive(:zip_video).and_return(['', '', instance_double(Process::Status, success?: true)])
      allow(Output).to receive(:filename).and_return(File.join(dir, 'out.mp4'))

      processor.convert(i)

      expect(Dubbing::Pipeline).to have_received(:apply).with('/tmp/in.mp4', dir: dir, opts: i.opts, stl: stl, probe: nil)
      expect(i.opts.slang).to be_nil
      expect(i.opts.alang).to be_nil
      expect(Zipper).to have_received(:zip_video).with(dubbed, File.join(dir, 'out.mp4'), opts: i.opts, probe: nil, stl: stl, info: i.info)
    end

    it 'keeps dub language options when subtitles were explicitly requested too' do
      opts = SymMash.new(dub: 1, slang: 'pt', alang: 'pt', subs: 1)

      processor.send(:consume_dub_language!, opts)

      expect(opts.slang).to eq('pt')
      expect(opts.alang).to eq('pt')
    end

    it 'does not dub audio inputs' do
      i.type = SymMash.new(name: :audio)
      i.opts = SymMash.new(dub: 1)
      allow(Dubbing::Pipeline).to receive(:apply)
      allow(Zipper).to receive(:choose_format).and_return(SymMash.new(ext: :mp3, mime: 'audio/mp3'))
      allow(Zipper).to receive(:zip_audio).and_return(['', '', instance_double(Process::Status, success?: true)])
      allow(Output).to receive(:filename).and_return(File.join(dir, 'out.mp3'))

      processor.convert(i)

      expect(Dubbing::Pipeline).not_to have_received(:apply)
    end
  end
end
