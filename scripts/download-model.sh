#!/usr/bin/env bash
set -euo pipefail

MODEL_NAME="${1:-small}"

DEST_DIR="$HOME/Library/Application Support/MeetingVault/models"
mkdir -p "$DEST_DIR"

FILENAME="ggml-${MODEL_NAME}.bin"
DEST_PATH="$DEST_DIR/$FILENAME"

URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${FILENAME}"

if [[ -f "$DEST_PATH" ]]; then
  echo "Model already exists: $DEST_PATH"
  exit 0
fi

echo "Downloading model: $MODEL_NAME"
echo "From: $URL"
echo "To:   $DEST_PATH"

curl -L --fail --output "$DEST_PATH" "$URL"

echo "Done. Set whisperModelPath to: $DEST_PATH"
