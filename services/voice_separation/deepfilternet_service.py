import os
import subprocess
import tempfile
import threading
import zipfile
from pathlib import Path

import setproctitle
import soundfile as sf
import torch
from df.enhance import enhance, init_df
from df.io import resample
from df.model import ModelParams
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from starlette.background import BackgroundTask

MODEL = os.environ.get("DEEPFILTER_MODEL", "DeepFilterNet3")
DEVICE = os.environ.get("DEEPFILTER_DEVICE", "cuda")
OUTPUT_SR = int(os.environ.get("DEEPFILTER_OUTPUT_SR", "44100"))
MAX_UPLOAD_BYTES = int(os.environ.get("DEEPFILTER_MAX_UPLOAD_BYTES", str(2 * 1024 * 1024 * 1024)))

gpu = os.environ.get("CUDA_VISIBLE_DEVICES", "?")
setproctitle.setproctitle(f"deepfilternet-gpu{gpu}")

app = FastAPI()
lock = threading.Lock()
model = None
df_state = None
model_sr = None


@app.on_event("startup")
def load_model():
    global model, df_state, model_sr
    if DEVICE == "cuda" and not torch.cuda.is_available():
        raise RuntimeError("DeepFilterNet requires an available CUDA device")
    model, df_state, _ = init_df(MODEL, log_level="ERROR", log_file=None)
    model_sr = ModelParams().sr
    if DEVICE == "cuda" and next(model.parameters()).device.type != "cuda":
        raise RuntimeError("DeepFilterNet did not load on CUDA")


@app.get("/health/ready")
def ready():
    if model is None or df_state is None:
        raise HTTPException(status_code=503, detail="model is not loaded")
    device = torch.cuda.get_device_name(0) if DEVICE == "cuda" else DEVICE
    return {"status": "ok", "backend": "deepfilternet", "model": MODEL, "device": device}


@app.post("/v1/separate")
def separate(file: UploadFile = File(...)):
    workdir = tempfile.TemporaryDirectory(prefix="deepfilternet-")
    root = Path(workdir.name)
    suffix = Path(file.filename or "audio").suffix
    input_path = root / f"input{suffix}"

    try:
        copy_upload(file, input_path)
        mix = load_mix(input_path, root / "decoded.wav")
        with lock:
            enhanced = enhance(model, df_state, mix, pad=True).cpu()
        vocals, residual = stems_from_enhance(mix, enhanced)
        sf.write(root / "vocals.wav", vocals.clamp(-1, 1).T.numpy(), OUTPUT_SR, subtype="PCM_16")
        sf.write(root / "no_vocals.wav", residual.clamp(-1, 1).T.numpy(), OUTPUT_SR, subtype="PCM_16")

        archive = root / "stems.zip"
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_STORED) as output:
            output.write(root / "vocals.wav", "vocals.wav")
            output.write(root / "no_vocals.wav", "no_vocals.wav")
        return FileResponse(
            archive,
            media_type="application/zip",
            filename="stems.zip",
            background=BackgroundTask(workdir.cleanup),
        )
    except HTTPException:
        workdir.cleanup()
        raise
    except Exception as error:
        workdir.cleanup()
        raise HTTPException(status_code=422, detail=f"voice separation failed: {error}") from error


def copy_upload(upload, destination):
    copied = 0
    with destination.open("wb") as output:
        while chunk := upload.file.read(1024 * 1024):
            copied += len(chunk)
            if copied > MAX_UPLOAD_BYTES:
                raise HTTPException(status_code=413, detail="media upload is too large")
            output.write(chunk)


def load_mix(input_path, wav_path):
    subprocess.run(
        ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", str(input_path), str(wav_path)],
        check=True,
    )
    data, file_sr = sf.read(str(wav_path), always_2d=True, dtype="float32")
    audio = torch.from_numpy(data.T.copy())
    return audio if file_sr == model_sr else resample(audio, file_sr, model_sr)


def stems_from_enhance(mix, enhanced):
    n = min(mix.shape[-1], enhanced.shape[-1])
    mix, enhanced = mix[..., :n], enhanced[..., :n]
    residual = mix - enhanced
    return to_stereo(resample(enhanced, model_sr, OUTPUT_SR)), to_stereo(resample(residual, model_sr, OUTPUT_SR))


def to_stereo(audio):
    if audio.shape[0] == 1:
        return audio.repeat(2, 1)
    return audio[:2]
