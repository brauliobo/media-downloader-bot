require 'spec_helper'

RSpec.describe Subtitler::VTT do
  def payloads(vtt)
    vtt.split(/\n\s*\n/).filter_map do |cue|
      lines = cue.lines.map(&:strip)
      timing = lines.find { |line| line.include?('-->') }
      next unless timing

      lines[(lines.index(timing) + 1)..].join(' ')
    end
  end

  def translate(vtt, from:, to:, word_tags: true)
    Subtitler::Subtitle.from_vtt(described_class.clean(vtt))
      .translated(from: from, to: to, merge_adjacent: false)
      .to_vtt(word_tags: word_tags)
  end

  def slice(vtt, **range)
    Subtitler::Subtitle.from_vtt(vtt).slice(**range).to_vtt
  end

  it 'converts external subtitles through FFmpeg' do
    ffmpeg = instance_double FFmpeg
    expect(ffmpeg).to receive(:convert_subtitle).with(
      input: end_with('.srt'), format: :vtt, label: 'VTT conversion failed'
    ).and_return "WEBVTT\n\nConverted"

    expect(described_class.to_vtt('subtitle body', 'srt', ffmpeg: ffmpeg))
      .to eq "WEBVTT\n\nConverted"
  end

  it 'canonicalizes native VTT without invoking FFmpeg or changing UTF-8 text and inline timings' do
    ffmpeg = instance_double FFmpeg
    expect(ffmpeg).not_to receive(:convert_subtitle)

    body = "WEBVTT\r\r00:00:00.000 --> 00:00:02.000\rOlá <00:00:01.000>mundo\\Nnovamente\r"
    canonical = described_class.to_vtt(body, '.VTT', ffmpeg: ffmpeg)

    expect(canonical).to eq(
      "WEBVTT\n\n00:00:00.000 --> 00:00:02.000\nOlá <00:00:01.000>mundo\nnovamente\n"
    )
    allow(::Translator).to receive(:translate).and_return(['Hola mundo nuevamente.'])
    translate(canonical, from: 'pt', to: 'es')
    expect(::Translator).to have_received(:translate).with(['Olá mundo novamente'], from: 'pt', to: 'es')
  end

  it 'canonicalizes native comma timestamps without changing prose and burns them to ASS' do
    body = <<~VTT
      WEBVTT

      00:00,000 --> 00:02,000
      Wait, 1,000 <00:01,000>units
    VTT

    canonical = described_class.to_vtt(body, 'vtt')
    ass = Subtitler::Subtitle.from_vtt(canonical).to_ass

    expect(canonical).to include(
      "00:00.000 --> 00:02.000\nWait, 1,000 <00:01.000>units"
    )
    expect(ass.lines.grep(/^Dialogue:/)).not_to be_empty
    expect(ass).not_to include('<00:01.000>')
  end

  it 'reinterprets HTTP binary bytes as UTF-8 and canonicalizes every line ending' do
    body = "\xEF\xBB\xBFWEBVTT\r\r\n00:00:00.000 --> 00:00:02.000\rOl\xC3\xA1 mundo\r".b

    expect(described_class.to_vtt(body, 'vtt')).to eq(
      "\uFEFFWEBVTT\n\n00:00:00.000 --> 00:00:02.000\nOlá mundo\n"
    )
  end

  it 'rejects invalid bytes in native VTT instead of deleting text' do
    body = "WEBVTT\n\nOl\xFF".force_encoding(Encoding::UTF_8)

    expect { described_class.to_vtt(body, 'vtt') }
      .to raise_error(Encoding::InvalidByteSequenceError, /invalid byte sequence in UTF-8/)
  end

  it 'rejects invalid native VTT structure without invoking FFmpeg' do
    [
      "not vtt\n",
      "WEBVTT\n\n00:00:bad --> 00:00:02.000\nBad\n",
      "WEBVTT\n\n00:00:02.000 --> 00:00:02.000\nBad\n",
      "WEBVTT\n\n00:00:03.000 --> 00:00:02.000\nBad\n",
    ].each do |body|
      expect { described_class.to_vtt(body.b, 'vtt') }
        .to raise_error(ArgumentError, /invalid WEBVTT/)
    end

    expect(described_class.to_vtt("WEBVTT\r".b, 'vtt')).to eq("WEBVTT\n")
  end

  it 'preserves external subtitle conversion errors' do
    ffmpeg = instance_double FFmpeg
    allow(ffmpeg).to receive(:convert_subtitle)
      .and_raise Sh::Error.new('VTT conversion failed', 'invalid subtitle')

    expect { described_class.to_vtt('invalid', 'srt', ffmpeg: ffmpeg) }
      .to raise_error Sh::Error, 'VTT conversion failed: invalid subtitle'
  end

  it 'extracts an embedded subtitle stream through FFmpeg' do
    ffmpeg = instance_double FFmpeg
    zipper = instance_double Zipper, infile: '/media/video.mkv'
    expect(ffmpeg).to receive(:convert_subtitle).with(
      input: '/media/video.mkv', format: :vtt, stream_index: 2,
      label: 'VTT extraction failed'
    ).and_return "WEBVTT\n\nEmbedded"

    expect(described_class.extract_embedded(zipper, 2, ffmpeg: ffmpeg))
      .to eq "WEBVTT\n\nEmbedded"
  end

  it 'translates VTT by sentences and applies the shared length limit' do
    vtt = <<~VTT
      WEBVTT

      1
      00:00:00.000 --> 00:00:04.000
      Hello. <00:00:01.000>This is a second sentence.
    VTT
    long_translation = 'Esta é uma frase traduzida muito longa com conteúdo suficiente para ultrapassar o limite padrão de uma legenda e exigir divisão.'

    allow(::Translator).to receive(:translate).and_return(['Olá.', long_translation])

    translated = translate(vtt, from: 'en', to: 'pt', word_tags: false)

    expect(::Translator).to have_received(:translate).with(
      ['Hello.', 'This is a second sentence.'],
      from: 'en',
      to:   'pt'
    )
    expect(payloads(translated)).to include('Olá.')
    expect(payloads(translated).join(' ')).to include(long_translation)
    expect(payloads(translated)).to all(have_attributes(length: be <= Subtitler::Subtitle::MAX_ENTRY_CHARS))
  end

  it 'keeps short translated sentences separate instead of prepending the next sentence' do
    vtt = <<~VTT
      WEBVTT

      00:00:00.000 --> 00:00:04.000
      Hello. This is another sentence.
    VTT

    allow(::Translator).to receive(:translate).and_return(['Olá.', 'Esta é outra frase.'])

    translated = translate(vtt, from: 'en', to: 'pt')

    expect(payloads(translated)).to eq(['Olá.', 'Esta é outra frase.'])
  end

  it 'translates cues that use minute-second timestamps' do
    vtt = <<~VTT
      WEBVTT

      00:00.240 --> 00:02.310
      Arthritis is getting worse.
    VTT

    allow(::Translator).to receive(:translate).and_return(['A artrite está piorando.'])

    translated = translate(vtt, from: 'en', to: 'pt')

    expect(translated).to include(
      "00:00:00.240 --> 00:00:02.310\nA artrite está piorando."
    )
  end

  it 'preserves compact inline timestamps during translation' do
    vtt = "WEBVTT\n\n00:00.000 --> 00:04.000\nHello <00:02.000>there.\n"
    allow(::Translator).to receive(:translate).and_return(['Olá mundo.'])

    translated = translate(vtt, from: 'en', to: 'pt')

    expect(translated).to include('Olá <00:00:02.000>mundo.')
  end

  it 'round-trips untouched VTT presentation metadata and removes only markers when requested' do
    vtt = <<~VTT
      WEBVTT

      cue-one
      00:00:00.000 --> 00:00:02.000 align:start position:50%
      Bonjour <00:00:01.000>world
      authored second line
    VTT
    subtitle = Subtitler::Subtitle.from_vtt(vtt)

    expect(subtitle.to_vtt).to eq(
      "WEBVTT\n\n" \
      "cue-one\n" \
      "00:00:00.000 --> 00:00:02.000 align:start position:50%\n" \
      "Bonjour <00:00:01.000>world\n" \
      "authored second line\n\n"
    )
    expect(subtitle.to_vtt(word_tags: false)).to eq(
      "WEBVTT\n\n" \
      "cue-one\n" \
      "00:00:00.000 --> 00:00:02.000 align:start position:50%\n" \
      "Bonjour world\n" \
      "authored second line\n\n"
    )
    expect(subtitle.to_vtt(word_tags: false)).not_to match(/<\d{2}:\d{2}/)
  end

  it 'does not reuse authored VTT content after semantic or word-timing changes' do
    vtt = <<~VTT
      WEBVTT

      cue-one
      00:00:00.000 --> 00:00:02.000 align:start
      Bonjour <00:00:01.000>world
      authored second line
    VTT
    subtitle = Subtitler::Subtitle.from_vtt(vtt)
    subtitle.entries.first.project_text!('Hello world')

    changed = subtitle.to_vtt(word_tags: false)

    expect(changed).to include(
      "cue-one\n00:00:00.000 --> 00:00:02.000 align:start\nHello world"
    )
    expect(changed).not_to include('Bonjour', 'authored second line', '<00:00:01.000>')

    timed_vtt = "WEBVTT\n\n00:00:00.000 --> 00:00:02.000\nBonjour <00:00:01.000>world\n"
    subtitle = Subtitler::Subtitle.from_vtt(timed_vtt)
    subtitle.entries.first.words.last.replace_timing!(start: 1.5, finish: 2.0)
    retimed = subtitle.to_vtt

    expect(retimed).to include('Bonjour <00:00:01.500>world')
    expect(retimed).not_to include('<00:00:01.000>')
  end

  it 'decodes cue markup and projects translation over structural inline timings' do
    vtt = <<~VTT
      WEBVTT

      00:00:00.000 --> 00:00:04.000
      <b>Hello</b> there <00:00:02,000>Fran&ccedil;ais encore.
    VTT
    allow(::Translator).to receive(:translate).and_return(['Olá mundo espanhol agora.'])

    translated = translate(vtt, from: 'en', to: 'pt')
    plain = translate(vtt, from: 'en', to: 'pt', word_tags: false)

    expect(::Translator).to have_received(:translate).twice.with(
      ['Hello there Français encore.'],
      from: 'en',
      to:   'pt'
    )
    expect(translated).to include(
      'Olá <00:00:01.000>mundo <00:00:02.000>espanhol <00:00:03.000>agora.'
    )
    expect(plain).to include('Olá mundo espanhol agora.')
    expect(plain).not_to include('<00:00:')
  end

  it 'preserves spaces around standalone decoded entities' do
    vtt = "WEBVTT\n\n00:00:00.000 --> 00:00:03.000\nencore &amp; toujours <00:00:02.000>ici\n"
    allow(::Translator).to receive(:translate).and_return(['ainda e sempre aqui'])

    translate(vtt, from: 'fr', to: 'pt')

    expect(::Translator).to have_received(:translate).with(['encore & toujours ici'], from: 'fr', to: 'pt')
  end

  it 'keeps unpunctuated VTT cues separate through translation' do
    vtt = <<~VTT
      WEBVTT

      00:00:00.000 --> 00:00:01.000
      Hello

      00:00:01.000 --> 00:00:02.000
      there
    VTT
    allow(::Translator).to receive(:translate).and_return(['Olá', 'aí'])

    translated = translate(vtt, from: 'en', to: 'pt')

    expect(::Translator).to have_received(:translate).with(['Hello', 'there'], from: 'en', to: 'pt')
    expect(payloads(translated)).to eq(['Olá', 'aí'])
  end

  it 'carries rounded milliseconds into the next VTT second' do
    subtitle = Subtitler::Subtitle.new(entries: [
      Subtitler::Subtitle::Entry.new(text: 'Carry', start: 1.9996, finish: 62.9996),
    ])

    expect(subtitle.to_vtt).to include(
      '00:00:02.000 --> 00:01:03.000'
    )
  end

  it 'serializes positive sub-millisecond cues as valid one-millisecond intervals' do
    word = Subtitler::Subtitle::Word
    entry = Subtitler::Subtitle::Entry
    subtitle = Subtitler::Subtitle.new(entries: [
      entry.new(text: 'Tiny', start: 1.0001, finish: 1.0004, words: [
        word.new(text: 'Tiny', start: 1.0001, finish: 1.0004),
      ]),
      entry.new(text: 'One two three four', start: 2.0004, finish: 2.0024, words: [
        word.new(text: 'One', start: 2.0004, finish: 2.0006),
        word.new(text: 'two', start: 2.0006, finish: 2.0007),
        word.new(text: 'three', start: 2.0007, finish: 2.0016),
        word.new(text: 'four', start: 2.0016, finish: 2.0024),
      ]),
      entry.new(text: 'Zero', start: 3.0, finish: 3.0),
    ])

    rendered = subtitle.to_vtt

    expect(rendered).to include("00:00:01.000 --> 00:00:01.001\nTiny")
    expect(rendered).to include(
      "00:00:02.000 --> 00:00:02.002\nOne <00:00:02.001>two three four"
    )
    expect(rendered).not_to include('Zero')
    expect(described_class.to_vtt(rendered, 'vtt')).to eq(rendered)
  end

  it 'keeps clean cue text wordless when inline timing markers are invalid' do
    [
      'Hello <00:00:03.000>there <00:00:02.000>friend.',
      'Hello <00:00:05.000>there friend.',
      'Hello <00:00:bad>there friend.',
    ].each do |text|
      allow(::Translator).to receive(:translate).and_return(['Texto limpo.'])
      vtt = "WEBVTT\n\n00:00:00.000 --> 00:00:04.000\n#{text}\n"

      translated = translate(vtt, from: 'en', to: 'pt')

      expect(translated).to include("00:00:00.000 --> 00:00:04.000\nTexto limpo.")
      expect(translated).not_to include('<00:00:')
    end
  end

  it 'does not merge normalized cues from different speakers' do
    subtitle = Subtitler::Subtitle.new(entries: [
      Subtitler::Subtitle::Entry.new(text: 'Hello.', start: 0.0, finish: 1.0, speaker_id: 0),
      Subtitler::Subtitle::Entry.new(text: 'Goodbye.', start: 1.2, finish: 2.0, speaker_id: 1),
    ])

    subtitle.normalize_entries!
    translated = subtitle.to_vtt

    expect(payloads(translated)).to eq(['Hello.', 'Goodbye.'])
  end

  describe '.slice' do
    let(:vtt) do
      <<~VTT
        WEBVTT

        00:00:01.000 --> 00:00:05.000
        One <00:00:02.000>two <00:00:03.000>three <00:00:04.000>four
      VTT
    end

    it 'retains overlapping words and rebases inline timings inside the range' do
      sliced = slice(vtt, from: '00:00:02', to: '00:00:04')

      expect(sliced).to include("00:00:00.000 --> 00:00:02.000\ntwo <00:00:01.000>three")
      expect(sliced).not_to include('One', 'four')
    end

    it 'keeps a word active at the left boundary as the first untagged word' do
      active = "WEBVTT\n\n00:00:01.000 --> 00:00:04.000\nOne alpha beta <00:00:03.000>last\n"
      sliced = slice(active, from: '00:00:02', to: '00:00:03')

      expect(sliced).to include("00:00:00.000 --> 00:00:01.000\nalpha <00:00:00.333>beta")
      expect(sliced).not_to include('<00:00:00.000>')
    end

    it 'excludes words ending at the left edge and starting at the right edge' do
      sliced = slice(vtt, from: '00:00:02', to: '00:00:03')

      expect(payloads(sliced)).to eq(['two'])
    end

    it 'leaves cue bounds and inline text unchanged without rebasing' do
      sliced = slice(vtt, from: '00:00:02', to: '00:00:04', rebase: false)

      expect(sliced).to include("00:00:01.000 --> 00:00:05.000\nOne <00:00:02.000>two <00:00:03.000>three <00:00:04.000>four")
    end

    it 'keeps the existing behavior for untagged cues' do
      plain = "WEBVTT\n\n00:00:01.000 --> 00:00:05.000\nWhole cue text\n"

      expect(slice(plain, from: '00:00:02', to: '00:00:04'))
        .to include("00:00:00.000 --> 00:00:02.000\nWhole cue text")
    end

    it 'removes invalid timing-like markup from rebased cue text' do
      [
        'One <00:00:bad>two',
        'One <00:00:04.500>two',
        'One <00:00:03.000>two <00:00:02.000>three',
      ].each do |text|
        source = "WEBVTT\n\n00:00:01.000 --> 00:00:04.000\n#{text}\n"
        sliced = slice(source, from: '00:00:01', to: '00:00:04')

        expect(payloads(sliced)).to eq([text.gsub(/<[^>]*>/, '').split.join(' ')])
        expect(sliced).not_to match(/<\d{2}:\d{2}/)
      end
    end

    it 'marks an intentional gap before the first retained word' do
      source = "WEBVTT\n\n00:00:01.000 --> 00:00:05.000\n<00:00:02.000>late <00:00:03.000>word\n"

      sliced = slice(source, from: '00:00:01', to: '00:00:04')

      expect(sliced).to include("00:00:00.000 --> 00:00:03.000\n<00:00:01.000>late <00:00:02.000>word")
    end
  end

  describe '.srt_to_vtt' do
    it 'normalizes recognized cue and inline timestamps without changing prose' do
      srt = <<~SRT
        1
        00:00:01,000 --> 00:00:03,500
        Wait, this costs 1,000 <00:00:02,250>units --> really.
      SRT

      expect(Subtitler::Subtitle.from_srt(srt).to_vtt).to include(
        "00:00:01.000 --> 00:00:03.500\nWait, this costs 1,000 <00:00:02.250>units --> really."
      )
    end
  end
end
