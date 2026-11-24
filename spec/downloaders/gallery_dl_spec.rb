require 'rails_helper'

RSpec.describe Downloaders::GalleryDl do
  let(:dir)  { Dir.mktmpdir('gallery-dl-spec-') }
  let(:tmp)  { Dir.mktmpdir('gallery-dl-tmp-', dir) }
  let(:opts) { SymMash.new }
  let(:ctx)  { Context.new(dir: dir, tmp: tmp, url: 'https://x.com/i/status/1', opts: opts) }

  let(:ok)   { Struct.new(:success?).new(true) }

  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

  describe '.supports?' do
    it 'routes image posts to gallery-dl' do
      allow(Sh).to receive(:run).and_return([[[3, 'https://example.com/photo.jpg', {type: 'image'}]].to_json, '', ok])

      expect(described_class.supports?(ctx)).to eq(true)
    end

    it 'routes single-video posts to yt-dlp' do
      allow(Sh).to receive(:run).and_return([[[3, 'https://example.com/video.mp4', {type: 'video'}]].to_json, '', ok])

      expect(described_class.supports?(ctx)).to eq(false)
    end

    it 'routes split video and audio streams like Facebook reels to yt-dlp' do
      ctx.url = 'https://web.facebook.com/reel/2991134747942674'
      rows = [
        [2, {category: 'facebook', subcategory: 'video', id: '2991134747942674', type: 'video', username: 'Caveira Kids'}],
        [3, 'https://video.fbcdn.net/v.mp4', {category: 'facebook', type: 'video', extension: 'mp4'}],
        [3, 'https://video.fbcdn.net/a.mp4', {category: 'facebook', type: 'audio', extension: 'm4a'}]
      ]
      allow(Sh).to receive(:run).and_return([rows.to_json, '', ok])

      expect(described_class.supports?(ctx)).to eq(false)
    end

    it 'routes single-video tweets to gallery-dl' do
      rows = [
        [2, {category: 'twitter', subcategory: 'tweet', content: "full tweet\n\nwith note text", user: {nick: 'NEXTA'}, tweet_id: 1}],
        [3, 'https://video.twimg.com/video.mp4', {category: 'twitter', type: 'video', extension: 'mp4'}]
      ]
      allow(Sh).to receive(:run).and_return([rows.to_json, '', ok])

      expect(described_class.supports?(ctx)).to eq(true)
      expect(ctx.gallery_rows).to eq(JSON.parse(rows.to_json))
      expect(described_class.content_from(ctx.gallery_rows)).to eq("full tweet\n\nwith note text")
    end

    it 'routes multi-item posts to gallery-dl' do
      rows = [
        [3, 'https://example.com/video.mp4', {type: 'video'}],
        [3, 'https://example.com/photo.jpg', {type: 'image'}]
      ]
      allow(Sh).to receive(:run).and_return([rows.to_json, '', ok])

      expect(described_class.supports?(ctx)).to eq(true)
    end

    it 'leaves unsupported posts to yt-dlp regardless of host' do
      ctx.url = 'https://youtube.com/watch?v=1'
      allow(Sh).to receive(:run).and_return(['[]', '', ok])

      expect(described_class.supports?(ctx)).to eq(false)
    end

    it 'does not raise when probing a non-public url' do
      ctx.url = 'http://localhost/gallery'

      expect(described_class.supports?(ctx)).to eq(false)
    end

    it 'keeps non-twitter single-video metadata cached on the context' do
      rows = [
        [2, {content: "full post\n\ntext", user: {nick: 'Author'}, id: 1}],
        [3, 'https://example.com/video.mp4', {type: 'video'}]
      ]
      allow(Sh).to receive(:run).and_return([rows.to_json, '', ok])

      expect(described_class.supports?(ctx)).to eq(false)
      expect(ctx.gallery_rows).to eq(JSON.parse(rows.to_json))
      expect(described_class.content_from(ctx.gallery_rows)).to eq("full post\n\ntext")
    end

    it 'reads Instagram posts through the bundled embed extractor, which needs no login' do
      ctx.url = 'https://www.instagram.com/p/Dfkrg_JlH0Q/?img_index=11'
      rows = [[3, 'https://example.com/photo.jpg', {type: 'image'}]]

      expect(Sh).to receive(:run)
        .with([anything, '-X', described_class::EXTRACTORS, '-j', 'instagram-embed:Dfkrg_JlH0Q'], chdir: tmp)
        .and_return([rows.to_json, '', ok])

      expect(described_class.supports?(ctx)).to eq(true)
    end

    it 'loads bundled extractors for YouTube community posts' do
      ctx.url = 'https://youtube.com/post/Ugkx0123456789_-'
      rows = [[3, 'https://yt3.ggpht.com/image=s0?imgmax=0', {type: 'image'}]]

      expect(Sh).to receive(:run)
        .with([anything, '-X', described_class::EXTRACTORS, '-j', ctx.url], chdir: tmp)
        .and_return([rows.to_json, '', ok])

      expect(described_class.supports?(ctx)).to eq(true)
    end
  end

  describe '#download' do
    it 'returns media-aware uploads for downloaded files' do
      allow(Sh).to receive(:run).and_return([[[2, {content: 'tweet text', user: {nick: 'alice'}, tweet_id: 1}]].to_json, '', ok])
      allow(Sh).to receive(:run).with(array_including('--no-part'), any_args) do |_cmd, **_|
        FileUtils.mkdir_p(File.join(tmp, 'twitter'))
        File.write(File.join(tmp, 'twitter', 'photo.jpg'), '')
        File.write(File.join(tmp, 'twitter', 'video.mp4'), '')
        ['', '', ok]
      end

      input = described_class.new(ctx).download

      expect(input.info.title).to eq('tweet text')
      expect(input.info.uploader).to eq('alice')
      expect(input.opts.caption).to eq(1)
      expect(input.uploads.size).to eq(2)
      expect(input.uploads.first.type.name).to eq(:photo)
      expect(input.uploads.first.mime).to eq('image/jpeg')
      expect(input.uploads.last.type.name).to eq(:video)
      expect(input.uploads.last.mime).to eq('video/mp4')
    end

    it 'loads bundled extractors when downloading' do
      allow(Sh).to receive(:run).and_return([[[2, {title: 'post'}]].to_json, '', ok])
      expect(Sh).to receive(:run).with(array_including('-X', described_class::EXTRACTORS, '--no-part'), any_args) do |_cmd, **_|
        File.write(File.join(tmp, 'photo.jpg'), '')
        ['', '', ok]
      end

      expect(described_class.new(ctx).download.uploads.size).to eq(1)
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
          [rows.to_json, '', ok]
        else
          File.write(File.join(tmp, 'photo.jpg'), '')
          ['', '', ok]
        end
      end

      downloader = Downloaders.for(Struct.new(:ctx).new(ctx))
      input      = downloader.download

      expect(downloader).to be_a(described_class)
      expect(input.info.title).to eq('tweet text')
      expect(probes).to eq(1)
    end

    it 'hands a single downloaded video to the media processor with streaming enabled' do
      allow(Sh).to receive(:run).and_return([[[2, {category: 'twitter', content: 'tweet video', user: {nick: 'NEXTA'}, tweet_id: 42}]].to_json, '', ok])
      allow(Sh).to receive(:run).with(array_including('--no-part'), any_args) do |_cmd, **_|
        File.write(File.join(tmp, 'clip.mp4'), '')
        ['', '', ok]
      end

      input = described_class.new(ctx).download

      expect(input.uploads).to be_nil
      expect(input.fn_in).to eq(File.join(tmp, 'clip.mp4'))
      expect(input.stream).to eq('gallery-dl')
      expect(input.info.title).to eq('tweet video')
      expect(input.info.uploader).to eq('NEXTA')
    end

    it 'disables streaming on a single video when audio extraction or cutting is requested' do
      opts.audio = 1
      allow(Sh).to receive(:run).and_return([[[2, {category: 'twitter', content: 'tweet video', tweet_id: 42}]].to_json, '', ok])
      allow(Sh).to receive(:run).with(array_including('--no-part'), any_args) do |_cmd, **_|
        File.write(File.join(tmp, 'clip.mp4'), '')
        ['', '', ok]
      end

      input = described_class.new(ctx).download

      expect(input.fn_in).to eq(File.join(tmp, 'clip.mp4'))
      expect(input.stream).to be_nil
    end

    it 'extracts caption and username metadata from Facebook photo posts' do
      ctx.url = 'https://www.facebook.com/photo/?fbid=123'
      allow(Sh).to receive(:run).and_return([[[2, {category: 'facebook', caption: 'Photo caption', username: 'Caveira Kids', id: '123'}]].to_json, '', ok])
      allow(Sh).to receive(:run).with(array_including('--no-part'), any_args) do |_cmd, **_|
        File.write(File.join(tmp, 'photo.jpg'), '')
        ['', '', ok]
      end

      input = described_class.new(ctx).download

      expect(input.info.title).to eq('Photo caption')
      expect(input.info.uploader).to eq('Caveira Kids')
    end
  end
end
