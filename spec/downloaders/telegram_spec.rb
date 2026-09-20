require 'spec_helper'

RSpec.describe Downloaders::Telegram::Link do
  def parse(url) = described_class.parse(url)

  it 'parses public posts, web previews, and trailing letter suffixes' do
    %w[
      https://t.me/RFU_EN/5682
      https://t.me/RFU_EN/5682b
      https://t.me/s/RFU_EN/5682
      https://telegram.me/RFU_EN/5682?embed=1
    ].each do |url|
      link = parse(url)
      expect(link.slug).to eq('RFU_EN')
      expect(link.message_id).to eq(5682)
      expect(link.private?).to eq(false)
      expect(link.canonical_url).to eq('https://t.me/RFU_EN/5682')
    end
  end

  it 'keeps the numeric post id in the public embed url' do
    link = parse('https://t.me/RFU_EN/5682b')

    expect(link.embed_url).to eq('https://t.me/RFU_EN/5682?embed=1')
  end

  it 'parses album single-item links and private channel posts' do
    single = parse('https://t.me/vorposte/29342?single')
    priv   = parse('https://t.me/c/1234567890/42')
    topic  = parse('https://t.me/c/1234567890/10/42')

    expect(single.single?).to eq(true)
    expect(priv.private?).to eq(true)
    expect(priv.chat_id).to eq(1234567890)
    expect(priv.message_id).to eq(42)
    expect(priv.td_chat_id).to eq(-1001234567890)
    expect(topic.message_id).to eq(42)
  end

  it 'ignores non-post Telegram urls' do
    expect(parse('https://t.me/RFU_EN')).to be_nil
    expect(parse('https://t.me/addstickers/CoolPack')).to be_nil
    expect(parse('https://t.me/share/url?url=https://example.com')).to be_nil
    expect(parse('https://example.com/RFU_EN/5682')).to be_nil
  end
end

RSpec.describe Downloaders::Telegram::Embed do
  def parse(name)
    described_class.parse(File.read(File.join('spec/fixtures/telegram', name)))
  end

  it 'reads photo posts from the public embed' do
    post = parse('photo_post.html')

    expect(post.error).to be_nil
    expect(post.author).to include('RFU News')
    expect(post.text).to include('U.S. Approves $2.68 Billion Air-Defense Sale to Ukraine')
    expect(post.items).to contain_exactly(
      have_attributes(kind: :photo, url: 'https://cdn4.telesco.pe/file/photo.jpg')
    )
  end

  it 'reads video src and grouped photos' do
    video = parse('video_post.html')
    album = parse('album_post.html')

    expect(video.items.map(&:kind)).to eq([:video])
    expect(album.items.map(&:url)).to eq([
      'https://cdn4.telesco.pe/file/one.jpg',
      'https://cdn4.telesco.pe/file/two.jpg',
    ])
  end

  it 'rejects missing posts and videos without a public file' do
    expect(parse('missing_post.html').error).to eq('Telegram post not found')
    html = <<~HTML
      <a class="tgme_widget_message_video_player not_supported" href="https://t.me/RFU_EN/5665"></a>
    HTML
    expect(described_class.parse(html).error).to eq('Telegram video is not available from the public preview')
  end
end

RSpec.describe Downloaders::Telegram do
  let(:dir)  { Dir.mktmpdir('telegram-spec-') }
  let(:tmp)  { Dir.mktmpdir('telegram-tmp-', dir) }
  let(:opts) { SymMash.new }
  let(:url)  { 'https://t.me/RFU_EN/5682b' }
  let(:ctx)  { Context.new(dir: dir, tmp: tmp, url: url, opts: opts, msg: SymMash.new(from: {id: 10})) }
  let(:downloader) { described_class.new(ctx) }

  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

  def fixture(name) = File.read(File.join('spec/fixtures/telegram', name))

  it 'routes public telegram post links, including trailing letter suffixes' do
    expect(described_class.supports?(ctx)).to eq(true)
    expect(Downloaders.for(Struct.new(:ctx).new(ctx))).to be_a(described_class)
  end

  it 'downloads public photo posts as captioned uploads' do
    allow(Utils::HTTP).to receive(:get_public).with('https://t.me/RFU_EN/5682?embed=1').and_return(fixture('photo_post.html'))
    allow(Utils::HTTP).to receive(:download_public) do |_media_url, path|
      File.binwrite(path, 'jpeg-bytes')
      'image/jpeg'
    end

    input = downloader.download

    expect(input.opts.caption).to eq(1)
    expect(input.info.title).to include('Air-Defense Sale to Ukraine')
    expect(input.info.uploader).to include('RFU News')
    expect(input.uploads.size).to eq(1)
    expect(input.uploads.first.type.name).to eq(:photo)
    expect(input.uploads.first.mime).to eq('image/jpeg')
    expect(File.read(input.uploads.first.fn_out)).to eq('jpeg-bytes')
    expect(downloader.download_one(input)).to eq(true)
  end

  it 'sends a single public video through the zipper pipeline' do
    ctx.url = 'https://t.me/europa_press/613'
    allow(Utils::HTTP).to receive(:get_public).and_return(fixture('video_post.html'))
    allow(Utils::HTTP).to receive(:download_public) do |_media_url, path|
      File.binwrite(path, 'mp4-bytes')
      'video/mp4'
    end

    input = downloader.download

    expect(input.fn_in).to be_present
    expect(input.uploads).to be_nil
    expect(input.info.title).to include('video briefing')
    expect(File.read(input.fn_in)).to eq('mp4-bytes')
  end

  it 'keeps grouped photos as an album of uploads' do
    ctx.url = 'https://t.me/album_channel/10'
    allow(Utils::HTTP).to receive(:get_public).and_return(fixture('album_post.html'))
    allow(Utils::HTTP).to receive(:download_public) do |media_url, path|
      File.binwrite(path, File.basename(media_url))
      'image/jpeg'
    end

    input = downloader.download

    expect(input.uploads.size).to eq(2)
    expect(input.uploads.map { |up| File.basename(up.fn_out) }).to eq(%w[telegram-10-1.jpg telegram-10-2.jpg])
  end

  it 'stores text-only posts as a captioned document' do
    ctx.url = 'https://t.me/notes/99'
    allow(Utils::HTTP).to receive(:get_public).and_return(fixture('text_post.html'))

    input = downloader.download

    expect(input.uploads.first.type.name).to eq(:document)
    expect(File.read(input.uploads.first.fn_out)).to eq('A text-only channel post.')
    expect(input.info.title).to eq('A text-only channel post.')
  end

  it 'still rejects private Telegram links from non-admin users' do
    ctx.url = 'https://t.me/c/123/456'

    expect { downloader.download }.to raise_error(/restricted/)
  end
end
