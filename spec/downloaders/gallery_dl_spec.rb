require 'spec_helper'

RSpec.describe Downloaders::GalleryDl do
  let(:dir)  { Dir.mktmpdir('gallery-dl-spec-') }
  let(:tmp)  { Dir.mktmpdir('gallery-dl-tmp-', dir) }
  let(:opts) { SymMash.new }
  let(:ctx)  { Context.new(dir: dir, tmp: tmp, url: 'https://x.com/i/status/1', opts: opts) }

  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

  describe '.supports?' do
    it 'routes social gallery URLs' do
      expect(described_class.supports?(ctx)).to eq(true)
    end

    it 'leaves video-first sites to yt-dlp' do
      ctx.url = 'https://youtube.com/watch?v=1'
      expect(described_class.supports?(ctx)).to eq(false)
    end
  end

  describe '#download' do
    it 'returns document uploads for downloaded files' do
      allow(Sh).to receive(:run) do |_cmd, **_|
        FileUtils.mkdir_p(File.join(tmp, 'twitter'))
        File.write(File.join(tmp, 'twitter', 'photo.jpg'), '')
        ['', '', 0]
      end

      input = described_class.new(ctx).download

      expect(input.uploads.size).to eq(1)
      expect(input.uploads.first.type.name).to eq(:document)
      expect(input.uploads.first.mime).to eq('image/jpeg')
    end
  end
end
