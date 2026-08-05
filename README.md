# media-downloader-bot

## Audiobook TTS Test

Use `bin/zip` to exercise the same local-file pipeline used by the bot:

```bash
THREADS=1 TTS=OmniVoice /home/braulio/.rvm/wrappers/ruby-3.4.4/ruby bin/zip \
  1908kybalion-pages-1-10.pdf \
  speed=1.0
```

The default audiobook voice is `female, middle-aged, moderate pitch, american accent`.
Override it with `voice=` when testing a specific narrator profile:

```bash
THREADS=1 TTS=OmniVoice /home/braulio/.rvm/wrappers/ruby-3.4.4/ruby bin/zip \
  1908kybalion-pages-1-10.pdf \
  speed=1.0 \
  voice=male,young_adult,moderate_pitch,american_accent
```

Non-URL `voice=` values are passed to OmniVoice as direct voice instructions. Use underscores for spaces inside attributes when calling from the shell, for example `young_adult`, `moderate_pitch`, or `american_accent`.

For audiobook voice cloning, pass an HTTP(S) audio or video link. The audiobook pipeline downloads its best audio stream and reuses the voice-reference quality pipeline to extract the clearest complete passage and transcript:

```bash
THREADS=1 TTS=OmniVoice /home/braulio/.rvm/wrappers/ruby-3.4.4/ruby bin/zip \
  1908kybalion-pages-1-10.pdf \
  voice=https://example.com/narrator-recording
```

## transcribe.cpp Subtitles

The `TranscribeCpp` subtitle backend runs the local CLI and maps its segment and
word timestamps into the same structure used by the existing Whisper renderer:

```bash
SUBTITLER=TranscribeCpp \
TRANSCRIBE_CPP_CLI=/path/to/transcribe.cpp/build/bin/transcribe-cli \
TRANSCRIBE_CPP_MODEL=/path/to/canary-1b-v2-timestamps-Q8_0.gguf \
TRANSCRIBE_CPP_LANGUAGE=en \
TRANSCRIBE_CPP_BACKEND=cuda \
TRANSCRIBE_CPP_DEVICE=0 \
bundle exec ruby bin/zip input.wav gensubs onlysrt
```

The model must advertise word timestamps. Canary requires an explicit language;
`TRANSCRIBE_CPP_LANGUAGE` defaults to `en`. The adapter converts input media to
16 kHz mono PCM before invoking the CLI. Canary rejects inputs longer than its
model limit (about 400 seconds for the current v2 model), so long-form bot media
still requires a chunking layer. Canary word timestamps do not include
confidence scores and therefore cannot be used by the separate voice-reference
quality selector.

## Transcription hashtags

Append Codex-generated Instagram-style hashtags to the media caption with any of
these options:

```bash
bundle exec ruby bin/zip input.wav hashtags lang=pt
bundle exec ruby bin/zip input.wav '#'
bundle exec ruby bin/zip input.wav hts
```

The generator uses `gpt-5.6-luna` with low reasoning effort. It follows the
requested `lang` language, chooses singular or plural based on the transcript,
and only combines two words when they form a meaningful concept.

## Voice cloning evaluation

Use `bin/voice_clone_eval` for repeatable OmniVoice clone comparisons. It uses
the repository's `key=value` opts convention. Repeat `case=` for baseline,
reference, and parameter-sweep cases. Each run writes generated audio,
transcription scores, speaker-embedding cosine scores, `results.json`, and
`summary.csv` under a temporary directory and prints the report to stdout:

```bash
VOICE_CLONE_EMBEDDING_PYTHON=/srv/sherpa-onnx/runtime/bin/python \
WHISPER_CPP_SERVER=http://127.0.0.1:8080 \
bundle exec ruby bin/voice_clone_eval \
  https://example.com/narrator-recording \
  comparison=source.wav \
  embedding_model=/srv/sherpa-onnx/models/embedding/nemo_en_titanet_small.onnx \
  case=baseline \
  case=raw-default:reference \
  case=guidance-1:reference:guidance=1 \
  case=steps-48:reference:steps=48
```

The first argument is an HTTP(S) URL. The evaluator downloads it, uses the
existing voice-reference transcriber to detect its language, extracts the best
voice-reference passage, and uses that passage as the evaluation text and
reference text. Results are printed as JSON to stdout; generated artifacts are
kept in a temporary directory for the run. Use `reference=PATH` with `text=`
or `text_file=` when the reference has already been extracted.

The Sherpa/TitaNet cosine value is a local speaker-similarity proxy, not
OmniVoice's official SIM-o metric. Set `embedding=false` or `transcription=false`
when the corresponding local service is unavailable.
