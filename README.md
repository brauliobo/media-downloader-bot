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

The `voice=` value is passed to OmniVoice as the one-time audiobook reference voice instruction. Use underscores for spaces inside attributes when calling from the shell, for example `young_adult`, `moderate_pitch`, or `american_accent`.
