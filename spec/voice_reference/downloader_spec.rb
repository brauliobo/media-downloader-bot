require 'spec_helper'
require_relative '../../lib/voice_reference'

RSpec.describe VoiceReference::Downloader do
  it 'downloads the link through the shared yt-dlp audio path' do
    Dir.mktmpdir('voice-reference-downloader-') do |dir|
      downloaded = File.join(dir, 'voice.webm')
      downloader = instance_double(Downloaders::YtDlp)
      allow(Downloaders::YtDlp).to receive(:new).and_return(downloader)
      allow(downloader).to receive(:download_one) do |input|
        expect(input.url).to eq('https://example.com/voice')
        expect(input.opts.audio).to eq(1)
        input.fn_in = downloaded
      end

      expect(described_class.new.call('https://example.com/voice', dir: dir)).to eq(downloaded)
    end
  end
end
