# Whisper Models

This project uses `whisper-cli` from `whisper-cpp` (whisper.cpp) and requires a `ggml-*.bin` model file.

## Download

Use the provided script:

```bash
./scripts/download-model.sh medium
```

It downloads to:

`~/Library/Application Support/MeetingVault/models/`

## Model sizes

- `tiny` / `base` / `small`: faster, smaller
- `medium` / `large`: better accuracy, much larger

## Set config

Update `whisperModelPath` in:

`~/Library/Application Support/MeetingVault/config.json`
