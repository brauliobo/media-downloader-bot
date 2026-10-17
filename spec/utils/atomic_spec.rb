require 'rails_helper'

RSpec.describe Utils::Atomic do
  around { |example| Dir.mktmpdir('atomic-') { |dir| @dir = dir; example.run } }

  let(:path) { File.join(@dir, 'sentence.wav') }

  it 'leaves the file only once it is whole, under the name asked' do
    described_class.write(path) do |part|
      File.write(part, 'whole')

      expect(File.exist?(path)).to be(false)
      expect(File.basename(part)).to end_with('-sentence.wav')
    end

    expect(File.read(path)).to eq('whole')
    expect(Dir.children(@dir)).to eq(['sentence.wav'])
  end

  it 'leaves nothing a resumed run would take for done when the run dies halfway' do
    expect { described_class.write(path) { |part| File.write(part, 'half'); raise 'killed' } }.to raise_error('killed')

    expect(File.exist?(path)).to be(false)
    expect(Dir.children(@dir)).to be_empty
  end

  it 'keeps the previous file when a new one dies halfway' do
    File.write(path, 'previous')

    expect { described_class.write(path) { |part| File.write(part, 'half'); raise 'killed' } }.to raise_error('killed')

    expect(File.read(path)).to eq('previous')
  end

  it 'writes and copies the same way' do
    source = File.join(@dir, 'source.wav').tap { |file| File.binwrite(file, 'data') }

    described_class.binwrite(path, 'bytes')
    copy = described_class.copy(source, File.join(@dir, 'copy.wav'))

    expect(File.binread(path)).to eq('bytes')
    expect(File.binread(copy)).to eq('data')
  end
end
