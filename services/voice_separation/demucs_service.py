import os
import tempfile
import threading
import zipfile
from pathlib import Path

import torch
from demucs.api import Separator, save_audio
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from starlette.background import BackgroundTask

MODEL = os.environ.get("DEMUCS_MODEL", "htdemucs")
DEVICE = os.environ.get("DEMUCS_DEVICE", "cuda")
MAX_UPLOAD_BYTES = int(os.environ.get("DEMUCS_MAX_UPLOAD_BYTES", str(2 * 1024 * 1024 * 1024)))

app = FastAPI()
lock = threading.Lock()
separator = None


@app.on_event("startup")
def load_separator():
    global separator
    if DEVICE == "cuda" and not torch.cuda.is_available():
        raise RuntimeError("Demucs requires an available CUDA device")
    separator = Separator(model=MODEL, device=DEVICE, jobs=0, progress=False)


@app.get("/health/ready")
def ready():
    if separator is None:
        raise HTTPException(status_code=503, detail="model is not loaded")
    device = torch.cuda.get_device_name(0) if DEVICE == "cuda" else DEVICE
    return {"status": "ok", "backend": "demucs", "model": MODEL, "device": device}


@app.post("/v1/separate")
def separate(file: UploadFile = File(...)):
    workdir = tempfile.TemporaryDirectory(prefix="demucs-")
    root = Path(workdir.name)
    suffix = Path(file.filename or "audio").suffix
    input_path = root / f"input{suffix}"

    try:
        copy_upload(file, input_path)
        with lock:
            _, sources = separator.separate_audio_file(input_path)
        vocals = sources["vocals"]
        non_vocals = torch.zeros_like(vocals)
        for name, source in sources.items():
            if name != "vocals":
                non_vocals += source
        save_audio(vocals, root / "vocals.wav", separator.samplerate)
        save_audio(non_vocals, root / "no_vocals.wav", separator.samplerate)

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
