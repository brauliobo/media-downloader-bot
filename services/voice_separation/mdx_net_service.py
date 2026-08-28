import logging
import os
import tempfile
import threading
import zipfile
from pathlib import Path

import setproctitle
from audio_separator.separator import Separator
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from starlette.background import BackgroundTask

MODEL = os.environ.get("MDX_MODEL", "Kim_Vocal_2.onnx")
DEVICE = os.environ.get("MDX_DEVICE", "cuda")
MODEL_DIR = os.environ.get("AUDIO_SEPARATOR_MODEL_DIR", os.environ.get("MDX_MODEL_DIR", "/var/cache/mdx-net-0/models"))
MAX_UPLOAD_BYTES = int(os.environ.get("MDX_MAX_UPLOAD_BYTES", str(2 * 1024 * 1024 * 1024)))
STEM_NAMES = {"Vocals": "vocals", "Instrumental": "no_vocals"}

gpu = os.environ.get("CUDA_VISIBLE_DEVICES", "?")
setproctitle.setproctitle(f"mdx-net-gpu{gpu}")

app = FastAPI()
lock = threading.Lock()
separator = None


@app.on_event("startup")
def load_separator():
    global separator
    if DEVICE == "cuda":
        import onnxruntime as ort
        import torch

        if hasattr(ort, "preload_dlls"):
            ort.preload_dlls()
        if not torch.cuda.is_available():
            raise RuntimeError("MDX-Net requires an available CUDA device")
        if "CUDAExecutionProvider" not in ort.get_available_providers():
            raise RuntimeError("MDX-Net requires ONNX Runtime CUDA")

    Path(MODEL_DIR).mkdir(parents=True, exist_ok=True)
    separator = Separator(
        log_level=logging.WARNING,
        model_file_dir=MODEL_DIR,
        output_dir=tempfile.gettempdir(),
        output_format="WAV",
        sample_rate=44100,
        use_soundfile=True,
    )
    separator.load_model(model_filename=MODEL)
    if DEVICE == "cuda" and getattr(separator, "onnx_execution_provider", [None])[0] != "CUDAExecutionProvider":
        raise RuntimeError("MDX-Net did not enable ONNX Runtime CUDA")


@app.get("/health/ready")
def ready():
    if separator is None:
        raise HTTPException(status_code=503, detail="model is not loaded")
    return {"status": "ok", "backend": "mdx-net", "model": MODEL, "device": _device_name()}


@app.post("/v1/separate")
def separate(file: UploadFile = File(...)):
    workdir = tempfile.TemporaryDirectory(prefix="mdx-net-")
    root = Path(workdir.name)
    suffix = Path(file.filename or "audio").suffix
    input_path = root / f"input{suffix}"

    try:
        copy_upload(file, input_path)
        with lock:
            separator.output_dir = str(root)
            if getattr(separator, "model_instance", None) is not None:
                separator.model_instance.output_dir = str(root)
            outputs = separator.separate(str(input_path), custom_output_names=STEM_NAMES)
        vocals, non_vocals = stem_paths(root, outputs)
        archive = root / "stems.zip"
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_STORED) as output:
            output.write(vocals, "vocals.wav")
            output.write(non_vocals, "no_vocals.wav")
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


def stem_paths(root, outputs):
    paths = [(Path(path) if Path(path).is_absolute() else root / path) for path in outputs]
    by_name = {path.name: path for path in paths}
    vocals, non_vocals = by_name.get("vocals.wav"), by_name.get("no_vocals.wav")
    if vocals is None or non_vocals is None or not vocals.is_file() or not non_vocals.is_file():
        raise RuntimeError(f"MDX-Net returned unexpected stems: {outputs}")
    return vocals, non_vocals


def _device_name():
    if DEVICE != "cuda":
        return DEVICE
    import torch

    return torch.cuda.get_device_name(0)
