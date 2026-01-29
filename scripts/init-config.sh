#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TEMPLATE_PATH="$REPO_ROOT/config/config.example.json"
CONFIG_DIR="$HOME/Library/Application Support/MeetingVault"
CONFIG_PATH="$CONFIG_DIR/config.json"
MODELS_DIR="$CONFIG_DIR/models"

mkdir -p "$CONFIG_DIR"

if [[ -f "$CONFIG_PATH" ]]; then
  echo "Config already exists: $CONFIG_PATH"
  exit 0
fi

if [[ ! -f "$TEMPLATE_PATH" ]]; then
  echo "Missing template: $TEMPLATE_PATH" >&2
  exit 1
fi

mkdir -p "$MODELS_DIR"

WHISPER_BIN="$(command -v whisper-cli || true)"

DEFAULT_MODEL=""
if [[ -f "$MODELS_DIR/ggml-small.bin" ]]; then
  DEFAULT_MODEL="$MODELS_DIR/ggml-small.bin"
elif [[ -f "$MODELS_DIR/ggml-medium.bin" ]]; then
  DEFAULT_MODEL="$MODELS_DIR/ggml-medium.bin"
fi

python3 - "$TEMPLATE_PATH" "$CONFIG_PATH" "$WHISPER_BIN" "$DEFAULT_MODEL" <<'PY'
import json
import os
import sys

template_path, config_path, whisper_bin, default_model = sys.argv[1:5]

with open(template_path, "r", encoding="utf-8") as f:
    data = json.load(f)

if whisper_bin:
    data["whisperBinary"] = whisper_bin

if default_model and not data.get("whisperModelPath"):
    data["whisperModelPath"] = default_model

os.makedirs(os.path.dirname(config_path), exist_ok=True)
with open(config_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")

print(config_path)
PY

echo "Created config: $CONFIG_PATH"
echo "Edit it to add Gemini/Notion keys."

open "$CONFIG_PATH" || true
