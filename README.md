# media-downloader-bot

A Telegram bot that downloads videos, audio and images from the web, converts them to fit Telegram's upload limits, and can also transcribe, subtitle, translate, dub and narrate media.

Send it a link (or a file) in Telegram, add optional keywords after the link, and get the result back in the chat.

## What it can do

- **Download from almost anywhere**: YouTube, Instagram, Facebook, X/Twitter, SoundCloud, Bandcamp, Rumble and the other sites supported by [yt-dlp](https://github.com/yt-dlp/yt-dlp), image galleries via [gallery-dl](https://github.com/mikf/gallery-dl), and Telegram message links.
- **Fit Telegram's limits**: media is delivered as a playable Telegram video or audio message. When the file would be too large it is either downloaded in a smaller format or compressed to fit.
- **Extract audio** from any video.
- **Trim and edit**: cut a section, remove parts, silence parts, change speed.
- **Subtitles**: transcribe speech, translate subtitles, or get just the `.srt` file.
- **Dubbing**: re-voice a video in another language.
- **Hashtags and captions**: title, uploader, description, translated caption and generated hashtags.
- **Audiobooks**: send a PDF, EPUB, TXT or YAML file and get a spoken audiobook back, optionally in a cloned or described voice.
- **Shorts**: split a long video into short clips with AI-planned cuts.
- **Playlists and albums**: download several items at once, number or sort them, and send them as albums.

## Using the bot

Open a chat with the bot and send `/help` to see the built-in cheat sheet.

### Download a link

Send a link, optionally followed by keywords separated by spaces:

```
https://youtu.be/FtGEzUKcAnE
https://youtu.be/n8TOOEXsrLw audio caption
https://www.instagram.com/p/CTAXxxODblP/
https://soundcloud.com/br-ulio-bhavamitra/sets/didi-gunamrta caption number
```

You can send several links in one message, up to 10, one per line. Keywords on a line apply to that link; keywords on a first line without a link apply to all of them.

In group chats the bot only reacts to messages that contain a link or a media file.

### Send a file

- **Video or audio file**: converted with the options you put in the caption.
- **PDF, EPUB, TXT or YAML**: turned into an audiobook.
- **`.srt` subtitle file with `lang=xx`**: translated into that language.

### Commands

| Command | What it does |
|---|---|
| `/start`, `/help` | Show the help message |
| `/stop` | Cancel all your active jobs in the chat (or press the Cancel button on a job) |
| `/cookies` | Save your cookies for sites that need a login. Send a Netscape `cookies.txt` as a document, or paste its content after the command |

## Options

Options are plain words (`audio`) or `key=value` pairs (`speed=1.5`) written after the link, or in the caption of a file you send.

### What to send

| Option | Effect |
|---|---|
| `audio` | Extract the audio instead of sending the video |
| `format=` | Output format. Video: `h264` (`mp4`), `h265` (`hevc`), `av1`, `vp9` (`webm`). Audio: `opus` (`ogg`), `aac` (`m4a`), `mp3` |
| `width=` | Video width in pixels |
| `quality=` | Video quality (lower is better) |
| `bitrate=`, `abrate=` | Audio bitrate for audio files / for the audio track of videos, in kbps |
| `noaudio` | Remove the audio track |
| `maxfr=` | Limit the frame rate |
| `ac=`, `ar=` | Audio channels / sample rate |
| `alang=pt` | Prefer the audio track in that language |
| `referer=` | Referer header for sites that require one |

### Trimming and editing

Times accept seconds (`90`, `90.5`), clock (`1:30`, `1:30:00`) or compact (`90s`, `1m30s`, `1h30m`).

| Option | Effect |
|---|---|
| `ss=` | Start at this time |
| `to=` | Stop at this time |
| `t=` | Duration after `ss=` (do not combine with `to=`) |
| `cuts=` | Remove intervals and close the gaps, e.g. `cuts=30-40,1:30-1:45` |
| `silences=` | Mute intervals, keeping the duration, e.g. `silences=10-20` |
| `speed=` | Change speed, e.g. `speed=1.5` |

```
https://youtu.be/abc ss=1m30s t=30s
https://youtu.be/abc ss=1:30 to=2:00
https://youtu.be/abc cuts=30-40,1:30.5-1:45
```

### Captions and text

| Option | Effect |
|---|---|
| `caption` | Add title and uploader (videos always get one; add this for audio) |
| `nocaption` | Send without a caption |
| `description` | Add the video description |
| `clang=pt` | Translate the caption into that language |
| `hashtags`, `#`, `hts` | Add generated Instagram-style hashtags, based on the transcription and written in the language from `lang=` |

### Subtitles, dubbing and clips

| Option | Effect |
|---|---|
| `lang=pt` | Language for subtitles and audio. Shortcut for `slang=pt alang=pt` |
| `slang=pt` | Add subtitles in that language, transcribing and translating when needed |
| `sub=pt` | Same, or `sub=source`, `sub=both`, `sub=none` to choose what to show |
| `gensubs` | Always generate subtitles with speech recognition |
| `nowords` | Plain subtitles, without word-by-word highlighting |
| `onlysrt` | Send only the `.srt` file |
| `dub=pt` | Dub the video into that language, with subtitles |
| `genshorts` | Cut the video into short clips |

### Playlists and albums

| Option | Effect |
|---|---|
| `number` | Prefix each file with its position |
| `sort`, `reverse` | Order the items by title, or in reverse |
| `album` | Send photos and videos grouped as albums |

Full playlist downloads (`limit=`, `after=`) are available to the bot's administrator. Everyone else gets the single video of the link.

### Audiobooks

Send a document and add options in its caption:

| Option | Effect |
|---|---|
| `voice=` | A voice description, e.g. `voice=male,young_adult,moderate_pitch,american_accent`, or a link to an audio/video recording of the voice to clone |
| `speed=` | Speaking speed |
| `lang=` | Language of the narration |

## Streaming uploads and size limits

The bot has an upload limit that depends on how it runs: 50 MB on the regular Telegram Bot API, 2 GB when it runs as a Telegram user client.

To avoid slow, quality-losing re-encodes, **regular users get streaming uploads by default**: the bot picks the best mp4 (h264/AAC) format of the video that fits the limit and uploads it exactly as downloaded, so it is also fast. For example, a 3:30 video at a 20 MB limit is delivered as 480p instead of being recompressed.

- The administrator keeps the re-encoding behavior unless they add `stream`. Anyone can add `nostream` to get the re-encoded version instead.
- Any option that changes the video or audio (`audio`, `format=`, `width=`, `speed=`, `cuts=`, subtitles, dubbing, ...) uses the re-encoding path instead.
- `ss=`, `to=` and `t=` do **not** disable it: only the requested section is downloaded.
- If no format fits the limit, the bot falls back to re-encoding the video to fit.
- When the upload limit is 50 MB, streamed videos only use audio up to 64 kbps, leaving more of the size budget to the picture.
- Very long videos are refused when they cannot fit the limit (about 35 minutes at 50 MB).

## Using it from the command line

The same conversion pipeline works locally with `bin/zip`, without Telegram:

```bash
bin/zip https://youtu.be/FtGEzUKcAnE audio
bin/zip movie.mkv ss=1m30s t=30s speed=1.5
bin/zip lecture.mp4 slang=pt onlysrt
bin/zip book.pdf voice=male,young_adult,moderate_pitch,american_accent
bin/zip ~/Videos
```

Links are downloaded with streaming uploads, like a regular bot user; add `nostream` to re-encode them instead. Results are written to a `converted/` folder, next to the input file or in the current folder for links. Passing a folder converts every media file in it. `SIZE_MB_LIMIT=50` makes the CLI behave like the 50 MB bot.

## Running your own bot

### Requirements

- Ruby (see `.ruby-version`) and Bundler
- PostgreSQL
- `ffmpeg`/`ffprobe`, `yt-dlp` and, for galleries, `gallery-dl`
- Node.js and pnpm for the web dashboard assets
- Optional, for the corresponding features: speech recognition (whisper.cpp / WhisperX), translation, text-to-speech and voice services. Example systemd units are in `services/`.

### Setup

```bash
bundle install
pnpm install
createdb mdb          # or the name you set in DB_NAME
bin/rails db:migrate
```

Configure through environment variables (a `.env` file works):

| Variable | Purpose |
|---|---|
| `TG_BOT_TOKEN` | Token of your bot from [@BotFather](https://t.me/BotFather) |
| `ADMIN_CHAT_ID` | Telegram user id of the administrator |
| `DB_NAME`, `DB_USER`, `DB_HOST`, `DB_PASSWORD` | PostgreSQL connection |
| `BLOCKED_USERS`, `BLOCKED_DOMAINS` | Users and domains to refuse |
| `MAX_RES` | Maximum video height to download (default 1080) |

### Start

```bash
bin/tgbot   # regular Telegram bot (50 MB uploads)
bin/tdbot   # Telegram user client through TDLib (2 GB uploads)
```

## Contributing

Report issues at <https://github.com/brauliobo/media-downloader-bot/issues/new>. Developer and evaluation notes live in [docs/development.md](docs/development.md).
