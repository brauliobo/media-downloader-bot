import os
import threading
import time

import numpy as np
import setproctitle
import soundfile as sf
import torch
from fastapi import FastAPI, File, HTTPException, UploadFile
from silero_vad import get_speech_timestamps, load_silero_vad

gpu = os.environ.get("CUDA_VISIBLE_DEVICES", "?")
setproctitle.setproctitle(f"silero-vad-gpu{gpu}")

DEVICE = os.environ.get("SILERO_VAD_DEVICE", "cuda")
SAMPLE_RATE = int(os.environ.get("SILERO_VAD_SAMPLE_RATE", "16000"))
THRESHOLD = float(os.environ.get("SILERO_VAD_THRESHOLD", "0.5"))
MIN_SPEECH_MS = int(os.environ.get("SILERO_VAD_MIN_SPEECH_MS", "250"))
MIN_SILENCE_MS = int(os.environ.get("SILERO_VAD_MIN_SILENCE_MS", "100"))
SPEECH_PAD_MS = int(os.environ.get("SILERO_VAD_SPEECH_PAD_MS", "120"))
MAX_UPLOAD_BYTES = int(os.environ.get("SILERO_VAD_MAX_UPLOAD_BYTES", str(256 * 1024 * 1024)))
MAX_AUDIO_SECONDS = float(os.environ.get("SILERO_VAD_MAX_AUDIO_SECONDS", "7200"))

app = FastAPI()
lock = threading.Lock()
model = None
device = None


@app.on_event("startup")
def load_model():
    global model, device
    if DEVICE == "cuda" and not torch.cuda.is_available():
        raise RuntimeError("Silero VAD requires an available CUDA device")
    device = torch.device(DEVICE)
    model = load_silero_vad()
    model.to(device)


@app.get("/health/ready")
def ready():
    if model is None:
        raise HTTPException(status_code=503, detail="model is not loaded")
    name = torch.cuda.get_device_name(0) if DEVICE == "cuda" else DEVICE
    return {"status": "ok", "backend": "silero-vad", "device": name, "sample_rate": SAMPLE_RATE}


@app.post("/v1/vad")
def detect(file: UploadFile = File(...)):
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
    if sample_rate != SAMPLE_RATE:
        raise HTTPException(status_code=422, detail=f"expected {SAMPLE_RATE} Hz audio")

    audio = torch.from_numpy(np.mean(samples, axis=1)).to(device)
    started = time.perf_counter()
    with lock:
        timestamps = get_speech_timestamps(
            audio,
            model,
            sampling_rate=SAMPLE_RATE,
            threshold=THRESHOLD,
            min_speech_duration_ms=MIN_SPEECH_MS,
            min_silence_duration_ms=MIN_SILENCE_MS,
            speech_pad_ms=SPEECH_PAD_MS,
            return_seconds=True,
        )
    elapsed = time.perf_counter() - started
    duration = samples.shape[0] / sample_rate
    segments = [{"start": round(span["start"], 3), "end": round(span["end"], 3)} for span in timestamps]
    return {
        "segments": segments,
        "duration": duration,
        "elapsed": elapsed,
        "rtf": elapsed / duration if duration else 0.0,
        "backend": "silero-vad",
        "device": DEVICE,
    }
