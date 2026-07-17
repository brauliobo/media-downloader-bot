require 'spec_helper'
require 'tmpdir'
require_relative '../../lib/bot/tg_bot'
require_relative '../support/spy_bot'

RSpec.describe 'DeepSec regressions' do
  let(:probe) do
    SymMash.new(
      format:  SymMash.new(duration: 60),
      streams: [SymMash.new(codec_type: 'video', width: 640, height: 360)],
    )
  end

  it 'downloads Telegram files under the requested directory with a safe basename' do
    Dir.mktmpdir('tg-download-') do |dir|
      bot = Bot::TgBot.new
      bot.tg = double(get_file: SymMash.new(file_path: 'documents/original.txt'))

      page = double(body: 'safe body')
      agent = double(get: page)
      allow(agent).to receive(:redirect_ok=)
      allow(Mechanize).to receive(:new).and_return(agent)

      info = SymMash.new(file_id: 'abc', file_name: '../../owned.txt')
      path = bot.download_file(info, dir: dir)

      expect(path).to eq(File.join(dir, 'owned.txt'))
      expect(File.read(path)).to eq('safe body')
      expect(File.exist?(File.expand_path('../owned.txt', dir))).to be(false)
    end
  end

  it 'rejects unsafe ffmpeg filter fragments from options' do
    opts = SymMash.new(
      vf:       'scale=1";touch$IFS/tmp/pwn;"',
      format:   Zipper::Types.video.h264,
      acodec:   'aac',
      metadata: {},
    )

    expect {
      Zipper.new('/tmp/in.mp4', '/tmp/out.mp4', probe: probe, opts: opts)
    }.to raise_error(ArgumentError, /unsafe video filter/)
  end

  it 'rejects unsafe subtitle extensions before writing temp input' do
    expect {
      Subtitler::VTT.to_vtt('1', '../evil')
    }.to raise_error(ArgumentError, /unsupported subtitle extension/)
  end

  it 'sanitizes Netscape cookie delimiters' do
    Dir.mktmpdir('cookies-') do |dir|
      cookies = {'example.com' => "sid=abc\n.example.org\tTRUE\t/\tFALSE\t0\tx\ty"}
      session = double(cookies: cookies)
      allow(session).to receive(:reload).and_return(session)
      path = Utils::CookieJar.write(session, dir)
      lines = File.read(path).lines

      expect(lines.size).to eq(2)
      expect(lines.last).not_to include("\n.example.org")
      expect(lines.last.split("\t").size).to eq(7)
    end
  end

  it 'does not treat thumbnail metadata as an arbitrary local path' do
    info = SymMash.new(thumbnail: __FILE__, width: 100, height: 100)

    expect(Utils::Thumb.process(info, base_filename: File.join(Dir.tmpdir, 'thumb-test'))).to be_nil
  end

  it 'uses remote thumbnail entries when the primary thumbnail is absent' do
    info = SymMash.new(thumbnails: [{url: 'https://img.example/small.jpg'}, {url: 'https://img.example/large.jpg'}])
    allow(Utils::Safety).to receive(:public_http_url?).with('https://img.example/large.jpg').and_return(true)
    allow(Utils::HTTP).to receive(:get_public).with('https://img.example/large.jpg').and_return("\xFF\xD8\xFFjpeg".b)
    allow(Sh).to receive(:run)

    expect(Utils::Thumb.process(info, base_filename: File.join(Dir.tmpdir, 'thumb-test'))).to end_with('-othumb.jpg')
  end

  it 'keeps generated video thumbnails within Telegram dimensions' do
    Dir.mktmpdir('thumb-size-') do |dir|
      src = File.join(dir, 'source.jpg')
      system('convert', '-size', '640x360', 'xc:red', src)

      info = SymMash.new(thumbnail: src, width: 640, height: 360)
      thumb = Utils::Thumb.process(info, base_filename: File.join(dir, 'thumb'), local: true)
      width, height = `identify -format '%w %h' #{thumb.shellescape}`.split.map(&:to_i)

      expect([width, height].max).to be <= 320
    end
  end

  it 'wraps paid video upload thumbnails as Telegram attachments' do
    bot = Bot::TgBot.new
    media = SymMash.new(type: :video, media: 'attach://file', thumbnail_path: __FILE__)
    params = bot.wrap_upload_params(type: :paid_media, file_path: __FILE__, file_mime: 'video/mp4', media: [media])

    expect(params[:thumbnail]).to be_a(Faraday::UploadIO)
    expect(params[:media].first[:thumbnail]).to eq('attach://thumbnail')
    expect(params[:media].first).not_to have_key(:thumbnail_path)
  end

  it 'wraps regular video thumbnails with legacy and current Telegram fields' do
    bot = Bot::TgBot.new
    params = bot.wrap_upload_params(type: :video, video_path: __FILE__, video_mime: 'video/mp4', thumb_path: __FILE__)

    expect(params[:thumb]).to be_a(Faraday::UploadIO)
    expect(params[:thumbnail]).to be_a(Faraday::UploadIO)
    expect(params).not_to have_key(:thumb_path)
    expect(params).not_to have_key(:thumbnail_path)
  end

  it 'passes one canonical video thumbnail path from workers' do
    Dir.mktmpdir('worker-thumb-') do |dir|
      bot = Bot::Spy.new
      old_service = Worker.service
      old_debug = ENV['DEBUG']
      Worker.service = bot
      ENV.delete('DEBUG')
      video = File.join(dir, 'video.mp4')
      thumb = File.join(dir, 'thumb.jpg')
      File.write(video, 'video')
      File.write(thumb, 'thumb')

      worker = Worker.new(SymMash.new(from: {id: 1}, chat: {id: 1}))
      item = SymMash.new(
        fn_out: video,
        thumb:  thumb,
        type:   Zipper::Types.video,
        info:   SymMash.new(title: 'video', uploader: 'uploader'),
        opts:   SymMash.new(format: SymMash.new(mime: 'video/mp4')),
        oprobe: SymMash.new(format: SymMash.new(duration: 1), streams: [SymMash.new(codec_type: 'video', width: 320, height: 180)])
      )
      worker.instance_variable_set(:@opts, item.opts)

      worker.upload(item)

      expect(bot.uploads.last.params[:thumb_path]).to eq(thumb)
      expect(bot.uploads.last.params).not_to have_key(:thumbnail_path)
    ensure
      Worker.service = old_service
      ENV['DEBUG'] = old_debug
    end
  end

  it 'ignores genshorts paths outside the working directory' do
    Dir.mktmpdir('shorts-') do |dir|
      processor = Processors::Shorts.new(dir: dir)

      expect(processor.send(:local_genshorts_path?, __FILE__)).to be(false)
    end
  end

  it 'falls back for unsafe tesseract language codes' do
    expect(Ocr::Tesseract.map_to_tesseract_lang(';ls')).to eq('eng')
  end

  it 'rejects private and IPv4-mapped loopback URLs' do
    expect(Utils::Safety.public_http_url?('http://127.0.0.1/')).to be(false)
    expect(Utils::Safety.public_ip?('::ffff:127.0.0.1')).to be(false)
  end

  it 'requires worker HTTP authentication' do
    old_token = ENV.delete('BOT_HTTP_TOKEN')
    request = double(get_header: '')
    expect(Bot::Worker::HTTPService.allocate.authorized?(request)).to be(false)
  ensure
    ENV['BOT_HTTP_TOKEN'] = old_token
  end

  it 'rejects worker upload symlinks that escape allowed roots' do
    Dir.mktmpdir('http-root-') do |dir|
      link = File.join(dir, 'upload')
      File.symlink(__FILE__, link)
      service = Bot::Worker::HTTPService.allocate
      allow(service).to receive(:allowed_roots).and_return([dir])

      expect { service.require_allowed_path!(link) }.to raise_error(ArgumentError)
    end
  end

  it 'preserves Netscape cookie scope and security attributes' do
    input = "#HttpOnly_.example.com\tTRUE\t/account\tTRUE\t123\tsid\tsecret\n"
    stored = Utils::CookieJar.parse_netscape(input)

    Dir.mktmpdir('cookies-') do |dir|
      session = double(cookies: stored, reload: nil)
      allow(session).to receive(:reload).and_return(session)
      line = File.readlines(Utils::CookieJar.write(session, dir)).last
      expect(line).to eq("#HttpOnly_.example.com\tTRUE\t/account\tTRUE\t123\tsid\tsecret\n")
    end
  end

  it 'imports cookie documents from a private temporary directory' do
    document = SymMash.new(file_id: 'cookie', file_name: 'Gemfile', file_size: 10)
    msg = SymMash.new(document: document, text: '')
    bot = double
    command = Manager::Commands::Cookie.new(bot, msg)
    allow(bot).to receive(:download_file) do |_, dir:|
      expect(dir).not_to eq(Dir.pwd)
      File.binwrite(File.join(dir, 'Gemfile'), 'cookie data')
      File.join(dir, 'Gemfile')
    end

    expect(command.send(:extract_cookie_content)).to eq('cookie data')
  end

  it 'rejects private Telegram links from non-admin users' do
    msg = SymMash.new(from: {id: 123}, bot: double)
    ctx = Context.new(url: 'https://t.me/c/123/456', opts: SymMash.new, msg: msg)

    expect { Downloaders::Telegram.new(ctx).download }.to raise_error(/restricted/)
  end
end
