require 'rails_helper'

RSpec.describe Downloaders::YtDlp::StreamSelector do
  def video(id, height, mb) = {format_id: id, ext: 'mp4', vcodec: 'avc1.64001f', acodec: 'none', width: height * 16 / 9, height: height, filesize: mb * 2**20}
  def audio(id, mb)        = {format_id: id, ext: 'm4a', vcodec: 'none', acodec: 'mp4a.40.2', abr: 48, filesize: mb * 2**20}

  let(:info) { SymMash.new(duration: 600, formats: [audio('140', 4), video('135', 480, 25), video('137', 1080, 120)]) }
  let(:opts) { SymMash.new }

  before { Zipper.size_mb_limit = 50 }
  after  { Zipper.size_mb_limit = nil }

  def select(audio_only: false) = described_class.new(info, opts: opts, audio_only: audio_only, max_res: 1080).selector

  it 'picks the format to stream' do
    expect(select).to eq('135+140')
  end

  it 'picks an audio track for audio-only entries' do
    expect(select(audio_only: true)).to eq('140')
  end

  it 'is nil when streaming is off for the request' do
    opts.nostream = 1
    expect(select).to be_nil
  end

  it 'is nil when no format fits the limit' do
    Zipper.size_mb_limit = 10
    expect(select).to be_nil
  end

  it 'only counts the requested section' do
    info.formats = [audio('140', 4), video('137', 1080, 120)]
    expect(select).to be_nil

    opts.ss = '0:10'
    opts.t  = '2:30'
    expect(select).to eq('137+140')
  end
end
