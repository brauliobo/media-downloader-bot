require 'rails_helper'

RSpec.describe Streaming do
  let(:opts) { SymMash.new }

  before { Zipper.size_mb_limit = 50 }
  after  { Zipper.size_mb_limit = nil }

  describe '.enabled?' do
    it 'is on for non admins' do
      expect(described_class.enabled?(opts, admin: false)).to be true
    end

    it 'is off for admins unless they ask for it' do
      expect(described_class.enabled?(opts, admin: true)).to be false
      opts.stream = 1
      expect(described_class.enabled?(opts, admin: true)).to be true
    end

    it 'is off with nostream, for everybody' do
      opts.nostream = 1
      expect(described_class.enabled?(opts, admin: false)).to be false
      opts.stream = 1
      expect(described_class.enabled?(opts, admin: true)).to be false
    end

    it 'is off without a bot size limit' do
      Zipper.size_mb_limit = nil
      expect(described_class.enabled?(opts, admin: false)).to be false
    end

    it 'is off for every encoding option' do
      described_class::ENCODING_KEYS.each do |key|
        expect(described_class.enabled?(SymMash.new(key => 1), admin: false)).to be(false), key.to_s
      end
    end

    it 'stays on for audio extraction' do
      expect(described_class.enabled?(SymMash.new(audio: 1), admin: false)).to be true
    end

    it 'stays on when only a section is cut by ss, to or t' do
      %i[ss to t].each do |key|
        expect(described_class.enabled?(SymMash.new(key => '1m'), admin: false)).to be(true), key.to_s
      end
    end
  end

  describe '.fits?' do
    it 'requires the file to be under the limit' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'f.mp4')
        File.write(path, 'x')
        expect(described_class.fits?(path)).to be true
        Zipper.size_mb_limit = 0
        expect(described_class.fits?(path)).to be false
      end
    end
  end
end
