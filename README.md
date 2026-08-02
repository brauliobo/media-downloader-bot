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
