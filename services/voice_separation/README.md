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
uv venv --python 3.11 .venv
uv pip install --python .venv/bin/python -e '.[bs_roformer]' fastapi uvicorn python-multipart
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

## Spleeter (opt-in)

Spleeter is available as an opt-in 2-stem vocal separator. It listens on
`http://127.0.0.1:8086` and is reserved for physical GPU 0. Do not enable it
together with `bs-roformer@0`.

Install the cloned runtime under `/srv`:

```sh
git clone https://github.com/deezer/spleeter.git /srv/spleeter
cd /srv/spleeter
uv venv --python 3.11 runtime
uv pip install --python runtime/bin/python -e . fastapi uvicorn python-multipart soundfile setproctitle librosa \
  nvidia-cuda-runtime-cu11==11.8.89 nvidia-cublas-cu11==11.11.3.6 nvidia-cudnn-cu11==8.6.0.163 \
  nvidia-cufft-cu11==10.9.0.58 nvidia-curand-cu11==10.3.0.86 nvidia-cusolver-cu11==11.4.1.48 \
  nvidia-cusparse-cu11==11.7.5.86 nvidia-nccl-cu11==2.16.5 nvidia-cuda-nvrtc-cu11==11.8.89 \
  nvidia-cuda-cupti-cu11==11.8.87
sudo cp ~/Projects/media-downloader-bot/services/spleeter@.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now spleeter@0.service
```

Select it per process with `VOICE_SEPARATOR=Spleeter`; this leaves the
default Demucs backend unchanged. Use `SPLEETER_SERVER` to change its
endpoint.

## MDX-Net (opt-in)

MDX-Net is available as an opt-in vocal separator using the UVR
`Kim_Vocal_2` ONNX checkpoint via `audio-separator`. It listens on
`http://127.0.0.1:8087` and is reserved for physical GPU 0. Do not enable
it together with `bs-roformer@0` or `spleeter@0`.

Install the cloned runtime under `/srv`:

```sh
git clone https://github.com/nomadkaraoke/python-audio-separator.git /srv/audio-separator
cd /srv/audio-separator
uv venv --python 3.11 runtime
uv pip install --python runtime/bin/python -e '.[gpu]' fastapi uvicorn python-multipart setproctitle
sudo cp ~/Projects/media-downloader-bot/services/mdx-net@.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now mdx-net@0.service
```

Select it per process with `VOICE_SEPARATOR=MDXNet`; this leaves the
default Demucs backend unchanged. Use `MDX_SERVER` to change its
endpoint.

## DeepFilterNet (opt-in)

DeepFilterNet3 is available as an opt-in speech enhancer. It treats the
enhanced signal as `vocals.wav` and the residual as `no_vocals.wav`. It
listens on `http://127.0.0.1:8088` and is reserved for physical GPU 0. Do
not enable it together with `bs-roformer@0`, `spleeter@0`, or `mdx-net@0`.

Install the cloned runtime under `/srv`:

```sh
git clone https://github.com/Rikorose/DeepFilterNet.git /srv/DeepFilterNet
cd /srv/DeepFilterNet
uv venv --python 3.11 runtime
UV_PYTHON=runtime/bin/python uv pip install torch==2.5.1 torchaudio==2.5.1 --index-url https://download.pytorch.org/whl/cu124
UV_PYTHON=runtime/bin/python uv pip install deepfilternet fastapi uvicorn python-multipart setproctitle soundfile
sudo cp ~/Projects/media-downloader-bot/services/deepfilternet@.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now deepfilternet@0.service
```

Select it per process with `VOICE_SEPARATOR=DeepFilterNet`; this leaves the
default Demucs backend unchanged. Use `DEEPFILTER_SERVER` to change its
endpoint.
