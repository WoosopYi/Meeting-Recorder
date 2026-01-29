# Troubleshooting

## Menu bar icon not visible

- `meeting-vault-app` is a menu bar app (no window by default).
- Run it and look for `MV` in the macOS menu bar.

## Notion 403 restricted_resource

Your Integration token exists, but it does not have access to the database.

Fix:

1. Open the target Notion database
2. Click `Share`
3. Invite your Integration and give it edit access

## Whisper errors

### whisper-cli not found

- Install: `brew install whisper-cpp`
- Confirm: `which whisper-cli`

### Missing model

- Download one: `./scripts/download-model.sh medium`
- Set `whisperModelPath` in config

## Microphone permission denied

When running via `swift run`, permission may be requested for the parent process (Terminal).
Grant microphone permission in System Settings.
