import ctypes
import os
import site
import tempfile
import threading
import zipfile
from pathlib import Path

import librosa
import numpy as np
import setproctitle
import soundfile as sf
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from starlette.background import BackgroundTask

_NVIDIA_LIB_ORDER = (
    "cuda_runtime", "cublas", "cudnn", "cufft", "curand",
    "cusolver", "cusparse", "cuda_nvrtc", "nccl", "cuda_cupti",
)


def _nvidia_lib_dirs():
    dirs = []
    for sp in site.getsitepackages():
        nvidia = Path(sp) / "nvidia"
        if nvidia.is_dir():
            dirs.extend(path for path in nvidia.glob("*/lib") if path.is_dir())
    return dirs


def _preload_cuda11():
    dirs = {path.parent.parent.name: path for path in _nvidia_lib_dirs()}
    for name in _NVIDIA_LIB_ORDER:
        libdir = dirs.get(name)
        if libdir is None:
            continue
        for so in sorted(libdir.glob("lib*.so*")):
            try:
                ctypes.CDLL(str(so), mode=ctypes.RTLD_GLOBAL)
                break
            except OSError:
                continue


_preload_cuda11()

MODEL = os.environ.get("SPLEETER_MODEL", "spleeter:2stems")
DEVICE = os.environ.get("SPLEETER_DEVICE", "cuda")
SAMPLE_RATE = int(os.environ.get("SPLEETER_SAMPLE_RATE", "44100"))
MAX_UPLOAD_BYTES = int(os.environ.get("SPLEETER_MAX_UPLOAD_BYTES", str(2 * 1024 * 1024 * 1024)))

gpu = os.environ.get("CUDA_VISIBLE_DEVICES", "?")
setproctitle.setproctitle(f"spleeter-gpu{gpu}")

app = FastAPI()
lock = threading.Lock()
separator = None


@app.on_event("startup")
def load_separator():
    global separator
    if DEVICE == "cuda":
        import tensorflow as tf

        gpus = tf.config.list_physical_devices("GPU")
        if not gpus:
            raise RuntimeError("Spleeter requires an available CUDA device")
        for gpu_device in gpus:
            tf.config.experimental.set_memory_growth(gpu_device, True)

    from spleeter.separator import Separator

    separator = Separator(MODEL, multiprocess=False)


@app.get("/health/ready")
def ready():
    if separator is None:
        raise HTTPException(status_code=503, detail="model is not loaded")
    device = _device_name()
    return {"status": "ok", "backend": "spleeter", "model": MODEL, "device": device}


@app.post("/v1/separate")
def separate(file: UploadFile = File(...)):
    workdir = tempfile.TemporaryDirectory(prefix="spleeter-")
    root = Path(workdir.name)
    suffix = Path(file.filename or "audio").suffix
    input_path = root / f"input{suffix}"

    try:
        copy_upload(file, input_path)
        mix = load_stereo(input_path)
        with lock:
            sources = separator.separate(mix, str(input_path))
        vocals = sources["vocals"]
        accompaniment = sources["accompaniment"]
        sf.write(root / "vocals.wav", vocals, SAMPLE_RATE, subtype="PCM_16")
        sf.write(root / "no_vocals.wav", accompaniment, SAMPLE_RATE, subtype="PCM_16")

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


def load_stereo(path):
    mix, _ = librosa.load(path, sr=SAMPLE_RATE, mono=False)
    if mix.ndim == 1:
        return np.stack((mix, mix), axis=-1)
    return mix.T


def _device_name():
    if DEVICE != "cuda":
        return DEVICE
    import tensorflow as tf

    gpus = tf.config.list_physical_devices("GPU")
    if not gpus:
        return "cuda"
    details = tf.config.experimental.get_device_details(gpus[0])
    return details.get("device_name") or gpus[0].name
