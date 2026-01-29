.PHONY: setup deps build build-release run-app run-cli

deps:
	@if command -v brew >/dev/null 2>&1; then \
		brew install whisper-cpp; \
	else \
		echo "Homebrew not found. Install whisper-cpp manually: https://brew.sh"; \
	fi

setup: deps
	./scripts/download-model.sh small
	./scripts/init-config.sh
	@echo "Setup complete. Run: make run-app"

build:
	swift build

build-release:
	swift build -c release

run-app:
	swift run meeting-vault-app

run-cli:
	swift run meeting-vault --help
