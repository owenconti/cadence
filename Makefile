# Cadence tasks. `make` with no target lists them.

.DEFAULT_GOAL := help
.PHONY: carplay-check watch help update check perf snapshots artwork release run icon phone phone-snapshots testflight clean

help: ## List tasks
	@grep -E '^[a-z][a-z-]*:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-10s %s\n", $$1, $$2}'

update: ## Rebuild and install /Applications/Cadence.app; a running copy offers Restart app
	@scripts/bundle.sh

watch: ## Build the Apple Watch companion for Simulator
	@scripts/watch.sh

carplay-check: ## Check CarPlay page boundaries and navigation row budgets
	@bash scripts/check-carplay-pages.sh

check: ## Automated update + restart check on a throwaway copy, then the artwork audit
	@bash scripts/check-carplay-pages.sh
	@scripts/watch.sh
	@scripts/check.sh

perf: ## Measure animation lag opening a long playlist on a throwaway copy
	@scripts/perf.sh

artwork: ## Draw every artwork source from the real library, read-only; fails on any blank
	@scripts/artwork.sh

snapshots: ## Screenshot every screen from a throwaway copy into build/check/snapshots
	@CONFIG=debug APP=build/check/Cadence.app BUNDLE_ID=com.owenconti.cadence.check scripts/bundle.sh >/dev/null
	@rm -rf build/check/snapshots
	@open -g -n -W --env CADENCE_SNAPSHOTS=$(CURDIR)/build/check/snapshots build/check/Cadence.app
	@ls build/check/snapshots

release: ## Cut a release: BUMP=patch|minor|major or VERSION=x.y.z, NOTES=file, DRY_RUN=1
	@VERSION_OVERRIDE="$(VERSION)" scripts/release.sh

run: ## Rebuild, install and (re)launch the app (for humans; quits a running copy)
	@scripts/run.sh

icon: ## Re-render the app icon from Support/AppIcon/render.swift
	@swift Support/AppIcon/render.swift

testflight: ## Upload Cadence for iPhone to TestFlight; the phone installs it from there
	@scripts/testflight.sh

phone: ## Build Cadence for iPhone and install it on a plugged-in iPhone (TestFlight is the usual way)
	@scripts/phone.sh install

phone-snapshots: ## Screenshot every iPhone screen in the simulator into build/phone/snapshots
	@scripts/phone.sh snapshots

clean: ## Remove all build output
	@rm -rf build .build
