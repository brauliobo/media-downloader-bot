require 'spec_helper'

RSpec.describe UploadCoordinator do
  let(:dir)    { Dir.mktmpdir('upload-coordinator-') }
  let(:worker) { instance_double(Worker, opts: opts, msg: msg) }
  let(:opts)   { SymMash.new(album: 1) }
  let(:msg)    { SymMash.new(chat: {id: 1}) }

  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

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

  it 'flushes queued media as one album' do
    uploads = [item('1.jpg', 'image/jpeg'), item('2.jpg', 'image/jpeg')]
    allow(worker).to receive(:send).with(:translate_caption_info, uploads.first.info, opts)
    allow(worker).to receive(:send).with(:msg_caption, anything).and_return('caption')
    allow(worker).to receive(:send_album)

    coordinator = described_class.new(worker)
    uploads.each_with_index { |upload, i| coordinator.upload_or_queue(upload, i) }
    coordinator.flush

    expect(worker).to have_received(:send_album).with(msg, 'caption', uploads: uploads, parse_mode: 'MarkdownV2')
  end

  it 'uploads a single queued item normally' do
    upload = item('1.jpg', 'image/jpeg')
    allow(worker).to receive(:send).with(:upload_one, upload)

    coordinator = described_class.new(worker)
    coordinator.upload_or_queue(upload, 0)
    coordinator.flush

    expect(worker).to have_received(:send).with(:upload_one, upload)
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
end
