# Cadence tasks. `make` with no target lists them.

.DEFAULT_GOAL := help
.PHONY: help dev stop restart status logs run build icon clean

help: ## List tasks
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-8s %s\n", $$1, $$2}'

dev: ## Launch the hot-reload app and auto-rebuild supervisor
	@scripts/dev.sh start

stop: ## Stop the supervisor and the dev app
	@scripts/dev.sh stop

restart: ## Rebuild and relaunch the dev app once
	@scripts/dev.sh restart

status: ## Show supervisor/app state and recent activity
	@scripts/dev.sh status

logs: ## Tail the supervisor and app logs
	@tail -n 30 -f build/dev-watch.log build/dev.log

run: ## Release build, signed, launched
	@scripts/run.sh

build: ## Release build only (build/Cadence.app)
	@scripts/bundle.sh

icon: ## Re-render the app icon from Support/AppIcon/render.swift
	@swift Support/AppIcon/render.swift

clean: ## Remove all build output
	@scripts/dev.sh stop >/dev/null 2>&1 || true
	@rm -rf build .build
