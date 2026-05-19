require 'spec_helper'

RSpec.describe Output do
  describe '.filename' do
    it 'does not append the same extension twice' do
      info = SymMash.new(title: 'clip.mp4')

      expect(described_class.filename(info, dir: '/tmp', ext: :mp4)).to eq('/tmp/clip.mp4')
    end

    it 'appends the extension when it is missing' do
      info = SymMash.new(title: 'clip')

      expect(described_class.filename(info, dir: '/tmp', ext: :mp4)).to eq('/tmp/clip.mp4')
    end
  end
end
