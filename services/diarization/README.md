# CUDA diarization services

The application selects a backend with `DIARIZER=PyannoteCommunity1` or
`DIARIZER=SherpaOnnx`. Their default endpoints are `http://127.0.0.1:8082`
and `http://127.0.0.1:8083`, respectively.

Both services accept `POST /v1/diarize` multipart requests with a `file` field
and an optional positive integer `speakers` field. They return backend-neutral
speaker intervals:

```json
{"segments":[{"start":0.1,"end":1.2,"speaker_id":"SPEAKER_00"}]}
```

## pyannote Community-1

The runtime is pinned to pyannote.audio 4.0.7 and PyTorch 2.8.0/cu128 under
`/srv/pyannote-community1`. Before downloading the gated model, accept its
conditions at <https://huggingface.co/pyannote/speaker-diarization-community-1>
and expose a read token only for the download:

```sh
HF_TOKEN=... /srv/pyannote-community1/runtime/bin/hf download \
  pyannote/speaker-diarization-community-1 \
  --revision 3533c8cf8e369892e6b79ff1bf80f7b0286a54ee \
  --local-dir /srv/pyannote-community1/model
```

The serving unit enables Hugging Face offline mode and does not need the token.

## sherpa-onnx

The runtime uses sherpa-onnx 1.13.4+cuda12.cudnn9 under `/srv/sherpa-onnx`,
with pyannote segmentation 3.0 and NeMo TitaNet-small models. CUDA must be set
for both segmentation and embedding. The service unit supplies the runtime
library path required by ONNX Runtime and runs one worker per GPU.

The default clustering threshold is `0.5`. Set an explicit `speakers` count
when it is known; threshold-based clustering must be calibrated on labeled,
representative recordings before production use. sherpa-onnx bypasses global
clustering for recordings short enough to produce only one segmentation
window, so an explicit count cannot be enforced for that upstream edge case.
