# Bots and workers

The bot (`bin/tdbot`, `bin/tgbot`) keeps the Telegram client; the books are converted by separate worker processes (`bin/worker`)
that a deploy of the bot does not restart. Both bots work the same way: a worker is pointed at one bot's service by address, nothing
in it is specific to TDLib or to the Bot API.

## Process model

| | bot (manager) | worker |
|---|---|---|
| holds | Telegram client, `Manager`, the HTTP/DRb service on loopback (`BOT_HTTP`/`BOT_DRB`), the tracked jobs engine (replay) | nothing but the job it is converting |
| restarts | on every deploy of the bot, in seconds | when reloaded (see below), after its book |
| code tree | the bot's | its own (`/srv/media-downloader-worker`), so a bot deploy never changes code under a worker |

The work dirs live under `TMPDIR`, a directory both share: the worker writes the files it uploads there and the bot's service reads
them (`BOT_ALLOWED_PATH_ROOTS` defaults to `TMPDIR`). It is `/tmp/media-downloader/work` (`work-tg` for the tgbot), on the tmpfs of
`/tmp`: a book's parts are many times its size and the disk cannot take them. So no unit has `PrivateTmp`, and
`media-downloader.tmpfiles.conf` makes the dirs at boot and keeps them out of the cleaning of `/tmp`. A reboot loses them: the books
being converted start over (a reload or a restart of a worker or the bot does not).

## The queue

The queue is the `bot_jobs` table (`BotJob`, `Bot::Jobs`), not the bot's memory. A row is a message handed to the workers of a
`queue` (`tdbot` or `tgbot`, asked of the bot's service at start-up, so `BOT_HTTP` is all a worker is configured with).

- The bot `submit`s a message: one row, unique per `queue` + `chat:message id` while active, so feeding the same message twice
  (a replay after a restart) returns the job it already has.
- A worker `dequeue`s straight from the database: the oldest unheld row, one running job per user (`Bot::UserQueue.limit`, the
  admin exempt), `FOR UPDATE SKIP LOCKED`. It needs the bot only to talk to Telegram.
- Cancelling (`/stop`, the cancel button) sets `cancelled`; the worker polls it. Finishing deletes the row.
- Messages the bot runs itself (`WITH_WORKER=1`, the old mode) are rows too (`worker = 'inline'`) so `/stop` works the same; they
  die with the bot and are dropped when it starts.

## Leases

A claimed row is `running` with `worker` and `lease_until` (`WORKER_LEASE`, 60 s). The worker renews its leases from a thread
every third of that, straight in the database, so a restart of the bot changes nothing. A row whose lease ran out belongs to a
dead worker and is claimed by the next one (`attempts` + 1, dropped after 5: a book that keeps killing its worker). A worker that
stops on purpose releases its row without costing an attempt.

The tracked jobs (replay) need no lease of their own: their items run on threads of the bot, so after a restart `Tracked::Engine#recover!`
is right to put the running ones back in line. What matters is that replaying one does not start a second book while a worker still
converts the first: a message that already has a job is waited for, not fed again (`Manager::Service#replay_message`).

## RPC while the bot is down

Everything a worker does to Telegram (`send_message`, `edit_message`, uploads, `download_file`, `report_error`) is a call to the bot's
service. `Bot::Worker::Client` retries a call that could not reach the bot (connection refused/reset, DRb connection lost) with a pause
growing to 30 s, up to `MANAGER_RETRIES` times (120, about an hour). The conversion itself keeps running; its status edits and uploads
wait and go out when the bot is back. A call the bot answered with an error is not retried.

## Reload and stop

| signal | worker |
|---|---|
| `USR2` (`systemctl reload`) | stops taking jobs, finishes the one in flight however long it takes, exits 0; `Restart=always` starts the replacement on the new code |
| `TERM` (`systemctl stop`, reboot), `INT` | the same, but after `WORKER_DRAIN_TIMEOUT` (540 s, under `TimeoutStopSec=600`) the job is handed back to the queue and the worker exits |
| the same signal twice | hands the job back and exits now |
| `KILL`, crash, power loss | lease runs out in at most a minute, another worker takes the job |

Each worker converts one book, so reloading all of them loses no capacity: idle ones restart at once, busy ones after their book, and
a busy one was working anyway. A job handed back or lost is resumed, not restarted:

- it works in `TMPDIR/job-<job id>`, the same path whoever takes it, kept when it is stopped (removed after success, error or cancel;
  `Worker.prune_workdirs` clears the ones nobody took for 7 days);
- the audiobook keeps its audio in a directory named by a hash of the text and the voice and skips the pages already read (the voice
  reference is kept too, so the narrator does not change); the OCR text of each page is kept by a hash of the page image.

Not resumed: the download of the input, the parsing of the book, the translation. The resumed job posts a new status message.

## Deploy runbook (the units live in `deploy/`; the repo installs nothing)

One-time cut-over from the bot running the books itself (done for the tdbot on 2026-10-16):

1. Apply the migration (`db/migrate/20261016150000_create_bot_jobs.rb`) to the production database.
2. Make the worker tree `/srv/media-downloader-worker`: a clone of a bot tree, plus its `vendor/`, `.bundle/`, `Gemfile.lock`, `voices/`
   and the `.env` and `.env.user` files. Use the lock of a tree built without `TD_BOT` (the tgbot's): a worker needs no TDLib, and its
   `.env.local` must not exist (no `TD_BOT`, no `WITH_WORKER`).
3. One environment file per bot, `/etc/media-downloader/<bot>-worker.env` (root:mdb 0640), holding that bot's `BOT_HTTP_TOKEN`: the two
   bots' tokens differ, and what the unit sets wins over the dotenv files. The bots' services are `BOT_HTTP` 1181 (tdbot) and 1180 (tgbot).
4. Install `media-downloader-workers.slice` and `media-downloader-<bot>-worker@.service`, and per bot a drop-in from `bot-workers.conf`.
   Remove `WITH_WORKER` from the bot's drop-ins and from its `.env.local`. Install `media-downloader.tmpfiles.conf` as
   `/etc/tmpfiles.d/media-downloader.conf` and run `systemd-tmpfiles --create` for the work dirs.
5. `systemctl daemon-reload`, restart the bot (the last time the books it was running are lost; replay items are retried), then
   `systemctl enable --now media-downloader-tdbot-worker@{1..7}`. A worker takes minutes to boot on a busy host.

Jobs fed by a tracked job (replay, a group's queue) count against no user: the job's own `parallel` is their limit. A message sent by a
person counts against them (`Bot::UserQueue.limit` running jobs, the admin exempt).

After that:

- Deploy the bot: update its tree, `systemctl restart media-downloader-tdbot`. Workers keep converting, queued jobs wait in the database.
- Deploy workers (a change to `Worker`, the audiobook, TTS, OCR...): update the worker tree, `systemctl reload 'media-downloader-*-worker@*'`.
  Nothing is interrupted. Use `systemctl stop` only to take a worker out for good: it waits `WORKER_DRAIN_TIMEOUT`.
- A change in what the bot and the workers say to each other (`Bot::Worker::Client` vs `Manager::Service`): adding a call, restart the bot
  first and then reload the workers; removing one, the other way round.
- A migration goes before both. `journalctl -u 'media-downloader-*-worker@*'` shows `worker <id> takes the jobs of <queue>` on start
  and `... stopped` on exit.

`services/media-downloader-worker@.service` is the older unit for the dequeue-over-HTTP worker and is superseded by `deploy/`.
