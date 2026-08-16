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

    it 'rejects non-JSON key types and missing segment collections' do
      expect { described_class.from_whisper_verbose_json(language: 'en') }
        .to raise_error(ArgumentError, 'subtitle keys must be strings')
      expect { described_class.from_whisper_verbose_json('language' => 'en') }
        .to raise_error(KeyError, /segments/)
    end

    it 'normalizes optional language, text, and words at ingress' do
      subtitle = described_class.from_whisper_verbose_json(
        'segments' => [{'start' => 0, 'end' => 1, 'words' => nil}]
      )

      expect(subtitle).to have_attributes(language: nil, text: '')
      expect(subtitle.entries.first).to have_attributes(text: '', words: [])
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
      subtitle = described_class.from_transcribe_cpp_json(JSON.generate(input))
      entry    = subtitle.entries.first
      word     = entry.words.first

      expect(subtitle.metadata).to eq('model' => 'small')
      expect(entry).to have_attributes(start: 0.25, finish: 1.25, metadata: {'temperature' => 0})
      expect(word).to have_attributes(text: 'Olá', start: 0.25, finish: 1.25, confidence: 0.8)
      expect(word.metadata).to eq('prob' => 0.8, 'token_id' => 9)
    end

  end

  describe 'subtitle formats' do
    it 'parses VTT cues into semantic entries and timed words' do
      subtitle = described_class.from_vtt(<<~VTT)
        WEBVTT

        cue-one
        00:00:00.000 --> 00:00:02.000 position:50%
        <b>Hello</b> <00:00:01.000>world &amp; friends
      VTT
      entry = subtitle.entries.first

      expect(entry).to have_attributes(
        cue_id: 'cue-one', start: 0.0, finish: 2.0, text: 'Hello world & friends'
      )
      expect(entry.words.map(&:text)).to eq(['Hello', 'world', '&', 'friends'])
      expect(entry.words.map { |word| [word.start, word.finish] }).to match([
        [0.0, 1.0],
        [1.0, be_within(1e-12).of(4.0 / 3)],
        [be_within(1e-12).of(4.0 / 3), be_within(1e-12).of(5.0 / 3)],
        [be_within(1e-12).of(5.0 / 3), 2.0],
      ])
      expect(entry.metadata['ass_text']).to eq('<b>Hello</b> world & friends')
    end

    it 'renders VTT and SRT with rounded valid ranges without mutating the model' do
      words = [
        described_class::Word.new(text: 'One', start: 1.0001, finish: 1.0006),
        described_class::Word.new(text: 'two', start: 1.0006, finish: 1.0009),
      ]
      subtitle = described_class.new(entries: [
        described_class::Entry.new(start: 1.0001, finish: 1.0004, text: 'One two', words: words),
      ])
      before = subtitle.deep_copy

      expect(subtitle.to_vtt).to eq(
        "WEBVTT\n\n00:00:01.000 --> 00:00:01.001\nOne two\n\n"
      )
      expect(subtitle.to_srt).to eq(
        "1\n00:00:01,000 --> 00:00:01,001\nOne <00:00:01,001>two\n\n"
      )
      expect(subtitle.entries.first).to have_attributes(
        start: before.entries.first.start,
        finish: before.entries.first.finish,
        text: before.entries.first.text
      )
      expect(subtitle.entries.first.words.map { |word| [word.text, word.start, word.finish] })
        .to eq(before.entries.first.words.map { |word| [word.text, word.start, word.finish] })
    end

    it 'parses CRLF SRT, rejects model-level noise, and preserves cue identifiers and endings' do
      srt = "7\r\n00:00:00,000 --> 00:00:01,000\r\n1.2.3.4\r\n\r\n" \
            "9\r\n00:00:01,000 --> 00:00:02,000\r\nKept\r\n"

      subtitle = described_class.from_srt(srt)
      subtitle.reject_noise!

      expect(subtitle.entries.map(&:cue_id)).to eq(['9'])
      expect(subtitle.text).to eq('Kept')
      expect(subtitle.to_srt).to eq("9\r\n00:00:01,000 --> 00:00:02,000\r\nKept\r\n")
    end

    it 'slices overlapping typed words with rebasing and leaves the source unchanged' do
      source = described_class.from_vtt(
        "WEBVTT\n\n00:00:01.000 --> 00:00:05.000\nOne <00:00:02.000>two <00:00:03.000>three\n"
      )

      sliced = source.slice(from: '00:00:02', to: '00:00:04')

      expect(sliced.entries.first).to have_attributes(start: 0.0, finish: 2.0, text: 'two three')
      expect(sliced.entries.first.words.map { |word| [word.text, word.start, word.finish] }).to eq([
        ['two', 0.0, 1.0], ['three', 1.0, 2.0],
      ])
      expect(source.entries.first).to have_attributes(start: 1.0, finish: 5.0)
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

    it 'replaces language and entries and rebuilds or filters document text explicitly' do
      kept = described_class::Entry.new(start: 0, finish: 1, text: 'Kept')
      gone = described_class::Entry.new(start: 1, finish: 2, text: '')

      subtitle.replace_language!('pt').replace_entries!([kept, gone])
      subtitle.reject_entries! { |candidate| candidate.text.empty? }
      subtitle.rebuild_text_from_entries!

      expect(subtitle).to have_attributes(language: 'pt', text: 'Kept', entries: [kept])
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

    it 'keeps canonical confidence authoritative after merging words' do
      first = described_class::Word.new(
        text: ' test', start: 1, finish: 2, confidence: 0.9, metadata: {'probability' => 0.9}
      )
      suffix = described_class::Word.new(text: 'ing', start: 2, finish: 3, confidence: 0.6)

      first.merge!(suffix)

      expect(first.confidence).to eq(0.6)
      expect(first.metadata).to eq('probability' => 0.9)
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

    it 'keeps first-class source text and words independent through copies and retiming' do
      source_word = entry.source_words.first
      copy        = entry.deep_copy

      entry.replace_text!('Translated').replace_words!([])
      copy.retime!(start: 3, finish: 7)

      expect(entry).to have_attributes(source_text: 'Original')
      expect(entry.source_words.map(&:text)).to eq(['Hello'])
      expect(source_word).to have_attributes(start: 1.0, finish: 2.0)
      expect(copy.source_words.first).to have_attributes(start: 3.0, finish: 5.0)
    end

    it 'merges cross-entry suffixes, extends the owner timing, and removes emptied entries' do
      prefix = described_class::Entry.new(
        start: 0, finish: 0.5, text: 'test',
        words: [described_class::Word.new(text: ' test', start: 0, finish: 0.5)]
      )
      suffix = described_class::Entry.new(
        start: 0.5, finish: 1, text: 'ing',
        words: [described_class::Word.new(text: 'ing', start: 0.5, finish: 1)]
      )
      split = described_class.new(entries: [prefix, suffix])

      split.merge_split_words!

      expect(split.entries.size).to eq(1)
      expect(split.entries.first).to have_attributes(start: 0.0, finish: 1.0, text: 'testing')
      expect(split.entries.first.words.first).to have_attributes(text: ' testing', finish: 1.0)
      expect(split.entries.first).to have_attributes(source_text: 'testing')
      expect(split.entries.first.source_words.map(&:text)).to eq([' test', 'ing'])
    end

    it 'assigns a speaker to every entry explicitly' do
      expect(subtitle.assign_speaker!(9)).to equal(subtitle)
      expect(subtitle.entries.map(&:speaker_id)).to eq([9])
    end
  end
end
