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
  end
end
