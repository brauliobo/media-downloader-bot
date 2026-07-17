require 'spec_helper'

RSpec.describe Bot::Worker::Client do
  let(:dir) { Dir.mktmpdir('worker-client-') }

  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

  it 'copies album uploads outside transient worker directories for proxy sends' do
    source = File.join(dir, 'photo.jpg')
    File.write(source, 'image')
    upload = SymMash.new(fn_out: source, mime: 'image/jpeg', type: SymMash.new(name: :document))
    client = described_class.allocate

    safe_uploads, cleanup_paths = client.send(:safe_album_uploads, [upload])

    expect(safe_uploads.first[:fn_out]).not_to eq(source)
    expect(File.exist?(safe_uploads.first[:fn_out])).to be(true)
  ensure
    Array(cleanup_paths).each { |path| FileUtils.rm_rf(path) }
  end

  it 'uses the remote bot caption limit' do
    client = described_class.allocate
    client.instance_variable_set(:@mode, :drb)
    client.instance_variable_set(:@drb, double(max_caption: 4096))

    expect(client.max_caption).to eq(4096)
  end

  it 'normalizes HTTP and DRb album results to the same shape' do
    client = described_class.allocate
    http   = client.send(:message_results, {'messages' => [{'id' => 123}]})
    drb    = client.send(:message_results, [{id: 123}])

    expect(http.map(&:id)).to eq([123])
    expect(drb.map(&:id)).to eq([123])
  end
end
