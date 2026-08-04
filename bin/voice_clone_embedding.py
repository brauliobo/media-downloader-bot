#!/usr/bin/env python3

"""Compute Sherpa-ONNX speaker-embedding cosine similarity."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import sherpa_onnx
import soundfile as sf


def embedding(extractor: sherpa_onnx.SpeakerEmbeddingExtractor, path: str) -> np.ndarray:
    samples, sample_rate = sf.read(path, always_2d=True, dtype="float32")
    samples = np.ascontiguousarray(np.mean(samples, axis=1))
    stream = extractor.create_stream()
    stream.accept_waveform(sample_rate=sample_rate, waveform=samples)
    stream.input_finished()
    if not extractor.is_ready(stream):
        raise RuntimeError(f"speaker embedding extractor is not ready for {path}")
    return np.asarray(extractor.compute(stream), dtype=np.float32)


def average_embedding(extractor: sherpa_onnx.SpeakerEmbeddingExtractor, paths: list[str]) -> np.ndarray:
    vectors = [embedding(extractor, path) for path in paths]
    return np.mean(vectors, axis=0)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--provider", default="cuda")
    parser.add_argument("--num-threads", type=int, default=1)
    parser.add_argument("--reference", nargs="+", required=True)
    parser.add_argument("--sample", nargs="+", required=True)
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args()

    config = sherpa_onnx.SpeakerEmbeddingExtractorConfig(
        model=args.model,
        num_threads=args.num_threads,
        debug=args.debug,
        provider=args.provider,
    )
    if not config.validate():
        raise ValueError(f"Invalid speaker embedding configuration: {config}")

    extractor = sherpa_onnx.SpeakerEmbeddingExtractor(config)
    reference = average_embedding(extractor, args.reference)
    sample = average_embedding(extractor, args.sample)
    reference_norm = float(np.linalg.norm(reference))
    sample_norm = float(np.linalg.norm(sample))
    if not reference_norm or not sample_norm:
        raise ValueError("speaker embedding vector has zero norm")

    print(json.dumps({
        "reference_files": [str(Path(path)) for path in args.reference],
        "sample_files": [str(Path(path)) for path in args.sample],
        "dimension": int(reference.size),
        "reference_norm": reference_norm,
        "sample_norm": sample_norm,
        "cosine_similarity": float(np.dot(reference, sample) / (reference_norm * sample_norm)),
    }))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
