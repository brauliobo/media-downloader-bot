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

  describe 'inside a job' do
    around { |example| Dir.mktmpdir('job-') { |home| described_class.within(home) { example.run } } }

    it 'gives the same directory to the same work, which an interrupted block leaves behind' do
      first = nil
      expect { described_class.resumable('book-', %w[a b]) { |dir| File.write(File.join(first = dir, 'done'), 'x'); raise 'killed' } }.to raise_error('killed')

      described_class.resumable('book-', %w[a b]) { |dir| expect([dir, File.exist?(File.join(dir, 'done'))]).to eq [first, true] }
      expect(File.exist?(first)).to be(false)
    end

    it 'gives other work a directory of its own' do
      dirs = [%w[a b], %w[a c]].map { |key| described_class.resumable('book-', key) { |dir| dir } }

      expect(dirs.uniq.size).to eq 2
    end

    it 'computes a text once for the same file and key' do
      file  = File.join(described_class.root, 'page.png').tap { |path| File.write(path, 'image') }
      calls = []
      read  = ->(**key) { described_class.cached('ocr', file, **key) { calls << key; 'text' } }

      expect([read.call(lang: 'pt'), read.call(lang: 'pt'), read.call(lang: 'en')]).to eq %w[text text text]
      expect(calls).to eq [{ lang: 'pt' }, { lang: 'en' }]
      File.write(file, 'another image')
      read.call(lang: 'pt')
      expect(calls.size).to eq 3
    end
  end

  describe 'outside a job' do
    it 'keeps nothing' do
      calls = 0
      2.times { described_class.cached('ocr', 'missing.png') { calls += 1 } }
      dirs = 2.times.map { described_class.resumable('book-', 'k') { |dir| dir } }

      expect(calls).to eq 2
      expect(dirs.uniq.size).to eq 2
      expect(dirs.map { |dir| File.exist?(dir) }).to eq [false, false]
    end
  end
end
