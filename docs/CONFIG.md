# Config

MeetingVault reads configuration from:

`~/Library/Application Support/MeetingVault/config.json`

Create it with:

```bash
./scripts/init-config.sh
```

## Fields

### Whisper (local transcription)

- `whisperBinary` (string, optional)
  - Default: `whisper-cli`
  - Example: `/opt/homebrew/bin/whisper-cli`

- `whisperModelPath` (string, required for transcription)
  - Example: `~/Library/Application Support/MeetingVault/models/ggml-medium.bin`

- `whisperLanguage` (string, optional)
  - Example: `ko`

### Gemini (summarization)

- `geminiApiKey` (string, required for summarization)
- `geminiModel` (string, optional)
  - Default: `gemini-3-flash-preview`

### Notion

MeetingVault does not call the Notion API.
Copy the generated Markdown notes into Notion manually.

## Example

See `config/config.example.json`.
