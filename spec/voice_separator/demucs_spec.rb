require 'spec_helper'
require_relative '../../lib/voice_separator/demucs'

RSpec.describe VoiceSeparator::Demucs do
  let(:dir) { Dir.mktmpdir('demucs-spec-') }
  let(:input) { File.join(dir, 'input.mp4') }
  let(:audio) { File.join(dir, 'input.mka') }
  let(:out) { File.join(dir, 'stems') }

  before do
    File.write(input, 'video')
    File.write(audio, 'audio')
    allow(Zipper).to receive(:copy_audio).and_return(audio)
    allow(Utils::HTTP).to receive(:client)
  end

  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

  def stem_zip
    zip = File.join(dir, 'stems.zip')
    File.write(File.join(dir, 'vocals.wav'), 'vocals')
    File.write(File.join(dir, 'no_vocals.wav'), 'other')
    Dir.chdir(dir) { raise 'zip failed' unless system('zip', '-q', zip, 'vocals.wav', 'no_vocals.wav') }
    File.binread(zip)
  end

  it 'posts extracted audio and unpacks vocal stems' do
    response = double(code: '200', body: stem_zip)
    expect(Utils::HTTP).to receive(:post) do |url, params|
      expect(url).to eq('http://127.0.0.1:8084/v1/separate')
      expect(params[:file]).to be_a(File)
      expect(params[:file].path).to eq(audio)
      response
    end

    stems = described_class.separate(input, dir: out)

    expect(stems).to have_attributes(vocals: File.join(out, 'vocals.wav'), non_vocals: File.join(out, 'no_vocals.wav'))
    expect(File.read(stems.vocals)).to eq('vocals')
    expect(File.read(stems.non_vocals)).to eq('other')
    expect(File.exist?(audio)).to be(false)
  end

  it 'preserves HTTP failure errors' do
    allow(Utils::HTTP).to receive(:post).and_return(double(code: '413'))

    expect { described_class.separate(input, dir: out) }.to raise_error('voice separation failed: 413')
    expect(File.exist?(audio)).to be(false)
  end
end
