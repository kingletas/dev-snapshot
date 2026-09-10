# dev-snapshot — one encrypted archive of a source tree, minus what a package
# manager can rebuild.
#
# Configure once in ~/.config/dev-snapshot/config (SOURCE, DEST, RECIPIENT),
# then `make regular` needs nothing else.
#
# Run `make` with no arguments for the list.

SHELL       := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

PREFIX ?= $(HOME)/bin
DS     ?= ./bin/dev-snapshot

# Every snapshot target is interactive by default: it prints the plan and asks.
# YES=1 skips the prompt, which is what an unattended run wants and what a
# person at a terminal should have to type on purpose.
ifeq ($(YES),1)
  CONFIRM := -y
else
  CONFIRM :=
endif

.PHONY: help
help: ## Show this help
	@echo
	@echo "  dev-snapshot — encrypted snapshots of a source tree"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "    \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  Config:   ~/.config/dev-snapshot/config"
	@echo "  Unattended:  make regular YES=1"
	@echo

# --- taking a snapshot ------------------------------------------------------

.PHONY: regular
regular: ## Full snapshot — everything but the rebuildable trees
	@$(DS) create $(CONFIRM)

.PHONY: slim
slim: ## Documents only — no history, logs, archives, binaries or large files
	@$(DS) create --slim $(CONFIRM)

.PHONY: plan
plan: ## What a full snapshot would archive and drop, writing nothing
	@$(DS) create -n

.PHONY: plan-slim
plan-slim: ## The same, for a slim snapshot
	@$(DS) create -n --slim

# --- what is on the drive ---------------------------------------------------

.PHONY: list
list: ## Snapshots at the destination, with dates
	@$(DS) list

.PHONY: verify
verify: ## Decrypt a snapshot and read it back — make verify FILE=path
	@test -n "$(FILE)" || { echo "usage: make verify FILE=<path to a .gpg>"; exit 2; }
	@$(DS) verify "$(FILE)"

.PHONY: restore
restore: ## Unpack a snapshot — make restore FILE=path DIR=path
	@test -n "$(FILE)" -a -n "$(DIR)" || { echo "usage: make restore FILE=<path> DIR=<path>"; exit 2; }
	@$(DS) restore "$(FILE)" "$(DIR)"

.PHONY: prune
prune: ## Delete all but the newest N of one label — make prune KEEP=3
	@test -n "$(KEEP)" || { echo "usage: make prune KEEP=<number>"; exit 2; }
	@$(DS) prune --keep "$(KEEP)"

# --- rules ------------------------------------------------------------------

.PHONY: rules
rules: ## The ruleset, and what each rule matches in your tree
	@$(DS) rules

.PHONY: rules-slim
rules-slim: ## The same, with the slim ruleset layered on
	@$(DS) rules --slim

.PHONY: rules-add
rules-add: ## Add a rule — make rules-add NAME=target [GUARD=sibling:Cargo.toml] [WHY="..."] [KIND=dir]
	@test -n "$(NAME)" || { \
		echo "usage: make rules-add NAME=<directory or pattern> [GUARD=...] [WHY=\"...\"] [KIND=dir|file]"; \
		echo; \
		echo "  make rules-add NAME=.cache WHY=\"tool cache\""; \
		echo "  make rules-add NAME=target GUARD=sibling:Cargo.toml WHY=\"cargo build output\""; \
		echo "  make rules-add NAME='*.bak' KIND=file WHY=\"editor backup\""; \
		echo; \
		echo "  GUARD is sibling:FILE (beside it), has:FILE (inside it), or omitted."; \
		exit 2; }
	@$(DS) rules add "$(NAME)" \
		--kind "$(or $(KIND),dir)" \
		$(if $(GUARD),--guard "$(GUARD)",) \
		$(if $(WHY),--why "$(WHY)",)

# --- install ----------------------------------------------------------------

.PHONY: install
install: ## Copy dev-snapshot and its rulesets into ~/bin (PREFIX= to change)
	@scripts/install "$(PREFIX)"

.PHONY: uninstall
uninstall: ## Remove the installed copy, leaving your config and snapshots alone
	@rm -f "$(PREFIX)/dev-snapshot"
	@rm -rf "$(PREFIX)/dev-snapshot.d"
	@echo "removed dev-snapshot from $(PREFIX)"
	@echo "your config and your snapshots were not touched"

# --- checks -----------------------------------------------------------------

.PHONY: test
test: ## The end-to-end suite — no network, no key generation
	@tests/run.sh

.PHONY: lint
lint: ## shellcheck, and the ruleset's own guard validation
	@printf '  %-14s ' "shellcheck"
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck bin/dev-snapshot tests/run.sh scripts/install packaging/release-notes.sh && echo "ok"; \
	else \
		echo "skipped (not installed)"; \
	fi
	@printf '  %-14s ' "rulesets"
	@bad=0; for f in bin/dev-snapshot.d/*.rules; do \
		while IFS=$$'\t' read -r kind name guard why; do \
			case "$$kind" in ''|\#*) continue ;; esac; \
			case "$$kind" in dir|file) ;; *) echo "$$f: unknown kind '$$kind' for $$name"; bad=1 ;; esac; \
			case "$${guard:--}" in -|sibling:*|has:*) ;; *) echo "$$f: unknown guard '$$guard' for $$name"; bad=1 ;; esac; \
			case "$$kind" in file) [ "$${guard:--}" = "-" ] || { echo "$$f: file rule '$$name' has a guard, which is never applied"; bad=1; } ;; esac; \
		done < "$$f"; \
	done; [ "$$bad" = 0 ] && echo "ok" || exit 1

.PHONY: check
check: lint test ## Everything a commit has to pass
	@echo
	@echo "  lint and tests pass"
