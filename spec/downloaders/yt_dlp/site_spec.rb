require 'rails_helper'

RSpec.describe Downloaders::YtDlp::Site do
  describe '.for' do
    it 'finds the site by host and its subdomains' do
      expect(described_class.for('https://rumble.com/v1-a.html')).to be_a(described_class::Rumble)
      expect(described_class.for('https://www.youtube.com/watch?v=a')).to be_a(described_class::Youtube)
      expect(described_class.for('https://youtu.be/a')).to be_a(described_class::Youtube)
      expect(described_class.for('https://x.bandcamp.com/track/y')).to be_a(described_class::Bandcamp)
    end

    it 'gives the defaults to any other host' do
      site = described_class.for('https://example.com/rumble.com')

      expect(site.class).to eq(described_class)
      expect(site.resolve('https://example.com/v')).to eq('https://example.com/v')
      expect(site.args(SymMash.new(alang: 'pt'))).to eq([])
    end
  end

  describe Downloaders::YtDlp::Site::Rumble do
    it 'resolves a watch page to its embed page through oembed' do
      body = {html: '<iframe src="https://rumble.com/embed/v79tk6m/" />'}.to_json
      allow(Utils::HTTP).to receive(:get_public).and_return(body)

      expect(subject.resolve('https://rumble.com/v7c086u-a.html?e9s=src_v1')).to eq('https://rumble.com/embed/v79tk6m/')
    end

    it 'keeps an embed page and the page when oembed fails' do
      allow(Utils::HTTP).to receive(:get_public).and_raise('boom')

      expect(subject.resolve('https://rumble.com/embed/v1/')).to eq('https://rumble.com/embed/v1/')
      expect(subject.resolve('https://rumble.com/v1-a.html')).to eq('https://rumble.com/v1-a.html')
    end
  end

  describe Downloaders::YtDlp::Site::Youtube do
    it 'asks for the audio language only when one is requested' do
      expect(subject.args(SymMash.new)).to eq([])
      expect(subject.args(SymMash.new(alang: 'pt')).first).to eq("--extractor-args #{Sh.escape('youtube:lang=pt;player_client=web_embedded,default')}")
    end

    it 'displays the short url of the video' do
      expect(subject.display(SymMash.new(id: 'abc'), 'https://www.youtube.com/watch?v=abc')).to eq('youtu.be/abc')
      expect(subject.display(SymMash.new, 'https://www.youtube.com/watch?v=abc')).to eq('youtube.com/watch?v=abc')
    end
  end
end
