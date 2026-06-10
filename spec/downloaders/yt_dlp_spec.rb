require 'spec_helper'

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

    it 'rejects audio download when no audio stream present' do
      file = File.join(tmp, 'input-1.jpg')
      File.write(file, '')
      opts.audio = 1
      allow(Sh).to receive(:run).and_return(['', '', 0])
      allow(Prober).to receive(:for).and_return(SymMash.new(streams: []))

      expect { downloader.download_one(i) }.to raise_error(/can't find/)
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

    it 'prefers info.webpage_url over the shortified url' do
      i.url  = 'youtu.be/abc'
      i.info = SymMash.new(webpage_url: 'https://www.youtube.com/watch?v=abc')
      captured = nil
      allow(Sh).to receive(:run) { |cmd, **_| captured = cmd; ['', '', 1] }
      expect { downloader.download_one(i) }.to raise_error(/download error/)
      expect(captured).to match(%r{https://www\\?\.youtube\\?\.com/watch})
    end
  end
end
