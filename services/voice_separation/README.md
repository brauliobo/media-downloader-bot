# Voice separation service

The application uses `VoiceSeparator::Demucs` by default and sends media to
`http://127.0.0.1:8084/v1/separate`. The service returns a ZIP containing
`vocals.wav` and `no_vocals.wav`. Set `VOICE_SEPARATOR` to select a future
backend or `DEMUCS_SERVER` to change the Demucs endpoint.

The systemd unit is fixed to physical GPU 1 with
`CUDA_VISIBLE_DEVICES=1`. Its default model is
`htdemucs`.

Install the maintained Demucs fork and its service runtime under `/srv`:

```sh
git clone https://github.com/adefossez/demucs.git /srv/demucs
cd /srv/demucs
uv venv --python 3.11 runtime
uv pip install --python runtime/bin/python -e . fastapi uvicorn python-multipart
sudo cp ~/Projects/media-downloader-bot/services/demucs@.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now demucs@1.service
```
