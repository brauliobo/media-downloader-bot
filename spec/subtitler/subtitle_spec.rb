require 'spec_helper'

RSpec.describe Subtitler::Subtitle do
  describe '.from_whisper_verbose_json' do
    let(:input) do
      {
        'language' => 'en',
        'text' => ' Hello world',
        'task' => 'transcribe',
        'segments' => [
          {
            'id' => 7,
            'start' => 0,
            'end' => 1.25,
            'text' => ' Hello world',
            'speaker_id' => 2,
            'cue_id' => 'cue-7',
            'words' => [
              {
                'word' => ' Hello',
                'start' => 0,
                'end' => 0.5,
                'probability' => 0.91,
                'backend_token' => 41,
              },
              {
                'word' => ' world',
                'start' => 0.6,
                'end' => 1.25,
                'confidence' => 0.87,
              },
            ],
          },
        ],
      }
    end

    it 'loads canonical values and preserves backend fields as metadata' do
      subtitle = described_class.from_whisper_verbose_json(JSON.generate(input))
      entry    = subtitle.entries.first

      expect(subtitle).to have_attributes(language: 'en', text: ' Hello world', metadata: {'task' => 'transcribe'})
      expect(entry).to have_attributes(
        start: 0.0, finish: 1.25, text: ' Hello world', speaker_id: 2, cue_id: 'cue-7', metadata: {'id' => 7}
      )
      expect(entry.words.map(&:text)).to eq([' Hello', ' world'])
      expect(entry.words.map(&:confidence)).to eq([0.91, 0.87])
      expect(entry.words.first.metadata).to eq('probability' => 0.91, 'backend_token' => 41)
    end

    it 'round-trips external end, word, confidence aliases, and unknown fields' do
      subtitle = described_class.from_whisper_verbose_json(input)

      expect(subtitle.to_whisper_verbose_hash).to eq(input)
    end

    it 'rejects non-JSON key types and missing required fields' do
      expect { described_class.from_whisper_verbose_json(language: 'en') }
        .to raise_error(ArgumentError, 'subtitle keys must be strings')
      expect { described_class.from_whisper_verbose_json('language' => 'en') }
        .to raise_error(KeyError, /text/)
    end
  end

  describe '.from_transcribe_cpp_json' do
    let(:input) do
      {
        'language' => 'pt',
        'text' => 'Olá',
        'model' => 'small',
        'segments' => [
          {
            't0_ms' => 250,
            't1_ms' => 1250,
            'text' => 'Olá',
            'temperature' => 0,
            'words' => [
              {
                't0_ms' => 250,
                't1_ms' => 1250,
                'text' => 'Olá',
                'prob' => 0.8,
                'token_id' => 9,
              },
            ],
          },
        ],
      }
    end

    it 'converts millisecond timing to float seconds and retains metadata' do
      subtitle = described_class.from_transcribe_cpp_json(input)
      entry    = subtitle.entries.first
      word     = entry.words.first

      expect(subtitle.metadata).to eq('model' => 'small')
      expect(entry).to have_attributes(start: 0.25, finish: 1.25, metadata: {'temperature' => 0})
      expect(word).to have_attributes(text: 'Olá', start: 0.25, finish: 1.25, confidence: 0.8)
      expect(word.metadata).to eq('prob' => 0.8, 'token_id' => 9)
    end

    it 'serializes canonical timing and text through transcribe.cpp adapters' do
      subtitle = described_class.from_transcribe_cpp_json(input)

      expect(subtitle.to_transcribe_cpp_hash).to eq(input)
    end
  end

  describe 'domain mutation' do
    let(:first_word) do
      described_class::Word.new(text: 'Hello', start: 1, finish: 2, metadata: {'token' => {'id' => 1}})
    end
    let(:entry) do
      described_class::Entry.new(start: 1, finish: 3, text: 'Original', words: [first_word], metadata: {'id' => 4})
    end
    let(:subtitle) do
      described_class.new(language: 'en', text: 'Transcript', entries: [entry], metadata: {'source' => ['api']})
    end

    it 'keeps text and words independent until synchronization is requested' do
      second_word = described_class::Word.new(text: 'world', start: 2, finish: 3)

      expect(entry.replace_text!('Edited').words).to eq([first_word])
      expect(entry.replace_words!([first_word, second_word]).text).to eq('Edited')

      entry.rebuild_text_from_words!

      expect(entry.text).to eq('Hello world')
    end

    it 'retimes nested words proportionally and scales all document timing' do
      entry.retime!(start: 3, finish: 7)

      expect(entry).to have_attributes(start: 3.0, finish: 7.0)
      expect(first_word).to have_attributes(start: 3.0, finish: 5.0)

      subtitle.scale_timing!(0.5)

      expect(entry).to have_attributes(start: 1.5, finish: 3.5)
      expect(first_word).to have_attributes(start: 1.5, finish: 2.5)
    end

    it 'assigns speakers and merges entries without sharing incoming words' do
      incoming_word = described_class::Word.new(text: 'again', start: 3.1, finish: 4)
      incoming = described_class::Entry.new(
        start: 3.1, finish: 4, text: 'again', words: [incoming_word], speaker_id: 6, metadata: {'next' => true}
      )

      entry.merge!(incoming)

      expect(entry).to have_attributes(start: 1.0, finish: 4.0, text: 'Original again', speaker_id: 6)
      expect(entry.words.map(&:text)).to eq(%w[Hello again])
      expect(entry.metadata).to eq('id' => 4, 'next' => true)

      incoming_word.replace_text!('changed')
      expect(entry.words.last.text).to eq('again')
    end

    it 'merges split words using exact token text, combined timing, and conservative confidence' do
      suffix = described_class::Word.new(
        text: 'ing', start: 2, finish: 2.5, confidence: 0.7, metadata: {'token_id' => 2}
      )
      first_word_with_confidence = described_class::Word.new(
        text: ' test', start: 1, finish: 2, confidence: 0.9, metadata: {'token_id' => 1}
      )

      first_word_with_confidence.merge!(suffix)

      expect(first_word_with_confidence).to have_attributes(
        text: ' testing', start: 1.0, finish: 2.5, confidence: 0.7, metadata: {'token_id' => 2}
      )
    end

    it 'deep-copies the complete mutable graph and keeps collection readers immutable' do
      copy = subtitle.deep_copy

      copy.replace_text!('Copy')
      copy.entries.first.replace_text!('Changed')
      copy.entries.first.words.first.replace_text!('Changed word')

      expect(subtitle.text).to eq('Transcript')
      expect(entry.text).to eq('Original')
      expect(first_word.text).to eq('Hello')
      expect { subtitle.entries << entry }.to raise_error(FrozenError)
      expect { first_word.metadata['token']['id'] = 2 }.to raise_error(FrozenError)
    end

    it 'assigns a speaker to every entry explicitly' do
      expect(subtitle.assign_speaker!(9)).to equal(subtitle)
      expect(subtitle.entries.map(&:speaker_id)).to eq([9])
    end
  end
end
