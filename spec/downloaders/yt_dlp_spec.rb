require 'rails_helper'

RSpec.describe Downloaders::YtDlp do
  let(:dir)  { Dir.mktmpdir('ytdlp-spec-') }
  let(:tmp)  { Dir.mktmpdir('ytdlp-tmp-', dir) }
  let(:opts) { SymMash.new }
  let(:msg)  { SymMash.new(from: {id: 10}) }
  let(:ctx)  { Context.new(dir: dir, tmp: tmp, url: 'https://example.com/v', opts: opts, msg: msg) }
  let(:downloader) { described_class.new(ctx) }

  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

  describe '#download' do
    it 'disables playlist downloads for non-admin users' do
      captured = nil
      allow(Bot::MsgHelpers).to receive(:from_admin?).with(msg).and_return(false)
      allow(Sh).to receive(:run) { |cmd, **_| captured = cmd; ['', '', 0] }

      downloader.download

      expect(captured).to include('--no-playlist')
      expect(captured).not_to include('--playlist-end')
    end

    it 'keeps playlist limits available for admins' do
      opts.limit = 3
      captured   = nil
      allow(Bot::MsgHelpers).to receive(:from_admin?).with(msg).and_return(true)
      allow(Sh).to receive(:run) { |cmd, **_| captured = cmd; ['', '', 0] }

      downloader.download

      expect(captured).to include('--playlist-end 3')
      expect(captured).not_to include('--no-playlist')
    end

    it 'forces single video downloads when cutting a playlist watch url' do
      ctx.url = 'https://www.youtube.com/watch?v=ceWwMJN5Ou0&list=TLPQMDMwNzIwMjbHKJx1-gwUng&index=13'
      opts.ss = '14:57'
      opts.to = '20:00'
      captured = nil
      allow(Bot::MsgHelpers).to receive(:from_admin?).with(msg).and_return(true)
      allow(Sh).to receive(:run) { |cmd, **_| captured = cmd; ['', '', 0] }

      downloader.download

      expect(captured).to include('--download-sections \*897.0-1200.0')
      expect(captured).to include('--no-playlist')
      expect(captured).not_to include('--playlist-end')
    end

    it 'converts period forms and t into absolute download sections' do
      opts.ss = '1m'
      opts.t  = '30s'
      captured = nil
      allow(Sh).to receive(:run) { |cmd, **_| captured = cmd; ['', '', 0] }

      downloader.download

      expect(captured).to include('--download-sections \*60.0-90.0')
      expect(captured).to include('--no-playlist')
    end

    it 'enables generic extractor browser impersonation' do
      captured = nil
      allow(Sh).to receive(:run) { |cmd, **_| captured = cmd; ['', '', 0] }

      downloader.download

      expect(captured).to include('--extractor-args generic:impersonate')
    end

    it 'uses a youtube client that exposes alternate audio languages' do
      ctx.url = 'https://www.youtube.com/watch?v=4MCYhF_bte8'
      ctx.opts.alang = 'pt'
      captured = nil
      allow(Sh).to receive(:run) { |cmd, **_| captured = cmd; ['', '', 0] }

      downloader.download

      extractor_args = 'youtube:lang=pt;player_client=web_embedded,default'
      expect(captured).to include("--extractor-args #{Sh.escape(extractor_args)}")
      expect(captured).to include(Sh.escape('bestvideo+bestaudio[language^=pt]'))
    end

    it 'resolves rumble urls through oembed' do
      ctx.url = 'https://rumble.com/v7c086u-modern-education-is-working-exactly-as-planned-sf736.html?e9s=src_v1'
      captured = nil
      body = {html: '<iframe src="https://rumble.com/embed/v79tk6m/" />'}.to_json
      allow(Utils::HTTP).to receive(:get_public).and_return(body)
      allow(Sh).to receive(:run) { |cmd, **_| captured = cmd; ['', '', 0] }

      downloader.download

      expect(captured).to include('https://rumble.com/embed/v79tk6m/')
      expect(captured).not_to include('v7c086u-modern-education')
    end

    it 'reports a missing url instead of crashing' do
      status = Class.new do
        attr_reader :errors

        def initialize
          @errors = []
        end

        def error(text, **_)
          errors << text
        end
      end.new

      ctx.url = nil
      ctx.st  = status
      allow(Sh).to receive(:run)

      downloader.download

      expect(status.errors).to eq(['No URL found'])
      expect(Sh).not_to have_received(:run)
    end
  end

  describe '#download_one' do
    let(:i) { SymMash.new(url: 'https://example.com/v', opts: opts) }

    it 'downloads the picked streaming format as mp4 with faststart' do
      i.stream = '135+140'
      captured = nil
      allow(Sh).to receive(:run) { |cmd, **_| captured = cmd; ['', '', 1] }

      expect { downloader.download_one(i) }.to raise_error(/download error/)

      expect(captured).to include('-f 135+140', '--merge-output-format mp4', 'Merger+ffmpeg_o')
      expect(captured).not_to include('bestvideo')
    end

    it 'does not extract audio again when an audio format was picked' do
      opts.audio = 1
      i.stream = '140'
      captured = nil
      allow(Sh).to receive(:run) { |cmd, **_| captured = cmd; ['', '', 1] }

      expect { downloader.download_one(i) }.to raise_error(/download error/)

      expect(captured).to include('-f 140')
      expect(captured).not_to include(' -x')
    end

    it 'extracts audio when transcoding' do
      opts.audio = 1
      captured = nil
      allow(Sh).to receive(:run) { |cmd, **_| captured = cmd; ['', '', 1] }

      expect { downloader.download_one(i) }.to raise_error(/download error/)

      expect(captured).to include(' -x')
    end

    it 'expects an audio stream from a source without video' do
      file = File.join(tmp, 'input-1.m4a')
      File.write(file, '')
      i.info = SymMash.new(video_ext: 'none')
      allow(Sh).to receive(:run).and_return(['', '', 0])
      allow(Prober).to receive(:for).and_return(SymMash.new(streams: [SymMash.new(codec_type: 'audio')]))

      downloader.download_one(i)

      expect(i.fn_in).to eq(file)
    end

    it 'raises when yt-dlp exits non-zero' do
      allow(Sh).to receive(:run).and_return(['', 'boom', 1])
      expect { downloader.download_one(i) }.to raise_error(/download error.*boom/m)
    end

    it 'raises when no downloaded file is found' do
      allow(Sh).to receive(:run).and_return(['', '', 0])
      expect { downloader.download_one(i) }.to raise_error(/can't find/)
    end

    it 'sets fn_in when a video file is downloaded' do
      file = File.join(tmp, 'input-1.mp4')
      File.write(file, '')
      allow(Sh).to receive(:run).and_return(['', '', 0])
      probe = SymMash.new(streams: [SymMash.new(codec_type: 'video')])
      allow(Prober).to receive(:for).and_return(probe)

      downloader.download_one(i)
      expect(i.fn_in).to eq(file)
    end

    it 'clears per-input cuts after yt-dlp downloads a section' do
      file = File.join(tmp, 'input-1.mp4')
      File.write(file, '')
      opts.ss = '1m'
      opts.t  = '30s'
      i.opts = opts.deep_dup
      allow(Sh).to receive(:run).and_return(['', '', 0])
      allow(Prober).to receive(:for).and_return(SymMash.new(streams: [SymMash.new(codec_type: 'video')]))

      downloader.download_one(i)

      expect(opts.ss).to be_nil
      expect(opts.to).to be_nil
      expect(opts.t).to be_nil
      expect(i.opts.ss).to be_nil
      expect(i.opts.to).to be_nil
      expect(i.opts.t).to be_nil
    end

    it 'rejects audio download when no audio stream present' do
      file = File.join(tmp, 'input-1.jpg')
      File.write(file, '')
      opts.audio = 1
      allow(Sh).to receive(:run).and_return(['', '', 0])
      allow(Prober).to receive(:for).and_return(SymMash.new(streams: []))

      expect { downloader.download_one(i) }.to raise_error(/can't find/)
    end

    it 'reports probe failures instead of a missing stream' do
      file = File.join(tmp, 'input-1.mp4')
      File.write(file, '')
      allow(Sh).to receive(:run).and_return(['', '', 0])
      allow(Prober).to receive(:for).and_raise('ffprobe failed: missing lib')

      expect { downloader.download_one(i) }.to raise_error(/probe failed.*missing lib/)
    end

    it 'prepends https when the input url lacks a protocol' do
      i.url = 'youtu.be/abc'
      captured = nil
      allow(Sh).to receive(:run) { |cmd, **_| captured = cmd; ['', '', 1] }
      expect { downloader.download_one(i) }.to raise_error(/download error/)
      expect(captured).to match(%r{https://youtu\\?\.be/abc})
    end

    it 'gives each playlist item its own opts so per-item mutation does not bleed' do
      shared = opts
      i1 = downloader.send(:build_input, SymMash.new(webpage_url: 'https://a/v1', display_id: 'a1', _filename: 'a1.webm', duration: 10), 0, true)
      i2 = downloader.send(:build_input, SymMash.new(webpage_url: 'https://a/v2', display_id: 'a2', _filename: 'a2.webm', duration: 10), 1, true)
      i1.opts.format = SymMash.new(ext: :mp4)
      expect(i2.opts.format).to be_nil
      expect(shared.format).to be_nil
    end

    it 'preserves the full info.webpage_url' do
      i.url  = 'youtu.be/abc'
      i.info = SymMash.new(webpage_url: 'https://www.youtube.com/watch?v=abc')
      captured = nil
      allow(Sh).to receive(:run) { |cmd, **_| captured = cmd; ['', '', 1] }
      expect { downloader.download_one(i) }.to raise_error(/download error/)
      expect(captured).to match(%r{https://www\\?\.youtube\\?\.com/watch})
    end

    describe 'streaming format' do
      let(:info) do
        SymMash.new(
          webpage_url: 'https://example.com/v', display_id: 'v', _filename: 'v.mp4', duration: 600,
          formats: [
            {format_id: '140', ext: 'm4a', vcodec: 'none', acodec: 'mp4a.40.2', filesize: 4 * 2**20},
            {format_id: '135', ext: 'mp4', vcodec: 'avc1.4d401e', acodec: 'none', width: 854, height: 480, filesize: 25 * 2**20},
          ]
        )
      end

      before { Zipper.size_mb_limit = 50 }
      after  { Zipper.size_mb_limit = nil }

      it 'is picked for non admins' do
        allow(Bot::MsgHelpers).to receive(:from_admin?).with(msg).and_return(false)

        expect(downloader.send(:build_input, info, 0, false).stream).to eq('135+140')
      end

      it 'is picked for admins too' do
        allow(Bot::MsgHelpers).to receive(:from_admin?).with(msg).and_return(true)

        expect(downloader.send(:build_input, info, 0, false).stream).to eq('135+140')
      end

      it 'is picked with options that do not touch the encoding' do
        opts.clang = 'pt'

        expect(downloader.send(:build_input, info, 0, false).stream).to eq('135+140')
      end

      it 'skips audio above 64kbps at the 50MB limit' do
        info.formats << SymMash.new(format_id: '139', ext: 'm4a', vcodec: 'none', acodec: 'mp4a.40.5', abr: 48, filesize: 2**20)
        info.formats.first.abr = 130

        expect(downloader.send(:build_input, info, 0, false).stream).to eq('135+139')
      end

      it 'picks an audio track for the audio option' do
        opts.audio = 1
        info.formats << SymMash.new(format_id: '140x', ext: 'm4a', vcodec: 'none', acodec: 'mp4a.40.2', abr: 130, filesize: 4 * 2**20)

        expect(downloader.send(:build_input, info, 0, false).stream).to eq('140x')
      end

      it 'picks an audio track for a source without video' do
        info.video_ext = 'none'
        info.formats   = [SymMash.new(format_id: 'sc', ext: 'mp3', vcodec: 'none', acodec: 'mp3', abr: 128, filesize: 3 * 2**20)]

        expect(downloader.send(:build_input, info, 0, false).stream).to eq('sc')
      end

      it 'is skipped with nostream' do
        opts.nostream = 1

        expect(downloader.send(:build_input, info, 0, false).stream).to be_nil
      end

      it 'is skipped when an option needs transcoding' do
        opts.speed = 2

        expect(downloader.send(:build_input, info, 0, false).stream).to be_nil
      end
    end

    it 'uses the regular short YouTube link format for Shorts' do
      ctx.url = 'https://www.youtube.com/shorts/abc123'
      info = SymMash.new(
        webpage_url: 'https://www.youtube.com/shorts/abc123',
        display_id:  'abc123',
        _filename:   'abc123.mp4',
        duration:    10,
      )

      input = downloader.send(:build_input, info, 0, false)

      expect(input.url).to eq('youtu.be/abc123')
      expect(input.info.url).to eq('https://www.youtube.com/shorts/abc123')
    end

    it 'uses full x.com descriptions when titles are ellipsized' do
      info = SymMash.new(
        webpage_url: 'https://x.com/i/status/2070518837150167314',
        display_id:  '2070518837150167314',
        _filename:   'status.mp4',
        duration:    10,
        title:       'Cloooud - As always, the Russian invaders are stealing anything that is lying ar...',
        description: 'As always, the Russian invaders are stealing anything that is lying around.'
      )

      input = downloader.send(:build_input, info, 0, false)

      expect(input.info.title).to eq('As always, the Russian invaders are stealing anything that is lying around.')
    end

    it 'uses full x.com descriptions when yt-dlp appends a video index' do
      info = SymMash.new(
        webpage_url: 'https://x.com/nexta_tv/status/2091885684243988758',
        display_id:  '2091885684243988758',
        _filename:   'status.mp4',
        duration:    10,
        title:       'NEXTA - 🥹 A touching moment: a serviceman asked Zelenskyy for a selfie during... #1',
        description: '🥹 A touching moment: a serviceman asked Zelenskyy for a selfie during an award ceremony'
      )

      input = downloader.send(:build_input, info, 0, false)

      expect(input.info.title).to eq('🥹 A touching moment: a serviceman asked Zelenskyy for a selfie during an award ceremony')
    end

    it 'prefers gallery-dl note tweet text over truncated yt-dlp metadata' do
      ctx.gallery_rows = [[2, {content: "full tweet\n\nwith note text"}]]
      info = SymMash.new(
        webpage_url: 'https://x.com/nexta_tv/status/2091885684243988758',
        display_id:  '2091885684243988758',
        _filename:   'status.mp4',
        duration:    10,
        title:       'NEXTA - 🥹 A touching moment: a serviceman asked Zelenskyy for a selfie during... #1',
        description: 'truncated legacy full_text https://t.co/UnVMfIYUCn'
      )

      input = downloader.send(:build_input, info, 0, false)

      expect(input.info.title).to eq("full tweet\n\nwith note text")
      expect(input.info.description).to eq("full tweet\n\nwith note text")
    end
  end
end
