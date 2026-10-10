require 'rails_helper'

RSpec.describe Worker::UploadCoordinator do
  let(:dir)    { Dir.mktmpdir('upload-coordinator-') }
  let(:worker) { instance_double(Worker, opts: opts, msg: msg, caption_limit: 1024) }
  let(:opts)   { SymMash.new(album: 1) }
  let(:msg)    { SymMash.new(chat: {id: 1}) }

  before do
    Worker.skip_cleanup = false
    allow(worker).to receive(:cleanup_input)
  end

  after do
    Worker.skip_cleanup = false
    FileUtils.remove_entry(dir) if Dir.exist?(dir)
  end

  def item(name, mime)
    path = File.join(dir, name)
    File.write(path, '')
    SymMash.new(
      fn_out: path,
      mime:   mime,
      type:   SymMash.new(name: mime.start_with?('video/') ? :video : :document),
      opts:   opts,
      url:    'https://x.com/i/status/1',
      info:   SymMash.new(title: name, description: '')
    )
  end

  it 'flushes queued mixed media as one album' do
    uploads = [item('1.jpg', 'image/jpeg'), item('2.mp4', 'video/mp4')]
    allow(worker).to receive(:album_caption).with(uploads).and_return('_caption_')
    allow(worker).to receive(:send_album)

    coordinator = described_class.new(worker)
    uploads.each_with_index { |upload, i| coordinator.upload_or_queue(upload, i) }
    coordinator.flush

    expect(worker).to have_received(:send_album).with(msg, '_caption_', uploads: uploads, parse_mode: 'MarkdownV2')
    expect(worker).to have_received(:cleanup_input).with(have_attributes(uploads: uploads))
  end

  it 'combines the title and link of every queued item into the album caption' do
    real_worker = Worker.new(SymMash.new(from: {id: 1}, chat: {id: 1}))
    uploads     = [item('1.mp4', 'video/mp4'), item('2.mp4', 'video/mp4')]
    uploads.each_with_index { |upload, i| upload.merge!(url: "https://x.com/i/status/#{i + 1}") }
    allow(real_worker).to receive(:send_album)
    allow(real_worker).to receive(:cleanup_input)
    real_worker.instance_variable_set(:@opts, opts)

    coordinator = described_class.new(real_worker)
    uploads.each_with_index { |upload, i| coordinator.upload_or_queue(upload, i) }
    coordinator.flush

    caption = "_1\\.mp4_\n\nx\\.com\\/i\\/status\\/1\n\n_2\\.mp4_\n\nx\\.com\\/i\\/status\\/2"
    expect(real_worker).to have_received(:send_album).with(real_worker.msg, caption, uploads: uploads, parse_mode: 'MarkdownV2')
  end

  it 'shares the caption limit between the album items' do
    real_worker = Worker.new(SymMash.new(from: {id: 1}, chat: {id: 1}))
    uploads     = Array.new(3) { |i| item("#{i}.mp4", 'video/mp4').merge!(info: SymMash.new(title: 'a' * 2_000, description: '')) }

    expect(real_worker.album_caption(uploads).size).to be <= real_worker.caption_limit
  end

  it 'uploads a single queued item normally' do
    upload = item('1.jpg', 'image/jpeg')
    allow(worker).to receive(:upload_item).with(upload)

    coordinator = described_class.new(worker)
    coordinator.upload_or_queue(upload, 0)
    coordinator.flush

    expect(worker).to have_received(:upload_item).with(upload)
    expect(worker).to have_received(:cleanup_input).with(upload)
  end

  it 'removes input files after uploading them' do
    real_worker = Worker.new(SymMash.new(from: {id: 1}, chat: {id: 1}))
    real_worker.instance_variable_set(:@dir, dir)
    upload = item('1.mp4', 'video/mp4')
    input  = File.join(dir, 'input.mp4')
    File.write(input, '')
    upload.fn_in = input
    allow(real_worker).to receive(:upload_item)

    described_class.new(real_worker).upload(upload)

    expect(File.exist?(input)).to be(false)
    expect(File.exist?(upload.fn_out)).to be(false)
  end

  it 'preserves generated files when cleanup is disabled' do
    real_worker = Worker.new(
      SymMash.new(from: {id: 1}, chat: {id: 1}),
      skip_cleanup: true
    )
    real_worker.instance_variable_set(:@dir, dir)
    upload = item('1.mp4', 'video/mp4')
    allow(real_worker).to receive(:upload_item)

    described_class.new(real_worker).upload(upload)

    expect(File.exist?(upload.fn_out)).to be(true)
  end

  it 'parses bare album as an upload option' do
    parsed = SymMash.new(metadata: {})

    Processors::Base.add_opt(parsed, 'album')

    expect(parsed.album).to eq(1)
    expect(parsed.metadata).not_to have_key(:album)
  end

  it 'keeps album values as metadata' do
    parsed = SymMash.new(metadata: {})

    Processors::Base.add_opt(parsed, 'album=Name')

    expect(parsed.album).to be_nil
    expect(parsed.metadata.album).to eq('Name')
  end

  it 'translates dubbed album captions without changing shared source info' do
    real_worker = Worker.new(SymMash.new(from: {id: 1}, chat: {id: 1}))
    uploads     = [item('1.jpg', 'image/jpeg'), item('2.jpg', 'image/jpeg')]
    input       = SymMash.new(
      opts:    opts.merge(caption: 1, dub_lang: 'pt'),
      info:    SymMash.new(title: 'English caption', language: 'en', description: ''),
      url:     'https://x.com/i/status/2073169414275350804',
      uploads: uploads
    )

    allow(Translator).to receive(:translate).with('English caption', from: 'en', to: 'pt').and_return('Legenda em portugues')
    allow(real_worker).to receive(:send_album)

    described_class.new(real_worker).upload(input)

    expect(real_worker).to have_received(:send_album).with(
      real_worker.msg,
      '_Legenda em portugues_' + "\n\n" + 'x\.com\/i\/status\/2073169414275350804',
      uploads: uploads,
      parse_mode: 'MarkdownV2'
    )
    expect(input.info.title).to eq('English caption')
  end
end
