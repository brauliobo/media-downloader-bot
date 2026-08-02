import os
import threading
import time

import numpy as np
import soundfile as sf
import torch
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from pyannote.audio import Pipeline

MODEL_PATH = os.environ.get("PYANNOTE_MODEL", "/srv/pyannote-community1/model")
DEVICE = os.environ.get("DIARIZATION_DEVICE", "cuda")
MAX_UPLOAD_BYTES = int(os.environ.get("DIARIZATION_MAX_UPLOAD_BYTES", str(256 * 1024 * 1024)))
MAX_AUDIO_SECONDS = float(os.environ.get("DIARIZATION_MAX_AUDIO_SECONDS", "7200"))

app = FastAPI()
lock = threading.Lock()
pipeline = None


@app.on_event("startup")
def load_pipeline():
    global pipeline
    if DEVICE != "cuda" or not torch.cuda.is_available():
        raise RuntimeError("pyannote requires an available CUDA device")
    pipeline = Pipeline.from_pretrained(MODEL_PATH)
    pipeline.to(torch.device("cuda:0"))


@app.get("/health/live")
def live():
    return {"status": "ok"}


@app.get("/health/ready")
def ready():
    if pipeline is None:
        raise HTTPException(status_code=503, detail="model is not loaded")
    return {"status": "ok", "device": torch.cuda.get_device_name(0), "model": MODEL_PATH}


@app.post("/v1/diarize")
def diarize(file: UploadFile = File(...), speakers: int | None = Form(None)):
    if speakers is not None and speakers < 1:
        raise HTTPException(status_code=422, detail="speakers must be positive")

    file.file.seek(0, os.SEEK_END)
    upload_bytes = file.file.tell()
    file.file.seek(0)
    if upload_bytes > MAX_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail="audio upload is too large")

    try:
        info = sf.info(file.file)
        file.file.seek(0)
        if info.duration > MAX_AUDIO_SECONDS:
            raise HTTPException(status_code=413, detail="audio duration exceeds the limit")
        samples, sample_rate = sf.read(file.file, dtype="float32", always_2d=True)
    except HTTPException:
        raise
    except Exception as error:
        raise HTTPException(status_code=422, detail=f"invalid audio: {error}") from error

    waveform = torch.from_numpy(np.mean(samples, axis=1)).unsqueeze(0)
    options = {"num_speakers": speakers} if speakers is not None else {}
    started = time.perf_counter()
    with lock:
        torch.cuda.reset_peak_memory_stats()
        output = pipeline({"waveform": waveform, "sample_rate": sample_rate}, **options)
        torch.cuda.synchronize()
        peak_memory = torch.cuda.max_memory_allocated()
    elapsed = time.perf_counter() - started
    annotation = output.exclusive_speaker_diarization
    segments = [
        {"start": round(turn.start, 3), "end": round(turn.end, 3), "speaker_id": speaker}
        for turn, _, speaker in annotation.itertracks(yield_label=True)
    ]
    duration = samples.shape[0] / sample_rate
    return {
        "segments": segments,
        "speaker_count": len(annotation.labels()),
        "duration": duration,
        "elapsed": elapsed,
        "rtf": elapsed / duration if duration else 0.0,
        "peak_cuda_bytes": peak_memory,
        "backend": "pyannote-community-1",
    }
