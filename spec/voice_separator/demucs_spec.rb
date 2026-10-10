require 'rails_helper'

RSpec.describe VoiceSeparator::Demucs do
  let(:dir) { Dir.mktmpdir('demucs-spec-') }
  let(:input) { File.join(dir, 'input.mp4') }
  let(:audio) { File.join(dir, 'input.mka') }
  let(:out) { File.join(dir, 'stems') }

  before do
    File.write(input, 'video')
    File.write(audio, 'audio')
    allow(Zipper::AudioOps).to receive(:copy).and_return(audio)
  end

  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

  def stem_zip
    zip = File.join(dir, 'stems.zip')
    File.write(File.join(dir, 'vocals.wav'), 'vocals')
    File.write(File.join(dir, 'no_vocals.wav'), 'other')
    Dir.chdir(dir) { raise 'zip failed' unless system('zip', '-q', zip, 'vocals.wav', 'no_vocals.wav') }
    File.binread(zip)
  end

  def zip64_stem_zip
    zip = File.join(dir, 'stems-zip64.zip')
    env = {
      'STEM_DIR' => dir,
      'STEM_ZIP' => zip
    }
    py = <<~'PY'
      import os, zipfile
      zipfile.ZIP64_LIMIT = 50
      folder = os.environ['STEM_DIR']
      open(os.path.join(folder, 'vocals.wav'), 'wb').write(b'vocals-zip64')
      open(os.path.join(folder, 'no_vocals.wav'), 'wb').write(b'other-zip64')
      with zipfile.ZipFile(os.environ['STEM_ZIP'], 'w', compression=zipfile.ZIP_STORED, allowZip64=True) as archive:
          archive.write(os.path.join(folder, 'vocals.wav'), 'vocals.wav')
          archive.write(os.path.join(folder, 'no_vocals.wav'), 'no_vocals.wav')
    PY
    raise 'zip64 failed' unless system(env, 'python3', '-c', py)
    data = File.binread(zip)
    raise 'zip64 fixture missing ZIP64 records' unless data.include?("PK\x06\x06")
    data
  end

  def stub_stems(body, status: 200)
    allow(described_class).to receive(:stream_separate) do |_file, archive|
      archive.write(body)
      status
    end
  end

  it 'posts extracted audio and unpacks vocal stems' do
    expect(described_class).to receive(:stream_separate) do |file, archive|
      expect(file).to be_a(File)
      expect(file.path).to eq(audio)
      archive.write(stem_zip)
      200
    end

    stems = described_class.separate(input, dir: out)

    expect(stems).to have_attributes(vocals: File.join(out, 'vocals.wav'), non_vocals: File.join(out, 'no_vocals.wav'))
    expect(File.read(stems.vocals)).to eq('vocals')
    expect(File.read(stems.non_vocals)).to eq('other')
    expect(File.exist?(audio)).to be(false)
  end

  it 'unpacks ZIP64 stem archives from Python zipfile' do
    stub_stems(zip64_stem_zip)

    stems = described_class.separate(input, dir: out)

    expect(File.read(stems.vocals)).to eq('vocals-zip64')
    expect(File.read(stems.non_vocals)).to eq('other-zip64')
  end

  it 'rejects a zip that is missing a stem' do
    zip = File.join(dir, 'partial.zip')
    File.write(File.join(dir, 'vocals.wav'), 'vocals')
    Dir.chdir(dir) { raise 'zip failed' unless system('zip', '-q', zip, 'vocals.wav') }
    stub_stems(File.binread(zip))

    expect { described_class.separate(input, dir: out) }
      .to raise_error('voice separation returned incomplete stems')
  end

  it 'preserves HTTP failure errors' do
    stub_stems('', status: 413)

    expect { described_class.separate(input, dir: out) }.to raise_error('voice separation failed: 413')
    expect(File.exist?(audio)).to be(false)
  end
end
