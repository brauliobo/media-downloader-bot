require 'spec_helper'

RSpec.describe Downloaders::GalleryDl do
  let(:dir)  { Dir.mktmpdir('gallery-dl-spec-') }
  let(:tmp)  { Dir.mktmpdir('gallery-dl-tmp-', dir) }
  let(:opts) { SymMash.new }
  let(:ctx)  { Context.new(dir: dir, tmp: tmp, url: 'https://x.com/i/status/1', opts: opts) }

  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

  describe '.supports?' do
    it 'routes image posts to gallery-dl' do
      allow(Sh).to receive(:run).and_return([[[3, 'https://example.com/photo.jpg', {type: 'image'}]].to_json, '', 0])

      expect(described_class.supports?(ctx)).to eq(true)
    end

    it 'routes single-video posts to yt-dlp' do
      allow(Sh).to receive(:run).and_return([[[3, 'https://example.com/video.mp4', {type: 'video'}]].to_json, '', 0])

      expect(described_class.supports?(ctx)).to eq(false)
    end

    it 'routes multi-item posts to gallery-dl' do
      rows = [
        [3, 'https://example.com/video.mp4', {type: 'video'}],
        [3, 'https://example.com/photo.jpg', {type: 'image'}]
      ]
      allow(Sh).to receive(:run).and_return([rows.to_json, '', 0])

      expect(described_class.supports?(ctx)).to eq(true)
    end

    it 'leaves unsupported posts to yt-dlp regardless of host' do
      ctx.url = 'https://youtube.com/watch?v=1'
      allow(Sh).to receive(:run).and_return(['[]', '', 0])

      expect(described_class.supports?(ctx)).to eq(false)
    end
  end

  describe '#download' do
    it 'returns media-aware uploads for downloaded files' do
      allow(Sh).to receive(:run).and_return([[[2, {content: 'tweet text', user: {nick: 'alice'}, tweet_id: 1}]].to_json, '', 0])
      allow(Sh).to receive(:run).with(array_including('--no-part'), any_args) do |_cmd, **_|
        FileUtils.mkdir_p(File.join(tmp, 'twitter'))
        File.write(File.join(tmp, 'twitter', 'photo.jpg'), '')
        File.write(File.join(tmp, 'twitter', 'video.mp4'), '')
        ['', '', 0]
      end

      input = described_class.new(ctx).download

      expect(input.info.title).to eq('tweet text')
      expect(input.info.uploader).to eq('alice')
      expect(input.opts.caption).to eq(1)
      expect(input.uploads.size).to eq(2)
      expect(input.uploads.first.type.name).to eq(:document)
      expect(input.uploads.first.mime).to eq('image/jpeg')
      expect(input.uploads.last.type.name).to eq(:video)
      expect(input.uploads.last.mime).to eq('video/mp4')
    end

    it 'reuses discovery metadata from downloader selection' do
      rows = [
        [2, {content: 'tweet text', user: {nick: 'alice'}, tweet_id: 1}],
        [3, 'https://example.com/photo.jpg', {type: 'image'}]
      ]
      probes = 0
      allow(Sh).to receive(:run) do |command, **_params|
        if command.include?('-j')
          probes += 1
          [rows.to_json, '', 0]
        else
          File.write(File.join(tmp, 'photo.jpg'), '')
          ['', '', 0]
        end
      end

      downloader = Downloaders.for(Struct.new(:ctx).new(ctx))
      input      = downloader.download

      expect(downloader).to be_a(described_class)
      expect(input.info.title).to eq('tweet text')
      expect(probes).to eq(1)
    end
  end
end
