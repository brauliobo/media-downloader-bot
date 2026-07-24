require 'spec_helper'
require_relative '../../lib/audiobook/ewprs'

RSpec.describe Audiobook::Ewprs do
  around do |example|
    original = ENV.delete('EWPRS_VOICE_REFERENCE')
    example.run
  ensure
    original ? ENV['EWPRS_VOICE_REFERENCE'] = original : ENV.delete('EWPRS_VOICE_REFERENCE')
  end

  it 'uses the recorded reference and neutral English instruction when configured' do
    Dir.mktmpdir('ewprs-') do |root|
      reference = File.join(root, 'speaker.wav')
      File.write(reference, 'wav')
      File.write(File.join(root, 'speaker.txt'), "An exact recorded reference sentence.\n")
      ENV['EWPRS_VOICE_REFERENCE'] = reference
      entry = described_class::Entry.new(kind: :discourse, path: '/tmp/discourse.html')

      options = described_class.new(root).parse_options(entry)

      expect(options.instruct).to eq('male, middle-aged, moderate pitch, neutral English accent')
      expect(options.speaker_wav).to eq(reference)
      expect(options.ref_text).to eq('An exact recorded reference sentence.')
    end
  end
end
