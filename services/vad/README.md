# Silero VAD service

Subtitling and transcription send only Silero speech ranges to Whisper.
Dubbing still uses Demucs for vocal / non-vocal stems.

The application uses `VoiceActivity::Silero` by default and posts 16 kHz mono
WAV to `http://127.0.0.1:8089/v1/vad`. It receives:

```json
{"segments":[{"start":0.1,"end":1.2}]}
```

Select a backend per process with `VOICE_ACTIVITY=Silero`. Use
`SILERO_VAD_SERVER` to change the Silero endpoint. The systemd unit is
fixed to physical GPU 1 with `CUDA_VISIBLE_DEVICES=1`.

Install the upstream clone and its service runtime under `~/Projects`:

```sh
git clone https://github.com/snakers4/silero-vad.git ~/Projects/silero-vad
cd ~/Projects/silero-vad
uv venv --python 3.11 runtime
UV_PYTHON=runtime/bin/python uv pip install torch==2.9.1 torchaudio==2.9.1 --index-url https://download.pytorch.org/whl/cu128
uv pip install --python runtime/bin/python -e . fastapi uvicorn python-multipart setproctitle soundfile
sudo cp ~/Projects/media-downloader-bot/services/silero-vad@.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now silero-vad@1.service
```
