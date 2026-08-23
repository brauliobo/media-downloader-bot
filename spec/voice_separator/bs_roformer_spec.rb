require 'spec_helper'
require_relative '../../lib/voice_separator/bs_roformer'

RSpec.describe VoiceSeparator::BSRoformer do
  let(:dir) { Dir.mktmpdir('bs-roformer-spec-') }
  let(:input) { File.join(dir, 'input.mp4') }
  let(:audio) { File.join(dir, 'input.mka') }
  let(:out) { File.join(dir, 'stems') }

  before do
    File.write(input, 'video')
    File.write(audio, 'audio')
    allow(Zipper).to receive(:copy_audio).and_return(audio)
  end

  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

  it 'uses its own opt-in endpoint and the shared stem archive contract' do
    zip = File.join(dir, 'stems.zip')
    File.write(File.join(dir, 'vocals.wav'), 'vocals')
    File.write(File.join(dir, 'no_vocals.wav'), 'other')
    Dir.chdir(dir) { raise 'zip failed' unless system('zip', '-q', zip, 'vocals.wav', 'no_vocals.wav') }

    expect(described_class).to receive(:stream_separate) do |file, archive|
      expect(file.path).to eq(audio)
      archive.write(File.binread(zip))
      200
    end

    stems = described_class.separate(input, dir: out)

    expect(described_class.api.to_s).to eq('http://127.0.0.1:8085')
    expect(File.read(stems.vocals)).to eq('vocals')
    expect(File.read(stems.non_vocals)).to eq('other')
  end
end
