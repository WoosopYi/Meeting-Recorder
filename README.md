# MeetingVault

Local-first macOS menubar recorder that can:

- Record microphone audio (mic-only)
- Transcribe locally using `whisper-cli` (whisper.cpp)
- Summarize using Gemini (`gemini-3-flash-preview`)
- Generate copy-friendly notes (JSON + Markdown)

This repo does NOT include Whisper model files (they are large). You download them locally.

## Requirements

- macOS 14+
- Swift 5.9+ (Command Line Tools or Xcode)
- Homebrew (recommended)

## Quickstart

1) Install dependencies

```bash
brew install whisper-cpp
```

Or:

```bash
make deps
```

2) Download a Whisper model (example: medium)

```bash
./scripts/download-model.sh medium
```

3) Create your config file

```bash
./scripts/init-config.sh
```

Or run everything:

```bash
make setup
```

It creates:

`~/Library/Application Support/MeetingVault/config.json`

4) Run the menubar app

```bash
swift run meeting-vault-app
```

You should see `MV` in the macOS menu bar.

After recording, click `Process Last Meeting` to generate notes. A small review window will open so you can copy the output.

## Run Without Terminal (Build a .app)

If you want to launch it like a normal macOS app (double-click), build an app bundle:

```bash
make app
```

It creates:

`./dist/MeetingRecorder.app`

You can move it to `/Applications` and run it without Terminal.

## Config

See `docs/CONFIG.md`.

## Notes

- When running via `swift run`, this app is not a full `.app` bundle. Some macOS APIs behave differently in that mode.

## License

MIT. See `LICENSE`.
