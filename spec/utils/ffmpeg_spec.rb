require 'spec_helper'
require_relative '../../lib/utils/ffmpeg'

RSpec.describe Utils::FFmpeg do
  def status(success)
    instance_double(Process::Status, success?: success)
  end

  it 'accepts compliant ffmpeg and ffprobe versions' do
    runner = lambda do |binary, argument|
      expect(argument).to eq('-version')
      ["#{binary} version n9.0 Copyright FFmpeg", '', status(true)]
    end

    expect { described_class.verify!(runner: runner) }.not_to raise_error
  end

  it 'rejects an older version' do
    runner = ->(binary, *) { ["#{binary} version 8.1 Copyright FFmpeg", '', status(true)] }

    expect { described_class.verify!(runner: runner) }
      .to raise_error(RuntimeError, 'ffmpeg 9.0 or newer is required; found 8.1')
  end

  it 'rejects a missing binary' do
    runner = ->(*) { raise Errno::ENOENT }

    expect { described_class.verify!(runner: runner) }
      .to raise_error(RuntimeError, 'ffmpeg is required')
  end
end
