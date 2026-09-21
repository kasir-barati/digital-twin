SHELL         := /bin/bash
.SHELLFLAGS   := -eu -o pipefail -c
.DEFAULT_GOAL := help

.ONESHELL:
.PHONY: help init start_dev

## Show this help message
help:
	@echo "Makefile targets:"
	@echo ""
	@awk '/^## /{desc = substr($$0, 4)} /^[a-zA-Z_-]+:/{if (desc) {target = $$1; sub(/:.*/, "", target); printf "  make %-20s- %s\n", target, desc; desc = ""}}' $(MAKEFILE_LIST)
	@echo ""

## Initialize project (install deps, setup pre-commit, create .env)
init:
	@which uv > /dev/null || (echo "Error: uv is not installed. Please install uv: https://docs.astral.sh/uv/getting-started/installation/" && exit 1)
	uv venv .venv
	uv sync
	cp --update=none .env.example .env || true
	# uv run pre-commit install

## Starts the app with auto-reload
start_dev:
	uv run uvicorn server:app --reload
