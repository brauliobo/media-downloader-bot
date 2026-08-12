import ctypes
import os
import threading
import time

import numpy as np
import sherpa_onnx
import soundfile as sf
from fastapi import FastAPI, File, Form, HTTPException, UploadFile

gpu = os.environ.get("CUDA_VISIBLE_DEVICES", "?")
ctypes.CDLL(None).prctl(15, f"sherpa-gpu{gpu}".encode(), 0, 0, 0)

SEGMENTATION_MODEL = os.environ.get(
    "SHERPA_SEGMENTATION_MODEL", "/srv/sherpa-onnx/models/segmentation/model.onnx"
)
EMBEDDING_MODEL = os.environ.get(
    "SHERPA_EMBEDDING_MODEL", "/srv/sherpa-onnx/models/embedding/nemo_en_titanet_small.onnx"
)
CLUSTER_THRESHOLD = float(os.environ.get("SHERPA_CLUSTER_THRESHOLD", "0.5"))
MAX_UPLOAD_BYTES = int(os.environ.get("DIARIZATION_MAX_UPLOAD_BYTES", str(256 * 1024 * 1024)))
MAX_AUDIO_SECONDS = float(os.environ.get("DIARIZATION_MAX_AUDIO_SECONDS", "7200"))

app = FastAPI()
lock = threading.Lock()
diarizer = None


def config(speakers=-1):
    return sherpa_onnx.OfflineSpeakerDiarizationConfig(
        segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
            pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(
                model=SEGMENTATION_MODEL
            ),
            provider="cuda",
            num_threads=1,
        ),
        embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(
            model=EMBEDDING_MODEL,
            provider="cuda",
            num_threads=1,
        ),
        clustering=sherpa_onnx.FastClusteringConfig(
            num_clusters=speakers,
            threshold=CLUSTER_THRESHOLD,
        ),
        min_duration_on=0.3,
        min_duration_off=0.5,
    )


@app.on_event("startup")
def load_diarizer():
    global diarizer
    settings = config()
    if not settings.validate():
        raise RuntimeError("invalid sherpa-onnx diarization configuration")
    diarizer = sherpa_onnx.OfflineSpeakerDiarization(settings)


@app.get("/health/live")
def live():
    return {"status": "ok"}


@app.get("/health/ready")
def ready():
    if diarizer is None:
        raise HTTPException(status_code=503, detail="model is not loaded")
    return {
        "status": "ok",
        "provider": "cuda",
        "version": sherpa_onnx.__version__,
        "sample_rate": diarizer.sample_rate,
    }


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
    if sample_rate != diarizer.sample_rate:
        raise HTTPException(status_code=422, detail=f"expected {diarizer.sample_rate} Hz audio")

    samples = np.mean(samples, axis=1)
    started = time.perf_counter()
    with lock:
        diarizer.set_config(config(speakers or -1))
        result = diarizer.process(samples)
    elapsed = time.perf_counter() - started
    segments = [
        {
            "start": round(segment.start, 3),
            "end": round(segment.end, 3),
            "speaker_id": f"SPEAKER_{segment.speaker:02d}",
        }
        for segment in result.sort_by_start_time()
    ]
    duration = samples.shape[0] / sample_rate
    return {
        "segments": segments,
        "speaker_count": result.num_speakers,
        "duration": duration,
        "elapsed": elapsed,
        "rtf": elapsed / duration if duration else 0.0,
        "backend": "sherpa-onnx",
        "provider": "cuda",
    }
