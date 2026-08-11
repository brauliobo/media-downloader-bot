require 'spec_helper'
require_relative '../../lib/dubbing/timing_score'

RSpec.describe Dubbing::TimingScore do
  def clip(start:, finish:)
    Dubbing::Audio::Clip.new(path: 'speech.wav', start: start, end: finish)
  end

  def scheduled(start:, finish:, speed:)
    Dubbing::Audio::ScheduledClip.new(path: 'speech.wav', start: start, end: finish, speed: speed)
  end

  it 'scores natural-speed clips in their subtitle slots as zero deviation' do
    score = described_class.call(
      [clip(start: 1.0, finish: 3.0)],
      [scheduled(start: 1.0, finish: 3.0, speed: 1.0)]
    )

    expect(score).to include(
      version:            1,
      sentence_count:     1,
      deviation_index:    0.0,
      slot_deviation_ms:  0.0,
      speed_min:          1.0,
      speed_p10:          1.0,
      speed_median:       1.0,
      speed_p90:          1.0,
      speed_max:          1.0,
      worst_sentences:    [{index: 1, start: 1.0, end: 3.0, speed: 1.0, deviation: 0.0}]
    )
  end

  it 'penalizes acceleration logarithmically' do
    expected = [clip(start: 0.0, finish: 1.0)]
    fast = described_class.call(expected, [scheduled(start: 0.0, finish: 1.0, speed: 2.0)])

    expect(fast.fetch(:deviation_index)).to eq(100.0)
  end
end
