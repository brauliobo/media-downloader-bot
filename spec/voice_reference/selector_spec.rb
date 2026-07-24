require 'spec_helper'
require_relative '../../lib/voice_reference'

RSpec.describe VoiceReference::Selector do
  let(:analyzer) do
    instance_double(VoiceReference::AudioAnalyzer).tap do |value|
      allow(value).to receive(:assess) do |candidate|
        quality = candidate.audio == 'clean.webm' ? 0.9 : 0.2
        candidate.score = quality + candidate.confidence * 0.2
        candidate
      end
    end
  end

  it 'selects intelligible English speech with the strongest signal quality' do
    selector = described_class.new(analyzer: analyzer)
    selected = selector.select([
      recording('clean.webm', probability: 0.92),
      recording('noisy.webm', probability: 0.99)
    ])

    expect(selected.audio).to eq('clean.webm')
    expect(selected.text).to include('clear English reference passage')
  end

  it 'rejects non-English and repetitive Whisper hallucinations' do
    selector = described_class.new(analyzer: analyzer)
    repetitive = Array.new(20, 'the same words').join(' ')
    selected = selector.select([
      recording('non-english.webm', language: 'hi', probability: 0.99),
      recording('repetitive.webm', probability: 0.99, text: repetitive)
    ])

    expect(selected).to be_nil
  end

  it 'combines adjacent Whisper segments into a reference-length passage' do
    selector = described_class.new(analyzer: analyzer)
    transcript = {
      language: 'en',
      segments: [
        segment(0, 6.5, 'The supreme goal is the hub of the universe that controls'),
        segment(6.5, 15, 'everything and is above the world of movements.'),
        segment(15, 30, 'This segment falls beyond the maximum reference duration and must not be included.')
      ]
    }

    selected = selector.select([{audio: 'clean.webm', transcript: transcript}])

    expect(selected.start).to eq(0)
    expect(selected.finish).to eq(15)
    expect(selected.text).to eq(
      'The supreme goal is the hub of the universe that controls everything and is above the world of movements.'
    )
  end

  it 'compares complete passages from each recording instead of global confidence leaders' do
    selector = described_class.new(analyzer: analyzer)
    noisy_segments = 6.times.map do |index|
      segment(index * 13, index * 13 + 12, "Sentence #{index} has enough distinct English words for candidate selection.")
    end
    noisy_segments.each { |segment| segment[:probabilities] = Array.new(12, 0.99) }

    selected = selector.select([
      {audio: 'noisy.webm', transcript: {language: 'en', segments: noisy_segments}},
      recording('clean.webm', probability: 0.9)
    ])

    expect(selected.audio).to eq('clean.webm')
  end

  it 'rejects passages that start or end inside a sentence' do
    selector = described_class.new(analyzer: analyzer)
    transcript = {
      language: 'en',
      segments: [
        segment(0, 15, 'The sentence begins here with several distinct words and continues,'),
        segment(15, 25, 'then it may create something good or something bad for the universe.')
      ]
    }

    expect(selector.select([{audio: 'clean.webm', transcript: transcript}])).to be_nil
  end

  def recording(audio, language: 'en', probability:, text: nil)
    text ||= 'This clear English reference passage contains enough distinct words for reliable selection and later reuse.'
    {
      audio: audio,
      transcript: {
        language: language,
        segments: [{
          start: 0,
          finish: 12,
          text: text,
          probabilities: Array.new(text.split.size, probability)
        }]
      }
    }
  end
  def segment(start, finish, text)
    {
      start: start,
      finish: finish,
      text: text,
      probabilities: Array.new(text.split.size, 0.95)
    }
  end
end
