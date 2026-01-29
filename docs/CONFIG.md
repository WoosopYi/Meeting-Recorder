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

### Notion (export)

- `notionToken` (string, required for export)
  - Notion internal integration token usually starts with `ntn_...`

- `notionDatabaseId` (string, required for export)
  - The database id you want to create pages in

## Example

See `config/config.example.json`.
