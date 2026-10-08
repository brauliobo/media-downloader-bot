require 'rails_helper'

RSpec.describe Downloaders::YtDlp::FormatPicker do
  def video(id, height, mb, vcodec: 'avc1.64001f', ext: 'mp4')
    {format_id: id, ext: ext, vcodec: vcodec, acodec: 'none', width: height * 16 / 9, height: height, filesize: mb * 2**20}
  end

  def audio(id, mb, language: nil, ext: 'm4a', acodec: 'mp4a.40.2', abr: nil)
    {format_id: id, ext: ext, vcodec: 'none', acodec: acodec, language: language, abr: abr, filesize: mb * 2**20}
  end

  let(:formats) do
    [
      audio('139', 2), audio('140', 4),
      video('133', 240, 5), video('134', 360, 12), video('135', 480, 25), video('136', 720, 60), video('137', 1080, 120),
      video('248', 1080, 40, vcodec: 'vp09.00.40.08', ext: 'webm'),
    ]
  end
  let(:info)    { SymMash.new(duration: 600, formats: formats) }

  def pick(info = self.info, limit_mb: 50, max_res: 1080, **opts) = described_class.for(info, limit_mb: limit_mb, max_res: max_res, **opts).selector

  it 'picks the best mp4 pair that fits the limit' do
    expect(pick).to eq('135+140')
  end

  it 'ignores formats that are not mp4 compatible even when they fit' do
    info.formats = [audio('140', 4), video('248', 1080, 10, vcodec: 'vp09.00.40.08', ext: 'webm')]
    expect(pick(info)).to be_nil
  end

  it 'falls back to the lighter audio when the best one does not fit' do
    info.formats = [audio('139', 2), audio('140', 4), video('135', 480, 44)]
    expect(pick(info)).to eq('135+139')
  end

  it 'skips audio above 64kbps at the 50MB limit even when it fits' do
    info.formats = [audio('139', 2, abr: 48), audio('140', 4, abr: 130), video('135', 480, 25)]
    expect(pick(info)).to eq('135+139')
  end

  it 'keeps any audio bitrate above the 50MB limit' do
    info.formats = [audio('139', 2, abr: 48), audio('140', 4, abr: 130), video('135', 480, 25)]
    expect(pick(info, limit_mb: 100)).to eq('135+140')
  end

  it 'gives up when only audio above the cap exists' do
    info.formats = [audio('140', 4, abr: 130), video('135', 480, 25)]
    expect(pick(info)).to be_nil
  end

  describe 'audio only' do
    def track(id, ext, acodec, abr, mb, vcodec: 'none') = {format_id: id, ext: ext, vcodec: vcodec, acodec: acodec, abr: abr, filesize: mb * 2**20}

    def pick_audio(info, **opts) = pick(info, audio_only: true, **opts)

    it 'picks the best m4a or mp3 track that fits, with no bitrate cap' do
      info.formats = [track('mp3', 'mp3', 'mp3', 128, 3), track('aac96', 'm4a', 'mp4a.40.2', 96, 2), track('aac160', 'm4a', 'mp4a.40.2', 160, 4)]
      expect(pick_audio(info)).to eq('aac160')
    end

    it 'falls to a lighter track when the best does not fit' do
      info.formats = [track('aac96', 'm4a', 'mp4a.40.2', 96, 2), track('aac160', 'm4a', 'mp4a.40.2', 160, 60)]
      expect(pick_audio(info)).to eq('aac96')
    end

    it 'ignores opus, webm and video formats' do
      info.formats = [track('251', 'webm', 'opus', 130, 3), track('v', 'mp4', 'mp4a.40.2', 96, 3, vcodec: 'avc1.64001f')]
      expect(pick_audio(info)).to be_nil
    end
  end

  it 'gives up when nothing fits' do
    expect(pick(limit_mb: 1)).to be_nil
  end

  it 'caps the resolution' do
    expect(pick(limit_mb: 500, max_res: 480)).to eq('135+140')
  end

  it 'uses a combined format when it is the best fit' do
    info.formats = [{format_id: '18', ext: 'mp4', vcodec: 'avc1.42001E', acodec: 'mp4a.40.2', height: 360, width: 640, filesize: 20 * 2**20}]
    expect(pick(info)).to eq('18')
  end

  it 'scales sizes down to a clipped section' do
    expect(pick(clip: 150)).to eq('137+140')
  end

  it 'prefers the requested audio language' do
    info.formats = [audio('140-en', 4, language: 'en'), audio('140-pt', 4, language: 'pt'), video('134', 360, 12)]
    expect(pick(info, alang: 'pt')).to eq('134+140-pt')
  end

  it 'estimates from the bitrate when the size is unknown' do
    info.formats = [video('134', 360, 0).merge(filesize: nil, tbr: 300), audio('140', 4)]
    expect(pick(info)).to eq('134+140')
  end

  it 'gives up when no size can be estimated' do
    info.formats = [video('134', 360, 0).merge(filesize: nil), audio('140', 4)]
    expect(pick(info)).to be_nil
  end

  it 'gives up without a duration' do
    info.duration = nil
    expect(pick(info)).to be_nil
  end
end
