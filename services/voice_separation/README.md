# Voice separation service

The application uses `VoiceSeparator::Demucs` by default and sends media to
`http://127.0.0.1:8084/v1/separate`. Both backends return a ZIP containing
`vocals.wav` and `no_vocals.wav`. Set `DEMUCS_SERVER` to change the Demucs
endpoint.

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

## BS-RoFormer (opt-in)

BS-RoFormer is available as an opt-in vocal separator. It uses the published
ZFTurbo inference implementation and vocal checkpoint, because the
`lucidrains/BS-RoFormer` package does not publish compatible pretrained
weights or an inference CLI. It listens on `http://127.0.0.1:8085` and is
reserved for physical GPU 0.

Install the inference runtime and the published checkpoint under `/srv`:

```sh
git clone https://github.com/ZFTurbo/Music-Source-Separation-Training.git /srv/Music-Source-Separation-Training
cd /srv/Music-Source-Separation-Training
uv venv --python 3.11 runtime
uv pip install --python runtime/bin/python -e '.[bs_roformer]' fastapi uvicorn python-multipart
mkdir -p /srv/bs-roformer-models
curl -L --fail -o /srv/bs-roformer-models/model_bs_roformer_ep_317_sdr_12.9755.ckpt \
  https://huggingface.co/RomanSolovyev/BS-RoFormer/resolve/main/model_bs_roformer_ep_317_sdr_12.9755.ckpt
sudo cp ~/Projects/media-downloader-bot/services/bs-roformer@.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now bs-roformer@0.service
```

Select it per process with `VOICE_SEPARATOR=BSRoformer`; this leaves the
default Demucs backend unchanged. Use `BS_ROFORMER_SERVER` to change its
endpoint. The service defaults to one inference chunk per batch and one shift
to keep its measured VRAM use bounded; raise `BS_ROFORMER_BATCH_SIZE` or
`BS_ROFORMER_BIGSHIFTS` only after re-evaluating latency and VRAM.
