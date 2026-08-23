import os
import sys
import tempfile
import threading
import zipfile
from pathlib import Path

import librosa
import numpy as np
import setproctitle
import soundfile as sf
import torch
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from starlette.background import BackgroundTask

REPOSITORY = Path(os.environ.get("BS_ROFORMER_REPOSITORY", "/srv/Music-Source-Separation-Training"))
CONFIG = Path(os.environ.get(
    "BS_ROFORMER_CONFIG",
    REPOSITORY / "configs/viperx/model_bs_roformer_ep_317_sdr_12.9755.yaml",
))
CHECKPOINT = Path(os.environ.get(
    "BS_ROFORMER_CHECKPOINT",
    "/srv/bs-roformer-models/model_bs_roformer_ep_317_sdr_12.9755.ckpt",
))
DEVICE = os.environ.get("BS_ROFORMER_DEVICE", "cuda")
MAX_UPLOAD_BYTES = int(os.environ.get("BS_ROFORMER_MAX_UPLOAD_BYTES", str(2 * 1024 * 1024 * 1024)))
BATCH_SIZE = int(os.environ.get("BS_ROFORMER_BATCH_SIZE", "1"))
BIGSHIFTS = int(os.environ.get("BS_ROFORMER_BIGSHIFTS", "1"))

sys.path.insert(0, str(REPOSITORY))
from utils.model_utils import bigshifts_wrapper, load_start_checkpoint
from utils.settings import get_model_from_config

gpu = os.environ.get("CUDA_VISIBLE_DEVICES", "?")
setproctitle.setproctitle(f"bs-roformer-gpu{gpu}")

app = FastAPI()
lock = threading.Lock()
model = None
config = None


@app.on_event("startup")
def load_model():
    global config, model
    if DEVICE == "cuda" and not torch.cuda.is_available():
        raise RuntimeError("BS-RoFormer requires an available CUDA device")
    if not CONFIG.is_file():
        raise RuntimeError(f"BS-RoFormer config does not exist: {CONFIG}")
    if not CHECKPOINT.is_file():
        raise RuntimeError(f"BS-RoFormer checkpoint does not exist: {CHECKPOINT}")

    model, config = get_model_from_config("bs_roformer", str(CONFIG))
    config.inference.batch_size = BATCH_SIZE
    checkpoint = torch.load(CHECKPOINT, map_location="cpu", weights_only=False)
    load_start_checkpoint(_checkpoint_args(), model, checkpoint, type_="inference")
    model.eval().to(DEVICE)


@app.get("/health/ready")
def ready():
    if model is None:
        raise HTTPException(status_code=503, detail="model is not loaded")
    device = torch.cuda.get_device_name(0) if DEVICE == "cuda" else DEVICE
    return {"status": "ok", "backend": "bs-roformer", "model": CHECKPOINT.name, "device": device}


@app.post("/v1/separate")
def separate(file: UploadFile = File(...)):
    workdir = tempfile.TemporaryDirectory(prefix="bs-roformer-")
    root = Path(workdir.name)
    suffix = Path(file.filename or "audio").suffix
    input_path = root / f"input{suffix}"

    try:
        copy_upload(file, input_path)
        mix, sample_rate = librosa.load(input_path, sr=config.audio.sample_rate, mono=False)
        if mix.ndim == 1:
            mix = np.stack((mix, mix))
        mix_orig = mix.copy()
        with lock:
            vocals = bigshifts_wrapper(config, model, mix, DEVICE, "bs_roformer", bigshifts=BIGSHIFTS)["vocals"]
        sf.write(root / "vocals.wav", vocals.T, sample_rate, subtype="PCM_16")
        sf.write(root / "no_vocals.wav", (mix_orig - vocals).T, sample_rate, subtype="PCM_16")

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


def _checkpoint_args():
    return type("Arguments", (), {
        "start_check_point": str(CHECKPOINT),
        "model_type": "bs_roformer",
        "lora_checkpoint_loralib": "",
    })()
