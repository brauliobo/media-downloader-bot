require 'rails_helper'
require_relative '../support/media_files'

RSpec.describe Downloaders::YtDlp do
  include MediaFiles

  let(:dir)  { Dir.mktmpdir('ytdlp-spec-') }
  let(:tmp)  { Dir.mktmpdir('ytdlp-tmp-', dir) }
  let(:opts) { SymMash.new }
  let(:msg)  { SymMash.new(from: {id: 10}) }
  let(:ctx)  { Context.new(dir: dir, tmp: tmp, url: 'https://example.com/v', opts: opts, msg: msg) }
  let(:downloader) { described_class.new(ctx) }
  let(:status) { Class.new { def errors = @errors ||= []; def error(text, **) = errors << text }.new }

  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

  # yt-dlp as the subprocess it is (ffprobe still runs for real): notes every command and, when asked for the metadata, leaves the info files.
  def fake_yt_dlp(infos: [], stderr: '', code: 0)
    [].tap do |commands|
      allow(Sh).to receive(:run).and_call_original
      allow(Sh).to receive(:run).with(a_string_starting_with('yt-dlp'), any_args) do |cmd, **|
        commands << cmd
        infos.each_with_index { |info, n| write_info(info, n) } if cmd.include?('--skip-download')
        ['', stderr, code]
      end
    end
  end

  def write_info(info, n)
    path = "#{tmp}/info-#{n + 1}.info.json"
    File.write(path, info.to_json)
    File.utime(Time.at(n), Time.at(n), path)
  end

  def admin! = msg.from.id = Bot::MsgHelpers::ADMIN_CHAT_ID

  def info_of(**attrs) = SymMash.new(webpage_url: 'https://example.com/v', display_id: 'v', _filename: 'v.mp4', duration: 10, **attrs)

  def inputs(*infos)
    fake_yt_dlp(infos: infos)
    downloader.download
  end

  describe '#download' do
    it 'disables playlist downloads for non-admin users' do
      captured = fake_yt_dlp

      downloader.download

      expect(captured.first).to include('--no-playlist')
      expect(captured.first).not_to include('--playlist-end')
    end

    it 'keeps playlist limits available for admins' do
      opts.limit = 3
      admin!
      captured = fake_yt_dlp

      downloader.download

      expect(captured.first).to include('--playlist-end 3')
      expect(captured.first).not_to include('--no-playlist')
    end

    it 'forces single video downloads when cutting a playlist watch url' do
      ctx.url = 'https://www.youtube.com/watch?v=ceWwMJN5Ou0&list=TLPQMDMwNzIwMjbHKJx1-gwUng&index=13'
      opts.ss = '14:57'
      opts.to = '20:00'
      admin!
      captured = fake_yt_dlp

      downloader.download

      expect(captured.first).to include('--download-sections \*897.0-1200.0')
      expect(captured.first).to include('--no-playlist')
      expect(captured.first).not_to include('--playlist-end')
    end

    it 'converts period forms and t into absolute download sections' do
      opts.ss = '1m'
      opts.t  = '30s'
      captured = fake_yt_dlp

      downloader.download

      expect(captured.first).to include('--download-sections \*60.0-90.0')
      expect(captured.first).to include('--no-playlist')
    end

    it 'enables generic extractor browser impersonation' do
      captured = fake_yt_dlp

      downloader.download

      expect(captured.first).to include('--extractor-args generic:impersonate')
    end

    it 'uses a youtube client that exposes alternate audio languages' do
      ctx.url = 'https://www.youtube.com/watch?v=4MCYhF_bte8'
      ctx.opts.alang = 'pt'
      captured = fake_yt_dlp

      downloader.download

      extractor_args = 'youtube:lang=pt;player_client=web_embedded,default'
      expect(captured.first).to include("--extractor-args #{Sh.escape(extractor_args)}")
      expect(captured.first).to include(Sh.escape('bestvideo+bestaudio[language^=pt]'))
    end

    it 'resolves rumble urls through oembed' do
      ctx.url = 'https://rumble.com/v7c086u-modern-education-is-working-exactly-as-planned-sf736.html?e9s=src_v1'
      body = {html: '<iframe src="https://rumble.com/embed/v79tk6m/" />'}.to_json
      allow(Utils::HTTP).to receive(:get_public).and_return(body)
      captured = fake_yt_dlp

      downloader.download

      expect(captured.first).to include('https://rumble.com/embed/v79tk6m/')
      expect(captured.first).not_to include('v7c086u-modern-education')
    end

    it 'reports a missing url instead of crashing' do
      ctx.url = nil
      ctx.st  = status
      captured = fake_yt_dlp

      downloader.download

      expect(status.errors).to eq(['No URL found'])
      expect(captured).to be_empty
    end

    it 'reports the metadata errors' do
      ctx.st = status
      fake_yt_dlp(stderr: 'unsupported <url>', code: 1)

      downloader.download

      expect(status.errors).to eq(["Metadata errors:\n<pre>unsupported &lt;url&gt;</pre>"])
    end
  end

  describe '#download_one' do
    let(:i) { SymMash.new(url: 'https://example.com/v', opts: opts) }

    def download_fails
      fake_yt_dlp(code: 1).tap { expect { downloader.download_one(i) }.to raise_error(/download error/) }
    end

    it 'downloads the picked streaming format as mp4 with faststart' do
      i.stream = '135+140'

      captured = download_fails

      expect(captured.first).to include('-f 135+140', '--merge-output-format mp4', 'Merger+ffmpeg_o')
      expect(captured.first).not_to include('bestvideo')
    end

    it 'does not extract audio again when an audio format was picked' do
      opts.audio = 1
      i.stream = '140'

      captured = download_fails

      expect(captured.first).to include('-f 140')
      expect(captured.first).not_to include(' -x')
    end

    it 'extracts audio when transcoding' do
      opts.audio = 1

      expect(download_fails.first).to include(' -x')
    end

    it 'expects an audio stream from a source without video' do
      file = media_file(File.join(tmp, 'input-1.m4a'))
      i.info = SymMash.new(video_ext: 'none')
      fake_yt_dlp

      downloader.download_one(i)

      expect(i.fn_in).to eq(file)
    end

    it 'raises when yt-dlp exits non-zero' do
      fake_yt_dlp(stderr: 'boom', code: 1)
      expect { downloader.download_one(i) }.to raise_error(/download error.*boom/m)
    end

    it 'raises when no downloaded file is found' do
      fake_yt_dlp
      expect { downloader.download_one(i) }.to raise_error(/can't find/)
    end

    it 'sets fn_in when a video file is downloaded' do
      file = media_file(File.join(tmp, 'input-1.mp4'))
      fake_yt_dlp

      downloader.download_one(i)
      expect(i.fn_in).to eq(file)
    end

    it 'clears per-input cuts after yt-dlp downloads a section' do
      media_file(File.join(tmp, 'input-1.mp4'))
      opts.ss = '1m'
      opts.t  = '30s'
      i.opts = opts.deep_dup
      fake_yt_dlp

      downloader.download_one(i)

      expect([opts, i.opts].flat_map { |o| [o.ss, o.to, o.t] }).to all(be_nil)
    end

    it 'rejects audio download when no audio stream present' do
      media_file(File.join(tmp, 'input-1.jpg'))
      opts.audio = 1
      fake_yt_dlp

      expect { downloader.download_one(i) }.to raise_error(/can't find/)
    end

    it 'reports probe failures instead of a missing stream' do
      File.write(File.join(tmp, 'input-1.mp4'), '')
      fake_yt_dlp

      expect { downloader.download_one(i) }.to raise_error(/probe failed.*ffprobe failed for input-1.mp4/)
    end

    it 'prepends https when the input url lacks a protocol' do
      i.url = 'youtu.be/abc'

      expect(download_fails.first).to match(%r{https://youtu\\?\.be/abc})
    end

    it 'gives each playlist item its own opts so per-item mutation does not bleed' do
      i1, i2 = inputs(info_of(webpage_url: 'https://a/v1', display_id: 'a1'), info_of(webpage_url: 'https://a/v2', display_id: 'a2'))
      i1.opts.format = SymMash.new(ext: :mp4)
      expect(i2.opts.format).to be_nil
      expect(opts.format).to be_nil
    end

    it 'preserves the full info.webpage_url' do
      i.url  = 'youtu.be/abc'
      i.info = SymMash.new(webpage_url: 'https://www.youtube.com/watch?v=abc')

      expect(download_fails.first).to match(%r{https://www\\?\.youtube\\?\.com/watch})
    end

    describe 'streaming format' do
      let(:info) do
        info_of(
          duration: 600,
          formats: [
            {format_id: '140', ext: 'm4a', vcodec: 'none', acodec: 'mp4a.40.2', filesize: 4 * 2**20},
            {format_id: '135', ext: 'mp4', vcodec: 'avc1.4d401e', acodec: 'none', width: 854, height: 480, filesize: 25 * 2**20},
          ]
        )
      end

      def stream = inputs(info).first&.stream

      before { Zipper.size_mb_limit = 50 }
      after  { Zipper.size_mb_limit = nil }

      it 'is picked for non admins' do
        expect(stream).to eq('135+140')
      end

      it 'is picked for admins too' do
        admin!

        expect(stream).to eq('135+140')
      end

      it 'is picked with options that do not touch the encoding' do
        opts.clang = 'pt'

        expect(stream).to eq('135+140')
      end

      it 'is nil when no format fits the limit, so the video is encoded' do
        Zipper.size_mb_limit = 20

        expect(stream).to be_nil
      end

      it 'only counts the requested section' do
        info.formats = [
          {format_id: '140', ext: 'm4a', vcodec: 'none', acodec: 'mp4a.40.2', abr: 48, filesize: 4 * 2**20},
          {format_id: '137', ext: 'mp4', vcodec: 'avc1.640028', acodec: 'none', width: 1920, height: 1080, filesize: 120 * 2**20},
        ]
        expect(stream).to be_nil

        opts.ss = '0:10'
        opts.t  = '2:30'
        expect(stream).to eq('137+140')
      end

      it 'skips audio above 64kbps at the 50MB limit' do
        info.formats << SymMash.new(format_id: '139', ext: 'm4a', vcodec: 'none', acodec: 'mp4a.40.5', abr: 48, filesize: 2**20)
        info.formats.first.abr = 130

        expect(stream).to eq('135+139')
      end

      it 'picks an audio track for the audio option' do
        opts.audio = 1
        info.formats << SymMash.new(format_id: '140x', ext: 'm4a', vcodec: 'none', acodec: 'mp4a.40.2', abr: 130, filesize: 4 * 2**20)

        expect(stream).to eq('140x')
      end

      it 'picks an audio track for a source without video' do
        info.video_ext = 'none'
        info.formats   = [SymMash.new(format_id: 'sc', ext: 'mp3', vcodec: 'none', acodec: 'mp3', abr: 128, filesize: 3 * 2**20)]

        expect(stream).to eq('sc')
      end

      describe 'for videos longer than the encoding limit' do
        before do
          ctx.st        = status
          info.duration = 50 * 60
        end

        it 'streams them when a format fits' do
          expect(stream).to eq('135+140')
          expect(status.errors).to be_empty
        end

        it 'refuses them when nothing fits and they must be encoded' do
          info.formats.last.filesize = 80 * 2**20

          expect(inputs(info)).to be_empty
          expect(status.errors).to eq(["Can't fit video longer than 43 minutes in 50MB"])
        end

        it 'refuses them when encoding is requested' do
          opts.nostream = 1

          expect(inputs(info)).to be_empty
          expect(status.errors).to match([/longer than 43 minutes/])
        end

        it 'encodes them when the floor bitrates still fit them' do
          opts.nostream = 1
          info.duration = 40 * 60

          expect(inputs(info)).not_to be_empty
        end

        it 'counts only the requested section' do
          opts.nostream = 1
          opts.ss = '0'
          opts.t  = '30m'

          expect(inputs(info)).not_to be_empty
        end
      end

      describe 'for audio that does not fit as is' do
        before do
          ctx.st       = status
          opts.audio   = 1
          info.formats = [SymMash.new(format_id: '140', ext: 'm4a', vcodec: 'none', acodec: 'mp4a.40.2', abr: 130, filesize: 90 * 2**20)]
        end

        it 'is encoded when the minimum bitrate still fits it' do
          info.duration = 3 * 3600

          expect(inputs(info).first.stream).to be_nil
          expect(status.errors).to be_empty
        end

        it 'is refused when even the minimum bitrate does not fit it' do
          info.duration = 7 * 3600

          expect(inputs(info)).to be_empty
          expect(status.errors).to eq(["Can't fit audio longer than 395 minutes in 50MB"])
        end

        it 'counts only the requested section' do
          info.duration = 7 * 3600
          opts.ss = '0'
          opts.t  = '1h'

          expect(inputs(info)).not_to be_empty
        end
      end

      it 'is skipped with nostream' do
        opts.nostream = 1

        expect(stream).to be_nil
      end

      it 'is skipped when an option needs transcoding' do
        opts.speed = 2

        expect(stream).to be_nil
      end
    end

    it 'uses the regular short YouTube link format for Shorts' do
      ctx.url = 'https://www.youtube.com/shorts/abc123'

      input = inputs(info_of(webpage_url: 'https://www.youtube.com/shorts/abc123', display_id: 'abc123')).first

      expect(input.url).to eq('youtu.be/abc123')
      expect(input.info.url).to eq('https://www.youtube.com/shorts/abc123')
    end

    it 'uses full x.com descriptions when titles are ellipsized' do
      info = info_of(
        webpage_url: 'https://x.com/i/status/2070518837150167314',
        title:       'Cloooud - As always, the Russian invaders are stealing anything that is lying ar...',
        description: 'As always, the Russian invaders are stealing anything that is lying around.'
      )

      expect(inputs(info).first.info.title).to eq('As always, the Russian invaders are stealing anything that is lying around.')
    end

    it 'uses full x.com descriptions when yt-dlp appends a video index' do
      info = info_of(
        webpage_url: 'https://x.com/nexta_tv/status/2091885684243988758',
        title:       'NEXTA - 🥹 A touching moment: a serviceman asked Zelenskyy for a selfie during... #1',
        description: '🥹 A touching moment: a serviceman asked Zelenskyy for a selfie during an award ceremony'
      )

      expect(inputs(info).first.info.title).to eq(info.description)
    end

    it 'prefers gallery-dl note tweet text over truncated yt-dlp metadata' do
      ctx.gallery_rows = [[2, {content: "full tweet\n\nwith note text"}]]
      info = info_of(
        webpage_url: 'https://x.com/nexta_tv/status/2091885684243988758',
        title:       'NEXTA - 🥹 A touching moment: a serviceman asked Zelenskyy for a selfie during... #1',
        description: 'truncated legacy full_text https://t.co/UnVMfIYUCn'
      )

      input = inputs(info).first

      expect(input.info.title).to eq("full tweet\n\nwith note text")
      expect(input.info.description).to eq("full tweet\n\nwith note text")
    end
  end
end
