require 'spec_helper'

RSpec.describe Prober do
  describe '.for' do
    it 'raises stderr from ffprobe failures' do
      status = instance_double(Process::Status, success?: false, exitstatus: 127)
      error  = Sh::Error.new 'ffprobe failed for input.mp4', 'missing libx265.so.215', status: status
      ffmpeg = instance_double FFmpeg
      allow(ffmpeg).to receive(:probe).with('/tmp/input.mp4').and_raise(error)
      allow(FFmpeg).to receive(:new).and_return ffmpeg

      expect {
        described_class.for '/tmp/input.mp4'
      }.to raise_error(Sh::Error, 'ffprobe failed for input.mp4: missing libx265.so.215')
    end
  end

  it 'normalizes audio metadata from ffprobe JSON' do
    ffmpeg = instance_double FFmpeg
    stream = {
      codec_type:         'audio',
      codec_name:         'aac',
      profile:             'HE-AAC',
      codec_tag_string:   'mp4a',
      mime_codec_string:  'mp4a.40.5',
      sample_fmt:         'fltp',
      sample_rate:        '24000',
      channels:            2,
      channel_layout:     'stereo',
      bits_per_sample:    0,
      extradata_size:     4,
      bit_rate:           '32004'
    }
    allow(ffmpeg).to receive(:probe).with('/tmp/input.m4a').and_return('streams' => [stream])

    expect(described_class.audio_format('/tmp/input.m4a', ffmpeg: ffmpeg)).to include(
      codec_name: 'aac', profile: 'HE-AAC', sample_rate: 24_000, channels: 2, bit_rate: 32_004
    )
    expect(described_class.audio_signature('/tmp/input.m4a', ffmpeg: ffmpeg)).to include(
      profile: 'HE-AAC', channel_layout: 'stereo', codec_tag_string: 'mp4a', extradata_size: 4
    )
  end

  it 'requires an audio stream for audio metadata' do
    ffmpeg = instance_double FFmpeg
    allow(ffmpeg).to receive(:probe).with('/tmp/video.mp4').and_return('streams' => [])

    expect {
      described_class.audio_format '/tmp/video.mp4', ffmpeg: ffmpeg
    }.to raise_error('ffprobe found no audio stream for video.mp4')
  end
end
