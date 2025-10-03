# Utility helpers for project maintenance.
#
# Usage:
#   make token [TOKEN_SIZE=24]
#
# TOKEN_SIZE controls the number of random bytes (default: 12) used when
# generating the base64 token. The resulting token is echoed to stdout and
# persisted under outputs/generated-token/ with the invocation timestamp.

SHELL := /bin/bash
TOKEN_SIZE ?= 12
TOKEN_OUTPUT_DIR := outputs/generated-token
TOKEN_TIMESTAMP := $(shell date +%Y%m%d-%H%M%S)
TOKEN_FILE := $(TOKEN_OUTPUT_DIR)/token-$(TOKEN_TIMESTAMP).txt

.PHONY: token
## Generate a reusable base64 token and persist it for later use.
token:
	@set -euo pipefail; \
		install -d -m 700 $(TOKEN_OUTPUT_DIR); \
		TOKEN="$$(openssl rand -base64 $(TOKEN_SIZE))"; \
		TOKEN_FILE="$(TOKEN_FILE)"; \
		printf '%s\n' "$$TOKEN" | tee "$$TOKEN_FILE"; \
		chmod 600 "$$TOKEN_FILE"; \
		echo "Saved token to $$TOKEN_FILE" >&2
