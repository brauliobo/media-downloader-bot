require 'rails_helper'

RSpec.describe Bot::Worker::AlbumProxy do
  let(:dir) { Dir.mktmpdir('album-proxy-') }

  after { FileUtils.remove_entry(dir) }

  it 'copies album uploads outside transient worker directories for proxy sends' do
    source = File.join(dir, 'photo.jpg')
    File.write(source, 'image')
    upload = SymMash.new(fn_out: source, mime: 'image/jpeg', type: SymMash.new(name: :document))
    staged = nil

    described_class.stage([upload]) do |payloads|
      staged = payloads.first[:fn_out]
      expect(staged).not_to eq(source)
      expect(File.read(staged)).to eq('image')
      expect(payloads.first).to include(mime: 'image/jpeg', type: { name: :document })
    end

    expect(File.exist?(staged)).to be(false)
  end
end
