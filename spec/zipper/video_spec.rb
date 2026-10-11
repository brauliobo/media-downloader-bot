require 'rails_helper'

RSpec.describe Zipper do
  include FFmpegDouble

  def probe(width: 1920, height: 1080, audio: false)
    streams = [SymMash.new(codec_type: 'video', width: width, height: height)]
    streams << SymMash.new(codec_type: 'audio') if audio
    SymMash.new(format: SymMash.new(duration: 60), streams: streams)
  end

  def zip_video(extra = {}, format: Zipper::Types.video.h264, **dimensions)
    ffmpeg = ffmpeg_double
    described_class.new(
      '/tmp/in.mp4', '/tmp/out.mp4', probe: probe(**dimensions), ffmpeg: ffmpeg,
      opts: SymMash.new({format: format, metadata: {}}.merge(extra))
    ).zip_video
    ffmpeg
  end

  describe '#format_name' do
    {
      video: %i[h264 h265 av1 vp9],
      audio: %i[opus aac mp3],
    }.each do |kind, names|
      names.each do |name|
        it "names the #{name} format" do
          zipper = described_class.new(
            '/tmp/in.mp4', '/tmp/out.mp4', probe: probe(audio: true),
            opts: SymMash.new(format: Zipper::Types.public_send(kind).public_send(name), metadata: {})
          )

          expect(zipper.format_name).to eq name
        end
      end
    end

    it 'does not know a format that is not offered' do
      zipper = described_class.new('/tmp/in.mp4', '/tmp/out.mp4', probe: probe, opts: SymMash.new(format: SymMash.new(opts: {}), metadata: {}))

      expect(zipper.format_name).to eq :unknown
    end
  end

  describe 'scaling' do
    it 'scales to even sizes' do
      expect(zip_video({width: 720})).to have_received(:scale).with(width: 720, modulus: 2)
    end

    it 'scales vp9 to multiples of eight' do
      expect(zip_video({width: 720}, format: Zipper::Types.video.vp9)).to have_received(:scale).with(width: 720, modulus: 8)
    end

    it 'halves the width of a portrait video' do
      expect(zip_video({width: 800}, width: 1080, height: 1920)).to have_received(:scale).with(width: 400, modulus: 2)
    end

    it 'keeps the width of a rotated video' do
      expect(zip_video({width: 800, vf: 'transpose=1'}, width: 1080, height: 1920)).to have_received(:scale).with(width: 800, modulus: 2)
    end

    it 'never scales up past the source' do
      expect(zip_video({width: 800}, width: 640, height: 360)).to have_received(:scale).with(width: 640, modulus: 2)
    end

    it 'fixes an odd source size when the resolution is preserved' do
      ffmpeg = zip_video({preserve_resolution: true}, width: 1921, height: 1081)

      expect(ffmpeg).to have_received(:preserve_resolution_scale).with(modulus: 2)
      expect(ffmpeg).not_to have_received(:scale)
    end

    it 'leaves an even source size alone when the resolution is preserved' do
      ffmpeg = zip_video({preserve_resolution: true})

      expect(ffmpeg).not_to have_received(:preserve_resolution_scale)
      expect(ffmpeg).not_to have_received(:scale)
    end
  end

  describe 'frame dropping' do
    it 'drops duplicate frames with the default tolerance' do
      expect(zip_video({mpdecimate: 1})).to have_received(:add_filter).with(FFmpeg.decimate_filter, stream: :video)
    end

    it 'drops duplicate frames with a given tolerance' do
      tolerance = 'hi=1024:lo=512:frac=0.40'

      expect(zip_video({mpdecimate: tolerance})).to have_received(:add_filter).with(FFmpeg.decimate_filter(tolerance), stream: :video)
    end
  end
end
