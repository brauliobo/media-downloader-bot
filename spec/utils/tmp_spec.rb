require 'rails_helper'

RSpec.describe Utils::Tmp do
  it 'keeps the root, directories and files inside the dir given to within, child processes included' do
    Dir.mktmpdir do |home|
      described_class.within(home) do
        expect(described_class.root).to eq(home)
        expect(described_class.path('x-', '.png')).to start_with("#{home}/x-").and end_with('.png')
        expect(`printf %s "$TMPDIR"`).to eq(home)
        described_class.dir('d-') { |dir| expect(File.dirname(dir)).to eq(home) }
      end
    end
  end

  it 'restores the previous root afterwards' do
    before = ENV['TMPDIR']
    Dir.mktmpdir { |home| described_class.within(home) { } }
    expect(ENV['TMPDIR']).to eq(before)
  end

  it 'removes the file path once the block ends, even on error' do
    seen = nil
    expect { described_class.file('f-', '.txt') { |path| File.write(seen = path, 'x'); raise 'boom' } }.to raise_error('boom')
    expect(File.exist?(seen)).to be(false)
  end
end
