# Cadence tasks. `make` with no target lists them.

.DEFAULT_GOAL := help
.PHONY: help update check snapshots run icon clean

help: ## List tasks
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-10s %s\n", $$1, $$2}'

update: ## Rebuild and install /Applications/Cadence.app; a running copy offers Restart app
	@scripts/bundle.sh

check: ## Automated update + restart check on a throwaway copy
	@scripts/check.sh

snapshots: ## Screenshot every screen from a throwaway copy into build/check/snapshots
	@CONFIG=debug APP=build/check/Cadence.app scripts/bundle.sh >/dev/null
	@rm -rf build/check/snapshots
	@open -g -n -W --env CADENCE_SNAPSHOTS=$(CURDIR)/build/check/snapshots build/check/Cadence.app
	@ls build/check/snapshots

run: ## Rebuild, install and (re)launch the app (for humans; quits a running copy)
	@scripts/run.sh

icon: ## Re-render the app icon from Support/AppIcon/render.swift
	@swift Support/AppIcon/render.swift

clean: ## Remove all build output
	@rm -rf build .build
