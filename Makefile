DOTFILES_DIR := $(shell pwd)
CLAUDE_DIR   := $(HOME)/.claude
SOURCEROOT   := $(HOME)/SourceRoot
BREW_PREFIX  := $(shell brew --prefix 2>/dev/null || echo /opt/homebrew)

# Resolve a Homebrew service's plist/label under EITHER name it may carry.
# Homebrew 6 renamed `homebrew.mxcl.<name>` to `sh.brew.<name>`, and the rename
# lands on the next `brew services start|restart`, not at upgrade time — so both
# names are live across these two machines. Recipes run under /bin/sh, hence the
# CLI form rather than sourcing; resolved AT RECIPE TIME rather than via
# $(shell ...) because `make setup` itself restarts services and thereby renames
# their plists mid-run. See scripts/lib/brew-service.sh.
BREW_SERVICE := bash $(DOTFILES_DIR)/scripts/lib/brew-service.sh

# Data half of the headless secrets system (schemas + encrypted cache) —
# see ~/SourceRoot/dotfiles-private, override for testing/alternate checkouts.
SECRETS_PRIVATE_REPO ?= $(HOME)/SourceRoot/dotfiles-private

# Colima (Docker runtime VM — replaces OrbStack/Docker Desktop).
# These are ceilings (not reservations): idle VM holds ~1.3GB regardless;
# CPU is time-shared (free when idle). Bump for heavy stacks like clickstack:
#   COLIMA_MEMORY=10 make colima-restart
# Defaults key on the secrets-backend marker, like brew-upgrade.sh: the dev host
# (cache) runs the real stacks and gets 4/8/60; the MacBook (op) rarely runs
# Docker and gets 2/4/30. colima-restart writes cpu/memory back into the
# persisted colima.yaml, so a single machine-agnostic default would silently
# resize the other machine on its next restart.
SECRETS_BACKEND := $(shell tr -d '[:space:]' < $(HOME)/.config/secrets/backend 2>/dev/null)
ifeq ($(SECRETS_BACKEND),op)
COLIMA_CPU    ?= 2
COLIMA_MEMORY ?= 4
COLIMA_DISK   ?= 30
else
COLIMA_CPU    ?= 4
COLIMA_MEMORY ?= 8
COLIMA_DISK   ?= 60
endif

# Collie — phone web-UI control surface for the herd (herdr plugin + Bun
# bridge), installed by `make collie-setup`. Pinned to a COMMIT for the same
# reason a third-party plugin always is here: `herdr plugin install` re-clones
# and rebuilds the repo
# every time, so an upgrade has to be a reviewed diff of this pin, not
# whatever tag happens to move.
COLLIE_SOURCE  := AltanS/collie
COLLIE_REF     := 2eff683d74511398923d4cb5a5ee7ac4f758ff32
COLLIE_VERSION := 1.5.0

# xcaddy + the Cloudflare DNS module, used by `make caddy-dns-build` to bake
# DNS-01 support into the Homebrew Caddy binary (stock Homebrew Caddy ships
# zero DNS provider modules). Same pinning discipline as COLLIE_REF: xcaddy fetches and compiles arbitrary Go modules on every
# invocation, so an upgrade has to be a reviewed diff of these lines, not
# whatever `@latest` resolves to on the day it happens to run.
XCADDY_VERSION           ?= v0.4.7
CADDY_DNS_MODULE         ?= github.com/caddy-dns/cloudflare
CADDY_DNS_MODULE_VERSION ?= v0.2.4

# ============================================================================
# Setup — idempotent, safe to run on a fresh machine or re-run after changes
# Existing real files are backed up to <file>.bak before being replaced.
# ============================================================================

.PHONY: setup
setup:
	@echo ""
	@echo "  Setting up dotfiles..."
	@echo ""
	@$(MAKE) --no-print-directory _check-prereqs
	@$(MAKE) --no-print-directory _setup-brew
	@$(MAKE) --no-print-directory _setup-packages
	@$(MAKE) --no-print-directory _setup-claude
	@$(MAKE) --no-print-directory _setup-config
	@$(MAKE) --no-print-directory _setup-hooks
	@$(MAKE) --no-print-directory _setup-scripts
	@$(MAKE) --no-print-directory _setup-zshenv
	@$(MAKE) --no-print-directory _setup-skills
	@$(MAKE) --no-print-directory _setup-imgcli
	@$(MAKE) --no-print-directory _setup-settings
	@$(MAKE) --no-print-directory _setup-gitignore
	@$(MAKE) --no-print-directory _setup-ghostty
	@$(MAKE) --no-print-directory _setup-tools
	@$(MAKE) --no-print-directory _setup-caddy
	@$(MAKE) --no-print-directory _setup-browser
	@$(MAKE) --no-print-directory _setup-sideclaw-mcp
	@$(MAKE) --no-print-directory _setup-pnpm
	@$(MAKE) --no-print-directory _setup-op-token
	@$(MAKE) --no-print-directory _setup-secrets
	@$(MAKE) --no-print-directory _setup-sdk-keys
	@$(MAKE) --no-print-directory _setup-research-gateway-mcp
	@$(MAKE) --no-print-directory _cleanup-hyperdx-mcp
	@$(MAKE) --no-print-directory _setup-ssh
	@$(MAKE) --no-print-directory _setup-karabiner
	@$(MAKE) --no-print-directory _setup-rules
	@$(MAKE) --no-print-directory _setup-agents
	@$(MAKE) --no-print-directory _setup-output-styles
	@$(MAKE) --no-print-directory _setup-usage-tracker
	@$(MAKE) --no-print-directory _setup-colima
	@echo ""
	@echo "  Done. Reload your shell: source ~/.zshrc"
	@echo ""

.PHONY: _check-prereqs
_check-prereqs:
	@echo "  Checking prerequisites..."
	@if [ ! -d "/Applications/1Password.app" ] && [ ! -d "$(HOME)/Applications/1Password.app" ]; then \
		echo ""; \
		echo "  ✗ 1Password app not found."; \
		echo ""; \
		echo "    Install 1Password before running make setup:"; \
		echo "      https://1password.com/downloads/mac/"; \
		echo ""; \
		echo "    Then install the CLI integration:"; \
		echo "      System Preferences → 1Password → Developer → Enable CLI"; \
		echo ""; \
		exit 1; \
	fi
	@if ! command -v op >/dev/null 2>&1; then \
		echo ""; \
		echo "  ✗ 1Password CLI (op) not found."; \
		echo ""; \
		echo "    Enable the CLI in 1Password:"; \
		echo "      System Preferences → 1Password → Developer → Enable CLI"; \
		echo ""; \
		exit 1; \
	fi
	@echo "    ✓ 1Password app + CLI ready"

.PHONY: _setup-brew
_setup-brew:
	@echo "  Homebrew..."
	@if command -v brew >/dev/null 2>&1; then \
		echo "    · brew $$(brew --version | head -1) (ok)"; \
	else \
		echo "    Installing Homebrew..."; \
		/bin/bash -c "$$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; \
		echo "    ✓ Homebrew installed"; \
	fi

.PHONY: _setup-packages
_setup-packages:
	@echo "  Brew packages (Brewfile)..."
	@# Single source of truth for every brew-managed package (taps, formulae, casks).
	@# Idempotent: installs only what is missing. npm-global + uv tools are installed
	@# later by their own steps (they need Node/uv on PATH, not ready this early).
	@# HOMEBREW_REQUIRE_TAP_TRUST=1 (config/zsh/brew.zsh) makes `brew bundle` REFUSE any
	@# declared third-party tap that isn't trusted yet — which aborts the ENTIRE bundle on
	@# a fresh machine (silently skipping colima/docker/etc.). Trust exactly the taps the
	@# Brewfile declares first — self-maintaining, no hardcoded list, only the vetted manifest.
	@grep -E '^tap "' $(DOTFILES_DIR)/Brewfile | sed -E 's/^tap "([^"]+)".*/\1/' | while read -r t; do \
		brew trust "$$t" >/dev/null 2>&1 && echo "    · trusted tap $$t" || true; \
	done
	@brew bundle install --file=$(DOTFILES_DIR)/Brewfile --no-upgrade \
		&& echo "    ✓ Brewfile satisfied" \
		|| echo "    ✗ brew bundle failed — run: make brew-check"
	@# A fresh machine needs caddy pinned from the first bundle install —
	@# otherwise the first bare `brew upgrade` anyone runs reverts the caddy DNS
	@# module before `make caddy-dns-build` has ever run once. See brew-upgrade.sh.
	@bash $(DOTFILES_DIR)/scripts/brew-upgrade.sh --pins-only

.PHONY: _setup-claude
_setup-claude:
	@echo "  Claude Code..."
	@if command -v claude >/dev/null 2>&1; then \
		echo "    · claude $$(claude --version 2>/dev/null | head -1) (ok)"; \
	else \
		echo "    Installing Claude Code..."; \
		curl -fsSL https://claude.ai/install.sh | bash; \
		echo "    ✓ Claude Code installed"; \
	fi

.PHONY: _setup-config
_setup-config:
	@echo "  Config..."
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/config/global.CLAUDE.md" \
		DST="$(CLAUDE_DIR)/CLAUDE.md"
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/config/zshrc" \
		DST="$(HOME)/.zshrc"
	@mkdir -p $(HOME)/.zsh
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/config/zsh" \
		DST="$(HOME)/.zsh/conf.d"
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/config/gitconfig" \
		DST="$(HOME)/.gitconfig"
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/config/gitconfig-personal" \
		DST="$(HOME)/.gitconfig-personal"
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/config/gitconfig-work" \
		DST="$(HOME)/.gitconfig-work"
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/config/bunfig.toml" \
		DST="$(HOME)/.bunfig.toml"
	@mkdir -p $(HOME)/.config
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/config/starship.toml" \
		DST="$(HOME)/.config/starship.toml"
	@# herdr: link the FILE, never the directory — ~/.config/herdr also holds
	@# herdr.sock, herdr-client.sock and the rotating logs, which are
	@# machine-local runtime state. Linked here rather than in the opt-in
	@# `herdr-setup` because the config governs the client too, and the
	@# MacBook runs a client (desk path) without ever running a server.
	@mkdir -p $(HOME)/.config/herdr
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/config/herdr/config.toml" \
		DST="$(HOME)/.config/herdr/config.toml"

.PHONY: _setup-tools
_setup-tools:
	@echo "  Tools..."
	@# Brew CLIs (jq gh fzf zoxide wtp fnm uv age python@3.14 bun) come from the
	@# Brewfile via _setup-packages. Confirm they resolve; flag drift if not.
	@for t in jq gh fzf zoxide wtp fnm uv age bun; do \
		command -v $$t >/dev/null 2>&1 && echo "    ✓ $$t" || echo "    ✗ $$t [missing — run: make brew-check]"; \
	done
	@# python@3.14 ships from the Brewfile; prune older pythons if nothing depends on them
	@for old in python@3.11 python@3.12 python@3.13; do \
		if brew list "$$old" &>/dev/null; then \
			if [ -z "$$(brew uses --installed "$$old" 2>/dev/null)" ]; then \
				brew uninstall "$$old" && echo "    ✓ removed $$old (no dependents)"; \
			else \
				echo "    · $$old kept (required by: $$(brew uses --installed $$old | tr '\n' ' '))"; \
			fi; \
		fi; \
	done
	@# coderabbit cask ships from the Brewfile; auth is a manual one-time step
	@command -v coderabbit >/dev/null 2>&1 \
		&& echo "    · coderabbit (run: coderabbit auth login)" \
		|| echo "    ✗ coderabbit [missing — run: make brew-check]"
	@# fallow — npm global (not brew: needs Node on PATH). Static analyzer for /analyze.
	@if command -v fallow >/dev/null 2>&1; then \
		echo "    · fallow (ok)"; \
	else \
		npm install -g fallow 2>/dev/null || true; \
		command -v fallow >/dev/null 2>&1 && echo "    ✓ fallow installed" || echo "    · fallow (use npx fallow as fallback)"; \
	fi

.PHONY: _setup-caddy
_setup-caddy:
	@echo "  Caddy (local HTTPS reverse proxy)..."
	@# caddy installed via Brewfile (_setup-packages); this step links config + runs the service
	@echo "    ✓ caddy $$(caddy version 2>/dev/null | head -1)"
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/config/Caddyfile" \
		DST="$(BREW_PREFIX)/etc/Caddyfile"
	@# Clean up any root-owned Caddy data left in user Library from earlier failed runs
	@CADDY_LIB="$(HOME)/Library/Application Support/Caddy"; \
	if [ -d "$$CADDY_LIB" ] && [ "$$(stat -f %Su "$$CADDY_LIB" 2>/dev/null)" = "root" ]; then \
		sudo rm -rf "$$CADDY_LIB" && echo "    ✓ removed stale root-owned Caddy data"; \
	fi
	@# Start Caddy as LaunchDaemon (root — required for port 443)
	@# LaunchDaemon plist sets HOME=/opt/homebrew/var/lib so CA lands there
	@sudo brew services restart caddy >/dev/null 2>&1 \
		&& echo "    ✓ caddy service" \
		|| $(MAKE) --no-print-directory _daemon-running-or-fail \
			SERVICE=caddy NAME="caddy service" \
			HINT="sudo brew services restart caddy"
	@# Trust Caddy local CA — caddy trust handles keychain install + NSS
	@if security dump-trust-settings -d 2>/dev/null | grep -q "Caddy"; then \
		echo "    · Caddy CA trusted (ok)"; \
	else \
		sudo caddy trust \
			&& echo "    ✓ Caddy CA trusted" \
			|| echo "    ✗ CA trust failed — re-run: sudo caddy trust"; \
	fi
	@echo "  dnsmasq (wildcard *.test → 127.0.0.1)..."
	@# dnsmasq installed via Brewfile (_setup-packages); this step configures + runs it
	@echo "    ✓ dnsmasq present"
	@# Add wildcard entry (idempotent)
	@if grep -q "address=/.test/127.0.0.1" "$(BREW_PREFIX)/etc/dnsmasq.conf" 2>/dev/null; then \
		echo "    · *.test wildcard (ok)"; \
	else \
		echo "address=/.test/127.0.0.1" >> "$(BREW_PREFIX)/etc/dnsmasq.conf"; \
		echo "    ✓ *.test wildcard added to dnsmasq.conf"; \
	fi
	@# Register *.test resolver with macOS (one-time sudo)
	@if [ -f "/etc/resolver/test" ]; then \
		echo "    · /etc/resolver/test (ok)"; \
	else \
		sudo mkdir -p /etc/resolver && printf "nameserver 127.0.0.1\n" | sudo tee /etc/resolver/test >/dev/null; \
		echo "    ✓ /etc/resolver/test created"; \
	fi
	@sudo brew services restart dnsmasq >/dev/null 2>&1 \
		&& echo "    ✓ dnsmasq service" \
		|| $(MAKE) --no-print-directory _daemon-running-or-fail \
			SERVICE=dnsmasq NAME="dnsmasq service" \
			HINT="sudo brew services restart dnsmasq"
	@# sleepwatcher (from Brewfile) fires wakeup.sh on sleep wake → caddy reload
	@brew services start sleepwatcher >/dev/null 2>&1 || brew services restart sleepwatcher >/dev/null 2>&1 || true
	@echo "    ✓ sleepwatcher service"
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/scripts/wakeup.sh" \
		DST="$(HOME)/.wakeup"
	@chmod +x $(DOTFILES_DIR)/scripts/wakeup.sh

.PHONY: _setup-pnpm
_setup-pnpm:
	@echo "  pnpm..."
	@if command -v pnpm >/dev/null 2>&1; then \
		echo "    · pnpm $$(pnpm --version) (ok)"; \
	else \
		echo "    Installing pnpm..."; \
		curl -fsSL https://get.pnpm.io/install.sh | sh -; \
		echo "    ✓ pnpm installed"; \
	fi

.PHONY: _setup-op-token
# Biometric sign-in has no meaning on the cache backend: `op` is not signed in
# there and the fallback below (`op vault list`) blocks forever on a Touch ID
# prompt no human can answer — the one unattended hang in `make setup`. Secrets
# on that machine come from the offline cache via secrets-run, so skip outright.
_setup-op-token:
	@if [ "$$(tr -d '[:space:]' < "$(HOME)/.config/secrets/backend" 2>/dev/null || true)" = "cache" ]; then \
		echo "  1Password CLI: skipped (cache backend — secrets resolve offline via secrets-run)"; \
	else \
		$(MAKE) --no-print-directory _setup-op-token-live; \
	fi

.PHONY: _setup-op-token-live
_setup-op-token-live:
	@echo "  1Password CLI (personal account: tkrumm)..."
	@if [ ! -S "$$HOME/.config/op/op-daemon.sock" ]; then \
		echo "    ✗ op daemon socket missing — is 1Password app running?"; \
		echo "      Start 1Password, then re-run: make setup"; \
		exit 1; \
	fi
	@echo "    · op-daemon.sock (ok)"
	@if bash $(DOTFILES_DIR)/scripts/lib/op-signed-in.sh tkrumm; then \
		echo "    · op session (ok, $$(op account get --account tkrumm --format=json 2>/dev/null | jq -r '.email // .name // "unknown"'))"; \
	else \
		echo "    Triggering Touch ID sign-in for tkrumm..."; \
		op vault list --account tkrumm >/dev/null 2>&1 || true; \
		if bash $(DOTFILES_DIR)/scripts/lib/op-signed-in.sh tkrumm; then \
			echo "    ✓ op session established"; \
		else \
			echo "    ✗ op sign-in failed — unlock the 1Password desktop app, then re-run"; \
		fi; \
	fi
	@echo "    · ANTHROPIC_API_KEY not exported (Claude Code uses subscription)"
	@#
	@# [SERVICE ACCOUNT — disabled]
	@# TOKEN=$$(security find-generic-password -a "$$USER" -s "op-service-account-token" -w 2>/dev/null); \
	@# KEY=$$(OP_SERVICE_ACCOUNT_TOKEN="$$TOKEN" op read "op://CLI/Anthropic/credential" 2>/dev/null); \
	@# security add-generic-password -U -a "$$USER" -s "anthropic-api-key" -w "$$KEY" -T /usr/bin/security

.PHONY: _setup-secrets
_setup-secrets:
	@echo "  Secrets (headless SOPS+age cache — tooling only, see $(SECRETS_PRIVATE_REPO))..."
	@mkdir -p "$(HOME)/.local/bin"
	@chmod +x $(DOTFILES_DIR)/scripts/secrets-run
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/scripts/secrets-run" \
		DST="$(HOME)/.local/bin/secrets-run"
	@mkdir -p "$(HOME)/.config/secrets"
	@if [ -f "$(HOME)/.config/secrets/backend" ]; then \
		echo "    · backend marker (ok, $$(cat $(HOME)/.config/secrets/backend))"; \
	else \
		echo "op" > "$(HOME)/.config/secrets/backend"; \
		echo "    ✓ backend marker written (default: op — run 'make secrets-backend-cache' on the mini)"; \
	fi
	@if command -v varlock >/dev/null 2>&1; then \
		varlock telemetry disable >/dev/null 2>&1 || true; \
		echo "    · varlock present (used only as the dotfiles-private pre-commit scan gate)"; \
	else \
		echo "    · varlock not installed (optional — only the pre-commit scan uses it)"; \
	fi

.PHONY: _setup-sdk-keys
_setup-sdk-keys:
	@echo "  API keys (1Password → Keychain cache)..."
	@if security find-generic-password -s claude-sdk-api-key -w >/dev/null 2>&1; then \
		echo "    · CLAUDE_SDK_API_KEY (ok)"; \
	else \
		KEY=$$(OP_ACCOUNT=tkrumm $(DOTFILES_DIR)/scripts/secrets-run read "op://common/anthropic/API_KEY" 2>/dev/null || echo ""); \
		if [ -n "$$KEY" ]; then \
			security add-generic-password -a "$$USER" -s claude-sdk-api-key -w "$$KEY" -T /usr/bin/security; \
			echo "    ✓ CLAUDE_SDK_API_KEY cached in Keychain"; \
		else \
			echo "    ✗ Could not read op://common/anthropic/API_KEY — skipping"; \
		fi; \
	fi
	@if security find-generic-password -s claude-sdk-base-url -w >/dev/null 2>&1; then \
		echo "    · CLAUDE_SDK_BASE_URL (ok)"; \
	else \
		URL=$$(OP_ACCOUNT=tkrumm $(DOTFILES_DIR)/scripts/secrets-run read "op://common/anthropic/BASE_URL" 2>/dev/null || echo ""); \
		if [ -n "$$URL" ]; then \
			security add-generic-password -a "$$USER" -s claude-sdk-base-url -w "$$URL" -T /usr/bin/security; \
			echo "    ✓ CLAUDE_SDK_BASE_URL cached in Keychain"; \
		else \
			echo "    ✗ Could not read op://common/anthropic/BASE_URL — skipping"; \
		fi; \
	fi

.PHONY: _setup-ssh
_setup-ssh:
	@echo "  SSH config (~/.ssh/config)..."
	@mkdir -p "$(HOME)/.ssh"
	@chmod 700 "$(HOME)/.ssh"
	@# ControlMaster socket dir (ssh will not create it; connections fail without it).
	@mkdir -p "$(HOME)/.ssh/cm"
	@chmod 700 "$(HOME)/.ssh/cm"
	@# No rendering and no secrets: every Host is a MagicDNS short name, so this
	@# is a plain install that works identically headless. (Not a symlink —
	@# colima appends its Include to this file and must not write into the repo.)
	@install -m 600 "$(DOTFILES_DIR)/config/ssh_config" "$(HOME)/.ssh/config"
	@echo "    ✓ ~/.ssh/config written (mini, iumac, homelab, vps — all MagicDNS)"
	@# colima injects its own Include into ~/.ssh/config on `colima start`; the
	@# render above would drop it (docker-over-ssh then breaks until next start).
	@if [ -f "$(HOME)/.colima/ssh_config" ] && ! grep -q '\.colima/ssh_config' "$(HOME)/.ssh/config" 2>/dev/null; then \
		printf '\nInclude %s/.colima/ssh_config\n' "$(HOME)" >> "$(HOME)/.ssh/config"; \
		echo "    ✓ colima Include re-appended"; \
	fi

.PHONY: _setup-karabiner
_setup-karabiner:
	@echo "  Karabiner-Elements (Caps Lock -> Hyper)..."
	@if [ ! -d /Applications/Karabiner-Elements.app ]; then \
		echo "    - not installed, skipping (Brewfile installs it; the pkg needs sudo)"; \
	else \
		mkdir -p "$(HOME)/.config/karabiner"; \
		if [ ! -f "$(HOME)/.config/karabiner/karabiner.json" ]; then \
			install -m 600 "$(DOTFILES_DIR)/config/karabiner/karabiner.json" "$(HOME)/.config/karabiner/karabiner.json"; \
			echo "    ✓ karabiner.json installed"; \
		elif cmp -s "$(DOTFILES_DIR)/config/karabiner/karabiner.json" "$(HOME)/.config/karabiner/karabiner.json"; then \
			echo "    ✓ karabiner.json matches the repo"; \
		else \
			echo "    ! karabiner.json differs from the repo — NOT overwritten."; \
			echo "      Karabiner rewrites this file on every UI change, so the live copy"; \
			echo "      is authoritative until you decide otherwise. Compare, then pick one:"; \
			echo "        diff $(DOTFILES_DIR)/config/karabiner/karabiner.json $(HOME)/.config/karabiner/karabiner.json"; \
			echo "        cp $(HOME)/.config/karabiner/karabiner.json $(DOTFILES_DIR)/config/karabiner/  # adopt live"; \
			echo "        cp $(DOTFILES_DIR)/config/karabiner/karabiner.json $(HOME)/.config/karabiner/  # adopt repo"; \
		fi; \
	fi

.PHONY: authorized-keys remote-access _setup-remote-access
# Installs trusted public keys into ~/.ssh/authorized_keys (append-if-missing;
# never clobbers or duplicates an existing entry). Deliberately NOT sudo and
# touches nothing else — no sshd config, no Screen Sharing toggle — so it is
# safe to run standalone on a machine that only needs a key, where the rest of
# `remote-access`'s sudo/sharing side effects are unwanted. `remote-access`
# below calls this instead of duplicating the install logic.
#
# TWO FILES, HOST-SCOPED. config/ssh/authorized_keys installs everywhere,
# always. config/ssh/authorized_keys.iumac — the mini's OUTBOUND key into the
# MacBook — installs only on a present-human machine (backend marker != cache,
# the same "am I the mini" discriminator git-headless/opbackup-setup already
# use). That key must never land in the mini's OWN authorized_keys: the mini
# holds the matching private key on disk, so installing the public half there
# too would let it authenticate to itself, turning an outbound-only credential
# into a standing inbound one on the machine most likely to be compromised
# first (see config/ssh/authorized_keys.iumac's header and
# dotfiles-private/docs/access-model.md).
#
# The grep matches a bare `ssh-...` line OR an authorized_keys OPTIONS-prefixed
# line (`restrict,pty ssh-ed25519 ...`, `command=... ssh-ed25519 ...`,
# `no-agent-forwarding ssh-ed25519 ...`, `from="..." ssh-ed25519 ...`) — a plain
# `^ssh-` anchor silently dropped any key carrying options, which is exactly the
# shape the mini->iumac key needs (`restrict,pty`).
authorized-keys:
	@mkdir -p "$(HOME)/.ssh"; chmod 700 "$(HOME)/.ssh"
	@touch "$(HOME)/.ssh/authorized_keys"; chmod 600 "$(HOME)/.ssh/authorized_keys"
	@grep -E '^(ssh-|restrict|command=|no-|from=)' "$(DOTFILES_DIR)/config/ssh/authorized_keys" | while IFS= read -r key; do \
		grep -qF "$$key" "$(HOME)/.ssh/authorized_keys" 2>/dev/null || printf '%s\n' "$$key" >> "$(HOME)/.ssh/authorized_keys"; \
	done
	@BACKEND=$$(tr -d '[:space:]' < "$(HOME)/.config/secrets/backend" 2>/dev/null || echo ""); \
	if [ "$$BACKEND" = "cache" ]; then \
		echo "    · authorized_keys.iumac skipped — this is the mini (backend=cache); that key is the mini's own OUTBOUND credential and must never also be an inbound one here"; \
	else \
		grep -E '^(ssh-|restrict|command=|no-|from=)' "$(DOTFILES_DIR)/config/ssh/authorized_keys.iumac" | while IFS= read -r key; do \
			grep -qF "$$key" "$(HOME)/.ssh/authorized_keys" 2>/dev/null || printf '%s\n' "$$key" >> "$(HOME)/.ssh/authorized_keys"; \
		done; \
	fi
	@echo "    ✓ authorized_keys ($$(grep -cE '^(ssh-|restrict|command=|no-|from=)' "$(HOME)/.ssh/authorized_keys" 2>/dev/null) trusted key(s))"

# Opt-in per machine — NOT in the default `setup` chain, because enabling an SSH
# server is a deliberate per-host decision. Run `make remote-access` on a Mac you
# want to control remotely (over Tailscale): installs trusted keys + key-only
# sshd hardening; the Remote Login / Screen Sharing toggles are best-effort
# (TCC/SIP usually require System Settings) and reachability is Tailscale-only.
remote-access: _setup-remote-access
_setup-remote-access:
	@echo "  Remote access (SSH + Screen Sharing over Tailscale)..."
	@$(MAKE) --no-print-directory authorized-keys
	@# Key-only sshd hardening — only with at least one trusted key (avoid lockout).
	@if ! grep -qE '^(ssh-|restrict|command=|no-|from=)' "$(HOME)/.ssh/authorized_keys" 2>/dev/null; then \
		echo "    ! sshd hardening skipped — no trusted keys (would lock out SSH)"; \
	else \
		DROPIN=/etc/ssh/sshd_config.d/200-hardening.conf; \
		TMP=$$(mktemp); sed "s/__SSH_USER__/$$(id -un)/" \
			"$(DOTFILES_DIR)/config/sshd/200-hardening.conf.template" > "$$TMP"; \
		if sudo cmp -s "$$TMP" "$$DROPIN" 2>/dev/null; then \
			echo "    · sshd hardening drop-in (ok)"; \
		else \
			sudo cp "$$TMP" "$$DROPIN" && sudo chown root:wheel "$$DROPIN" && sudo chmod 644 "$$DROPIN" \
				&& echo "    ✓ sshd hardening installed (key-only, AllowUsers $$(id -un))" \
				|| echo "    ✗ sshd hardening failed"; \
		fi; \
		rm -f "$$TMP"; \
	fi
	@# Toggles: TCC/SIP usually block enabling these from a CLI — best-effort, else manual.
	@sudo launchctl enable system/com.apple.screensharing >/dev/null 2>&1 || true
	@sudo systemsetup -setremotelogin on >/dev/null 2>&1 || true
	@echo "    ↳ Verify: System Settings → General → Sharing → Remote Login ON, Screen"
	@echo "      Sharing ON, 'Allow access for' = your user only, VNC password OFF."
	@echo "    ↳ Reachable only via Tailscale (tag:mac ACL). Ensure NO router WAN"
	@echo "      port-forward exists for 22/5900."

.PHONY: tailnet-sshd-setup tailnet-sshd-status tailnet-sshd-teardown
# Userland sshd on the tailnet interface (:2222) that BYPASSES the MDM-managed
# macOS Remote Login SACL. IT pins com.apple.access_ssh to `IT-Admin` and
# re-drops johannes.krumm on every MDM check-in, so the mini's inbound ssh into
# iumac (:22) authenticates the key then closes the session with no log line.
# Apple's sshd enforces the SACL via pam_sacl.so under `UsePAM yes`; this one
# runs `UsePAM no`, pubkey-only, as the login user in the GUI session, so the
# group is never consulted (see tailnet-sshd/sshd_config.template).
#
# Opt-in per host (like remote-access/git-headless/batt-setup), MacBook-only: on
# the mini (backend=cache) there is no such MDM and Tailscale SSH already serves
# inbound. Needs the tcp:2222 grant in dotfiles-private/tailscale-acl.jsonc
# (tag:mac -> tag:mac) pushed, or the connection times out with nothing logged.
tailnet-sshd-setup:
	@BACKEND=$$(tr -d '[:space:]' < "$(HOME)/.config/secrets/backend" 2>/dev/null || echo ""); \
	if [ "$$BACKEND" = "cache" ]; then \
		echo "  tailnet-sshd: backend is 'cache' (the mini) — not applicable, skipping."; exit 0; fi
	@echo "  Userland tailnet sshd (:2222, MDM SACL bypass)..."
	@$(MAKE) --no-print-directory authorized-keys
	@if ! grep -qE '^(ssh-|restrict|command=|no-|from=)' "$(HOME)/.ssh/authorized_keys" 2>/dev/null; then \
		echo "    ! aborted — no trusted keys in ~/.ssh/authorized_keys (nothing could connect)"; exit 1; fi
	@chmod 700 "$(HOME)/.ssh" 2>/dev/null || true
	@mkdir -p "$(LAUNCHAGENTS)"
	@$(MAKE) --no-print-directory _render-plists PLISTS="com.jkrumm.tailnet-sshd" PLIST_DIR="$(DOTFILES_DIR)/tailnet-sshd"
	@sleep 2
	@$(MAKE) --no-print-directory tailnet-sshd-status
	@echo "    ↳ ACL: ensure tcp:2222 is in the tag:mac->tag:mac grant"
	@echo "      (dotfiles-private/tailscale-acl.jsonc → make tailscale-acl-push)"
	@echo "    ↳ From the mini: ssh -p 2222 iumac (config/ssh_config pins Port 2222)"
tailnet-sshd-status:
	@if netstat -an 2>/dev/null | grep -q '127.0.0.1\.2222 .*LISTEN'; then \
		echo "    ✓ sshd listening on 127.0.0.1:2222 (loopback — invisible to corp LAN)"; \
	else \
		echo "    ✗ sshd NOT on 127.0.0.1:2222 — see ~/Library/Logs/tailnet-sshd.err"; \
	fi
	@if /Applications/Tailscale.app/Contents/MacOS/Tailscale serve status 2>/dev/null | grep -q '127.0.0.1:2222'; then \
		echo "    ✓ tailnet door: serve tcp:2222 -> 127.0.0.1:2222 (ACL tag:mac->tag:mac)"; \
	else \
		echo "    ✗ tailnet door missing — 'tailscale serve --bg --tcp 2222 tcp://127.0.0.1:2222'"; \
	fi
tailnet-sshd-teardown:
	@DST="$(LAUNCHAGENTS)/com.jkrumm.tailnet-sshd.plist"; \
	launchctl unload "$$DST" 2>/dev/null || true; \
	rm -f "$$DST" && echo "  ✓ tailnet-sshd agent unloaded + removed" || true
	@/Applications/Tailscale.app/Contents/MacOS/Tailscale serve --tcp 2222 off 2>/dev/null \
		&& echo "  ✓ serve door tcp:2222 removed" || echo "  · no serve door to remove"
	@echo "  · host key + rendered config kept in ~/.config/tailnet-sshd (rm -rf to purge)"

.PHONY: git-headless _setup-git-headless
# Headless GitHub *and GitLab* pushes for the Mac mini — opt-in, NOT in the
# default `setup` chain (mirrors remote-access/batt-setup: a deliberate per-host
# call). The mini can't use the 1Password SSH agent (the biometric prompt hangs
# with no human), so git talks to both forges over HTTPS: this writes
# ~/.gitconfig-headless (machine-local, never symlinked) rewriting git@<forge>:
# remotes to https://<forge>/ and pointing the credential helper at the secrets
# cache. config/gitconfig includes it unconditionally (a no-op wherever the file
# doesn't exist, i.e. every MacBook). homelab/VPS need nothing — Tailscale SSH
# is keyless and headless-safe already. Self-gates on the cache backend.
#
# GitLab was added 2026-08-04. It is the SAME failure as GitHub's, found the same
# way: every ~/IuRoot repo has a git@gitlab.com: remote, so `git fetch` on the
# mini died with `sign_and_send_pubkey: signing failed ... Permission denied
# (publickey)` — an SSH-shaped error whose actual cause is that the 1Password
# agent cannot serve a headless host. The fallback people reach for first,
# op://Private/feuer/gitlab-token, is a dead end twice over: it is seeded under
# the `careerpartner` account (so a bare `secrets-run read` reports "ref not in
# cache" against `tkrumm` and looks absent rather than misrouted), and the cached
# copy was expired anyway — `GET /api/v4/user` → 401 invalid_token. Hence a
# dedicated op://mini/gitlab/TOKEN in the same vault as the GitHub one, on the
# same rotation path (`make secrets-seed`).
#
# GitLab is a WARNING, not a hard failure: a missing GitLab token must not cost
# the mini its GitHub push path. That is safe to soften precisely because the
# seed fails closed on an unresolvable ref, so a genuinely missing 1P item breaks
# `make secrets-seed` loudly long before this probe would have.
#
# Credentials come from `secrets-run` (op://mini/github/token, declared in
# headless.refs), NOT the `gh` keyring. The keyring was the original design and
# failed in the worst way on 2026-07-26: the token expired, `gh auth
# git-credential get` returned 0 with an empty body, and git reported
# `could not read Username for 'https://github.com'` — which reads as a
# transport fault and cost a whole misdirected diagnosis. The cache has no
# session dependency (no keychain, no GUI login, no forwarded agent), so it
# resolves identically from a LaunchAgent, a `claude --bg` daemon that outlived
# its ssh connection, and an interactive shell. See
# scripts/git-credential-secrets-cache.
git-headless: _setup-git-headless
_setup-git-headless:
	@BACKEND=$$(tr -d '[:space:]' < "$(HOME)/.config/secrets/backend" 2>/dev/null || echo ""); \
	if [ "$$BACKEND" != "cache" ]; then \
		echo "  git-headless: backend is not 'cache' (present-human machine) — skipping."; \
		exit 0; \
	fi; \
	echo "  Headless GitHub + GitLab access (Mac mini only)..."; \
	HELPER="$(HOME)/.local/bin/git-credential-secrets-cache"; \
	GITLAB_REF="op://mini/gitlab/TOKEN"; \
	GITLAB_USER="oauth2"; \
	$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/scripts/git-credential-secrets-cache" \
		DST="$$HELPER"; \
	chmod +x "$(DOTFILES_DIR)/scripts/git-credential-secrets-cache"; \
	if ! printf 'protocol=https\nhost=github.com\n\n' | "$$HELPER" get 2>/dev/null | grep -q '^password=.'; then \
		echo "    ✗ helper cannot resolve op://mini/github/token from the cache."; \
		echo "      fix: ask-human.sh ask 'reseal the secrets cache' --cmd 'make secrets-seed' --wait"; \
		echo "      (async, survives this session), or run 'make secrets-seed' directly if the"; \
		echo "      MacBook is at hand right now (biometric). Then retry."; \
		exit 1; \
	fi; \
	echo "    ✓ credential helper resolves a GitHub token from the cache"; \
	GITCFG="$(HOME)/.gitconfig-headless"; \
	printf '[url "https://github.com/"]\n\tinsteadOf = git@github.com:\n\n[credential "https://github.com"]\n\thelper = \n\thelper = %s\n' "$$HELPER" > "$$GITCFG"; \
	if printf 'protocol=https\nhost=gitlab.com\n\n' \
		| GIT_CREDENTIAL_SECRETS_REF="$$GITLAB_REF" GIT_CREDENTIAL_SECRETS_USER="$$GITLAB_USER" "$$HELPER" get 2>/dev/null \
		| grep -q '^password=.'; then \
		printf '\n[url "https://gitlab.com/"]\n\tinsteadOf = git@gitlab.com:\n\n[credential "https://gitlab.com"]\n\thelper = \n\thelper = !GIT_CREDENTIAL_SECRETS_REF=%s GIT_CREDENTIAL_SECRETS_USER=%s %s\n' \
			"$$GITLAB_REF" "$$GITLAB_USER" "$$HELPER" >> "$$GITCFG"; \
		echo "    ✓ credential helper resolves a GitLab token from the cache"; \
	else \
		echo "    ! helper cannot resolve $$GITLAB_REF — GitLab stanza NOT written."; \
		echo "      GitHub still works. To fix: ensure the 1P item exists, that"; \
		echo "      $$GITLAB_REF is listed in dotfiles-private/headless.refs, then"; \
		echo "      ask-human.sh ask 'reseal the secrets cache' --cmd 'make secrets-seed' --wait"; \
		echo "      (async), or run 'make secrets-seed' from the MacBook directly if present"; \
		echo "      (biometric), and retry."; \
	fi; \
	echo "    ✓ ~/.gitconfig-headless written — forges over HTTPS via the secrets cache"

.PHONY: doctor
doctor: ## Read-only health of this machine (+ the mini when run from the MacBook)
	@bash $(DOTFILES_DIR)/scripts/doctor.sh

.PHONY: agent-dispatch-smoke
agent-dispatch-smoke: ## Dispatch a trivial read-only task at dispatch-scratch and assert it returns
	@bash $(DOTFILES_DIR)/scripts/agent-dispatch.sh bg dispatch-scratch 'List the files in this directory and stop. Read-only; do not edit anything.'

.PHONY: caddy-tailnet
# Expose dev servers over the tailnet via Caddy. Runs ON the dev host (the mini).
# Opt-in per machine and NOT in the default `setup` chain — only one machine is
# the dev host, and the generated include names that machine's MagicDNS name and
# Tailscale IP, which is why it stays untracked and machine-local.
#
# The app list is the tracked config/Caddyfile: every `<name>.test` block gets a
# clean https://<name>.$DEV_DOMAIN door automatically. ~/.config/caddy-tailnet.ports
# is opt-OUT only (exclude), not a second list.
caddy-tailnet:
	@bash $(DOTFILES_DIR)/scripts/caddy-tailnet.sh

.PHONY: caddy-dns-build
# Build Caddy with the Cloudflare DNS module and install it over Homebrew's
# binary. Stock Homebrew Caddy ships ZERO DNS provider modules
# (`caddy list-modules | grep dns.providers` is empty), so DNS-01 — which the
# clean https://<app>.$DEV_DOMAIN door in scripts/caddy-tailnet.sh needs for
# its wildcard cert — is impossible with the stock binary. xcaddy is not in
# Homebrew, so it's installed straight from source via `go install`, pinned
# above like COLLIE_REF.
#
# Dev-host only, same gate `collie-setup` uses: the mini is the only machine
# that runs the tailnet Caddyfile include this unlocks.
#
# Deliberately targets the SAME Caddy version already installed (read live
# from `caddy version`) — this is a module addition, not a silent upgrade.
#
# THE TRAP, and the whole reason devhost-health-check.sh asserts the module
# is present on every run: a later `brew upgrade caddy` silently REVERTS this
# binary back to the stock one. The module just vanishes — nothing errors —
# until the wildcard cert fails to renew ~60 days out. Re-running this target
# is the fix after any caddy upgrade.
#
# The whole recipe is ONE continued shell line, deliberately. `exit 0` in a
# make recipe ends only that line's shell — make happily runs the next one — so
# a dev-host gate written as its own line does not actually gate anything.
# (collie-setup has that shape and that latent bug; not fixed here, but do not
# copy it.) Chaining everything after the gate with `; \` is what makes the
# skip real, which matters more here than for collie: the tail of this target
# is a Go toolchain install, a multi-minute compile, and three sudo calls.
#
# Related, and the reason the restart failure is spelled out inline instead of
# delegating to _daemon-running-or-fail: make EXECUTES any recipe line
# containing `$(MAKE)` even under `make -n`. With the whole target on one line,
# a `make -n caddy-dns-build` "dry run" would compile and sudo-install for
# real. Keep `$(MAKE)` out of this recipe.
#
# Sudo is primed INSIDE the recipe, first thing, and that placement is load-
# bearing in two ways. Priming it outside — the documented
# `op read … | ssh mini "sudo -S -v && make …"` shape — does NOT work here:
# with no TTY, sudo's credential timestamp is scoped to the parent PID, and
# make's recipe shell is a different process than the shell that ran `sudo -v`.
# The later `sudo cp` / `sudo install` then find no cached credential, have no
# TTY to prompt on, and fail — AFTER a four-minute compile has already run.
# Hence: prime here (all sudo calls in this recipe share one parent shell,
# because the whole recipe is one line), and prime BEFORE the build so a
# missing credential costs a second rather than a compile. `[ -t 0 ]` picks
# between an interactive prompt (`ssh -t`) and reading the password from a
# pipe, so both invocation styles work.
caddy-dns-build:
	@BACKEND=$$(tr -d '[:space:]' < "$(HOME)/.config/secrets/backend" 2>/dev/null || echo ""); \
	if [ "$$BACKEND" != "cache" ]; then \
		echo "    · not the dev host (backend=$${BACKEND:-unset}) — caddy-dns-build skipped"; \
		exit 0; \
	fi; \
	command -v go >/dev/null 2>&1 || { echo "  ✗ go not installed — run: brew bundle install"; exit 1; }; \
	command -v caddy >/dev/null 2>&1 || { echo "  ✗ caddy not installed — run: brew bundle install"; exit 1; }; \
	if [ -t 0 ]; then sudo -v; else sudo -S -v 2>/dev/null; fi \
		|| { echo "  ✗ sudo required. Either:"; \
		     echo "      ssh -t mini 'cd ~/SourceRoot/dotfiles && make caddy-dns-build'   # type the password"; \
		     echo "      op read \"op://Private/mac-mini-server/password\" --account tkrumm | ssh mini 'cd ~/SourceRoot/dotfiles && make caddy-dns-build'"; \
		     exit 1; }; \
	CADDY_BIN="$(BREW_PREFIX)/opt/caddy/bin/caddy"; \
	CADDY_VER=$$(caddy version 2>/dev/null | awk '{print $$1}'); \
	[ -n "$$CADDY_VER" ] || { echo "  ✗ could not read 'caddy version'"; exit 1; }; \
	GOBIN_DIR=$$(go env GOPATH)/bin; \
	XCADDY="$$GOBIN_DIR/xcaddy"; \
	if [ -x "$$XCADDY" ] && [ "$$("$$XCADDY" version 2>/dev/null | awk '{print $$1}')" = "$(XCADDY_VERSION)" ]; then \
		echo "    ✓ xcaddy $(XCADDY_VERSION) installed"; \
	else \
		echo "    → installing xcaddy $(XCADDY_VERSION) into $$GOBIN_DIR"; \
		go install github.com/caddyserver/xcaddy/cmd/xcaddy@$(XCADDY_VERSION) \
			&& echo "    ✓ xcaddy $(XCADDY_VERSION) installed" \
			|| { echo "  ✗ go install xcaddy failed"; exit 1; }; \
	fi; \
	echo "    → building caddy $$CADDY_VER + $(CADDY_DNS_MODULE)@$(CADDY_DNS_MODULE_VERSION) (this takes a minute)"; \
	TMP_BIN=$$(mktemp -t caddy-xcaddy); \
	"$$XCADDY" build "$$CADDY_VER" \
		--with $(CADDY_DNS_MODULE)@$(CADDY_DNS_MODULE_VERSION) \
		--output "$$TMP_BIN" \
		|| { echo "  ✗ xcaddy build failed"; rm -f "$$TMP_BIN"; exit 1; }; \
	"$$TMP_BIN" list-modules 2>/dev/null | grep -q dns.providers.cloudflare \
		|| { echo "  ✗ built binary is missing dns.providers.cloudflare — refusing to install it"; rm -f "$$TMP_BIN"; exit 1; }; \
	BUILT_VER=$$("$$TMP_BIN" version 2>/dev/null | awk '{print $$1}'); \
	[ "$$BUILT_VER" = "$$CADDY_VER" ] \
		|| { echo "  ✗ built $$BUILT_VER, expected $$CADDY_VER — refusing to install a version mismatch"; rm -f "$$TMP_BIN"; exit 1; }; \
	BACKUP="$$CADDY_BIN.orig-brew"; \
	if [ ! -f "$$BACKUP" ]; then \
		sudo cp -p "$$CADDY_BIN" "$$BACKUP" && echo "    ✓ backed up stock binary → $$BACKUP"; \
	else \
		echo "    · stock backup already exists at $$BACKUP"; \
	fi; \
	sudo install -m 555 -o root -g admin "$$TMP_BIN" "$$CADDY_BIN" \
		&& echo "    ✓ installed custom caddy over $$CADDY_BIN" \
		|| { echo "  ✗ install failed"; rm -f "$$TMP_BIN"; exit 1; }; \
	rm -f "$$TMP_BIN"; \
	caddy list-modules 2>/dev/null | grep -q dns.providers.cloudflare \
		&& echo "    ✓ dns.providers.cloudflare present" \
		|| { echo "  ✗ live 'caddy' still missing dns.providers.cloudflare after install"; exit 1; }; \
	LIVE_VER=$$(caddy version 2>/dev/null | awk '{print $$1}'); \
	[ "$$LIVE_VER" = "$$CADDY_VER" ] \
		&& echo "    ✓ caddy version unchanged ($$LIVE_VER)" \
		|| { echo "  ✗ caddy version changed: $$CADDY_VER → $$LIVE_VER"; exit 1; }; \
	sudo brew services restart caddy >/dev/null 2>&1 \
		&& echo "    ✓ caddy service restarted with the new binary" \
		|| { echo "  ✗ caddy service restart failed — the new binary is installed but the running process is still the old one. Fix: sudo brew services restart caddy"; exit 1; }

.PHONY: batt-setup batt-limit batt-status
# MacBook-only battery charge limiter (https://github.com/charlie0129/batt).
# The binary ships via the Brewfile (harmless on a battery-less Mac like the
# mini); the root LaunchDaemon + charge cap are opt-in per machine and gated
# below on the machine actually having an internal battery. The daemon runs with
# --always-allow-non-root-access, so `batt limit` needs no sudo after setup.
# Default cap 80% (long-term battery health); LIMIT=100 lifts it for a full
# charge (e.g. before travel): `make batt-limit LIMIT=100`. Add DAYS=N to also
# pause the daily 09:00 reset-to-80% for N days (com.jkrumm.batt-reset checks
# ~/.config/batt/pause-until via battery/batt-reset.sh); omit DAYS to clear
# any existing pause, resuming normal daily governance.
# batt is keg-only (not symlinked into bin), so call it via its opt path.
LIMIT ?= 80
DAYS ?=
BATT := $(BREW_PREFIX)/opt/batt/bin/batt
BATT_PAUSE_FILE := $(HOME)/.config/batt/pause-until
batt-setup:
	@if ! pmset -g batt | grep -q InternalBattery; then \
		echo "  batt: no internal battery (not a MacBook) — skipping."; exit 0; fi
	@[ -x "$(BATT)" ] || { echo "  batt missing — run 'make setup' (Brewfile installs it)"; exit 1; }
	@echo "  Battery charge limiter (batt)..."
	@sudo brew services start batt >/dev/null 2>&1 || true
	@sleep 1
	@$(BATT) limit $(LIMIT) >/dev/null 2>&1 \
		&& echo "    ✓ daemon running, charge limit set to $(LIMIT)%" \
		|| echo "    ✗ failed to set limit — check the daemon ($$(brew --prefix)/var/log/batt.log)"
	@# Daily reset agent: any boost (e.g. 100% via Raycast) expires next morning (09:00 → 80%).
	@mkdir -p "$(LAUNCHAGENTS)"
	@$(MAKE) --no-print-directory _render-plists PLISTS="com.jkrumm.batt-reset" PLIST_DIR="$(DOTFILES_DIR)/battery"
	@# Raycast Script Commands: self-authored, no deps. Symlink the dir; Raycast must be pointed at it once.
	@ln -sfn "$(DOTFILES_DIR)/raycast" "$(HOME)/.raycast-scripts" \
		&& echo "    ✓ Raycast scripts → ~/.raycast-scripts (Battery Limit / Battery Status)"
	@echo "    ↳ One-time in Raycast: Settings (⌘,) → Script Commands (own top-level"
	@echo "      tab, not under Extensions) → Add Script Directory → ~/.raycast-scripts"
batt-limit:
	@if ! pmset -g batt | grep -q InternalBattery; then \
		echo "  batt: no internal battery — nothing to do."; exit 0; fi
	@$(BATT) limit $(LIMIT) >/dev/null 2>&1 \
		&& echo "  ✓ charge limit set to $(LIMIT)%" \
		|| { echo "  ✗ daemon not running — run 'make batt-setup' first"; exit 1; }
	@if [ -n "$(DAYS)" ]; then \
		mkdir -p "$$(dirname "$(BATT_PAUSE_FILE)")"; \
		UNTIL=$$(date -v+$(DAYS)d +%s); \
		echo "$$UNTIL" > "$(BATT_PAUSE_FILE)"; \
		echo "  ✓ daily 09:00 auto-reset paused until $$(date -r $$UNTIL '+%a %b %d')"; \
	else \
		rm -f "$(BATT_PAUSE_FILE)"; \
	fi
batt-status:
	@$(BATT) status 2>/dev/null || echo "  batt daemon not running — run 'make batt-setup'"
	@if [ -f "$(BATT_PAUSE_FILE)" ]; then \
		UNTIL=$$(cat "$(BATT_PAUSE_FILE)"); \
		if [ -n "$$UNTIL" ] && [ "$$(date +%s)" -lt "$$UNTIL" ]; then \
			echo "  ⏸ auto-reset paused until $$(date -r $$UNTIL '+%a %b %d, %H:%M')"; \
		fi; \
	fi

# ~/SourceRoot/brain continuous sync through GitHub, every 5 minutes, on BOTH
# machines. The script picks its role off the secrets-backend marker: `cache`
# (mini) = source, pull + push only, never commits; `op` (MacBook) = mirror,
# pull + commit + push. GitHub is the hub and this agent is the only thing that
# pushes to it — obsidian-git is deliberately not installed, since a plugin
# committing on its own timer beside this one is two committers racing for
# .git/index.lock. Self-guards on a missing vault.
.PHONY: brain-sync-setup brain-sync-teardown
brain-sync-setup:
	@if [ ! -d "$(HOME)/SourceRoot/brain/.git" ]; then \
		echo "  brain-sync: no git vault at ~/SourceRoot/brain — skipping."; exit 0; fi
	@mkdir -p "$(LAUNCHAGENTS)"
	@$(MAKE) --no-print-directory _render-plists PLISTS="com.jkrumm.brain-sync" PLIST_DIR="$(DOTFILES_DIR)/brain"
	@echo "    ↳ every 300s → pull --rebase, push (mirror role also commits); log: ~/Library/Logs/brain-sync.log"
brain-sync-teardown:
	@PLIST="$(LAUNCHAGENTS)/com.jkrumm.brain-sync.plist"; \
	launchctl unload "$$PLIST" 2>/dev/null || true; \
	rm -f "$$PLIST"; \
	echo "  ✓ brain-sync torn down (unloaded + plist removed)"

# The subtraction pass's enforcement half (docs/PRD.md phase 0.4): every launchd
# label loaded on this machine must appear in docs/architecture.md. Read-only,
# exits 1 on findings — a legit new agent gets a map row in the same change.
.PHONY: architecture-check
architecture-check:
	@bash $(DOTFILES_DIR)/scripts/architecture-check.sh

# Persistent loopback forwards into the mini's dev databases, so dbOSK (and the
# mysql CLI, and any script) has a fixed endpoint that is simply always there.
# Declared state + the full "why not tailscale serve / not Caddy" argument:
# dbtunnel/tunnels.conf. MacBook-only in effect — the script no-ops on the mini,
# where these databases are already on loopback.
.PHONY: db-tunnel-setup db-tunnel-status db-tunnel-teardown
db-tunnel-setup:
	@mkdir -p "$(LAUNCHAGENTS)"
	@$(MAKE) --no-print-directory _render-plists PLISTS="com.jkrumm.db-tunnel" PLIST_DIR="$(DOTFILES_DIR)/dbtunnel"
	@awk 'NF && $$1 !~ /^#/ { printf "    ↳ 127.0.0.1:%s → %s:%s (%s)\n", $$1, $$2, $$4, substr($$0, index($$0,$$5)) }' "$(DOTFILES_DIR)/dbtunnel/tunnels.conf"
	@echo "    ↳ log: ~/Library/Logs/db-tunnel.log"
# Read-only, and deliberately probes the LOCAL end rather than asking launchd:
# `launchctl list` reports the job loaded whether or not the forward came up,
# which is the exact failure this target exists to catch.
db-tunnel-status:
	@launchctl list 2>/dev/null | grep -q com.jkrumm.db-tunnel \
		&& echo "  agent: loaded" || echo "  agent: NOT loaded — run 'make db-tunnel-setup'"
	@awk 'NF && $$1 !~ /^#/ { print $$1 }' "$(DOTFILES_DIR)/dbtunnel/tunnels.conf" | while read -r p; do \
		if nc -z -G 2 127.0.0.1 "$$p" 2>/dev/null; then echo "  ✓ 127.0.0.1:$$p open"; \
		else echo "  ✗ 127.0.0.1:$$p CLOSED"; fi; \
	done
db-tunnel-teardown:
	@PLIST="$(LAUNCHAGENTS)/com.jkrumm.db-tunnel.plist"; \
	launchctl unload "$$PLIST" 2>/dev/null || true; \
	rm -f "$$PLIST"; \
	echo "  ✓ db-tunnel torn down (unloaded + plist removed)"

# The nightly (03:30) leftover-dirt sweep on the mini — commits any working tree
# the day's Claude Code sessions left dirty (claude_iu/Haiku writes the commit
# message) and pushes. It is NOT the sync layer: brain-sync above is, on a
# 5-minute interval on both machines. This is the backstop for the one thing
# brain-sync deliberately will not do, which is commit on the mini. Self-guards
# on a missing vault; the script's `git add -A` respects .gitignore, so secrets
# stay out.
.PHONY: brain-backup-setup brain-backup-teardown
brain-backup-setup:
	@if [ ! -d "$(HOME)/SourceRoot/brain/.git" ]; then \
		echo "  brain-backup: no git vault at ~/SourceRoot/brain — skipping."; exit 0; fi
	@mkdir -p "$(LAUNCHAGENTS)"
	@$(MAKE) --no-print-directory _render-plists PLISTS="com.jkrumm.brain-backup" PLIST_DIR="$(DOTFILES_DIR)/brain"
	@echo "    ↳ nightly at 03:30 → commit + push to origin/master; log: ~/Library/Logs/brain-backup.log"
brain-backup-teardown:
	@PLIST="$(LAUNCHAGENTS)/com.jkrumm.brain-backup.plist"; \
	launchctl unload "$$PLIST" 2>/dev/null || true; \
	rm -f "$$PLIST"; \
	echo "  ✓ brain-backup torn down (unloaded + plist removed)"

# Content-refresh for the brain vault reader (~/SourceRoot/basalt-ui-obsidian,
# served as the always-on `brain-web` container on the mini). Downstream of
# brain-sync above: this polls the vault's git HEAD every 5 minutes and only
# rebuilds the reader's static site (`make refresh`) when it moved — it never
# touches the container, since nginx bind-mounts dist/ read-only. Self-guards
# on a missing vault or a missing basalt-ui-obsidian checkout.
.PHONY: brain-web-refresh-setup brain-web-refresh-teardown
brain-web-refresh-setup:
	@if [ ! -d "$(HOME)/SourceRoot/brain/.git" ]; then \
		echo "  brain-web-refresh: no git vault at ~/SourceRoot/brain — skipping."; exit 0; fi
	@if [ ! -d "$(HOME)/SourceRoot/basalt-ui-obsidian" ]; then \
		echo "  brain-web-refresh: no checkout at ~/SourceRoot/basalt-ui-obsidian — skipping."; exit 0; fi
	@mkdir -p "$(LAUNCHAGENTS)"
	@$(MAKE) --no-print-directory _render-plists PLISTS="com.jkrumm.brain-web-refresh" PLIST_DIR="$(DOTFILES_DIR)/brain-web"
	@echo "    ↳ every 300s → rebuild apps/demo/dist when the vault's HEAD moves; log: ~/Library/Logs/brain-web-refresh.log"
brain-web-refresh-teardown:
	@PLIST="$(LAUNCHAGENTS)/com.jkrumm.brain-web-refresh.plist"; \
	launchctl unload "$$PLIST" 2>/dev/null || true; \
	rm -f "$$PLIST"; \
	echo "  ✓ brain-web-refresh torn down (unloaded + plist removed)"

.PHONY: _setup-rules
_setup-rules:
	@echo "  Rules (global → ~/.claude/rules/)..."
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/rules" \
		DST="$(CLAUDE_DIR)/rules"

.PHONY: _setup-agents
_setup-agents:
	@echo "  Agents (global → ~/.claude/agents/)..."
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/agents" \
		DST="$(CLAUDE_DIR)/agents"

.PHONY: _setup-output-styles
_setup-output-styles:
	@echo "  Output styles (global → ~/.claude/output-styles/)..."
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/config/output-styles" \
		DST="$(CLAUDE_DIR)/output-styles"

.PHONY: _setup-hooks
_setup-hooks:
	@echo "  Hooks..."
	@mkdir -p $(CLAUDE_DIR)/hooks
	@# Hooks only — NOT *.test.ts. A bare *.ts glob also chmods the test file,
	@# which is imported by bun and never executed, so every `make setup` left
	@# a stray 100644 -> 100755 mode change in `git status`.
	@find $(DOTFILES_DIR)/hooks -maxdepth 1 -name '*.ts' ! -name '*.test.ts' -exec chmod +x {} +
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/hooks/notify.ts" \
		DST="$(CLAUDE_DIR)/hooks/notify.ts"
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/hooks/protect-branches.ts" \
		DST="$(CLAUDE_DIR)/hooks/protect-branches.ts"
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/hooks/docker-makefile.ts" \
		DST="$(CLAUDE_DIR)/hooks/docker-makefile.ts"
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/hooks/machine-role.ts" \
		DST="$(CLAUDE_DIR)/hooks/machine-role.ts"
	@# Shared PR-required denylist — read by protect-branches.ts, also drives github-config.sh
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/config/pr-required-repos.json" \
		DST="$(CLAUDE_DIR)/pr-required-repos.json"

.PHONY: _setup-scripts
_setup-scripts:
	@echo "  Scripts..."
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/scripts/statusline.sh" \
		DST="$(CLAUDE_DIR)/statusline.sh"
	@chmod +x $(DOTFILES_DIR)/scripts/fetch_usage.py
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/scripts/fetch_usage.py" \
		DST="$(CLAUDE_DIR)/fetch_usage.py"
	@# keyprobe is the ONLY unambiguous test for the Hyper key, and both brain
	@# cards tell you to run it — so it has to exist on every machine, not just
	@# the one where it was first written. ~/.local/bin so it is on PATH for
	@# non-interactive shells too (see _setup-zshenv).
	@mkdir -p "$(HOME)/.local/bin"
	@chmod +x $(DOTFILES_DIR)/scripts/keyprobe.py
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/scripts/keyprobe.py" \
		DST="$(HOME)/.local/bin/keyprobe"
	@chmod +x $(DOTFILES_DIR)/scripts/agent-dispatch.sh
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/scripts/agent-dispatch.sh" \
		DST="$(HOME)/.local/bin/agent-dispatch"

.PHONY: _setup-zshenv
# ~/.zshenv is the ONLY startup file zsh reads for a non-interactive,
# non-login shell — which is exactly what `ssh host -- <cmd>` gets. macOS runs
# path_helper from /etc/zprofile, but that is a LOGIN file, so a bare
# `ssh mini 'herdr …'` lands with PATH=/usr/bin:/bin:/usr/sbin:/sbin and no
# Homebrew at all — silently forcing every remote automation to hand-prefix
# the PATH.
#
# The file is NOT symlinked: third-party installers (cargo, …) append
# to it and would clobber a symlink into the repo. Append an idempotent guarded
# block instead, and prepend rather than append to PATH so brew wins over any
# system binary of the same name — matching what config/zsh/path.zsh already
# does for interactive shells.
_setup-zshenv:
	@echo "  zshenv (non-interactive PATH — ssh remote commands)..."
	@ZSHENV="$(HOME)/.zshenv"; \
	MARKER="# >>> dotfiles: non-interactive PATH >>>"; \
	LEGACY="# >>> dotfiles: homebrew PATH >>>"; \
	if [ -f "$$ZSHENV" ] && grep -qF "$$LEGACY" "$$ZSHENV"; then \
		sed -i '' '/# >>> dotfiles: homebrew PATH >>>/,/# <<< dotfiles: homebrew PATH <<</d' "$$ZSHENV"; \
		echo "    ✓ removed superseded PATH block (homebrew-only)"; \
	fi; \
	if [ -f "$$ZSHENV" ] && grep -qF "$$MARKER" "$$ZSHENV"; then \
		echo "    · ~/.zshenv PATH block (ok)"; \
	else \
		BREW_PREFIX="$$(/usr/bin/env brew --prefix 2>/dev/null || echo /opt/homebrew)"; \
		{ \
			echo ""; \
			echo "$$MARKER"; \
			echo "# Managed by dotfiles (make setup). zsh reads ONLY this file for"; \
			echo "# non-interactive non-login shells — \`ssh host -- cmd\`. Without it"; \
			echo "# that path can't see Homebrew."; \
			echo "case \":\$$PATH:\" in"; \
			echo "  *\":$$BREW_PREFIX/bin:\"*) ;;"; \
			echo "  *) export PATH=\"$$BREW_PREFIX/bin:$$BREW_PREFIX/sbin:\$$PATH\" ;;"; \
			echo "esac"; \
			echo "# ~/.local/bin holds claude, secrets-run and imgcli — none of them"; \
			echo "# Homebrew-managed, all of them needed by remote automation."; \
			echo "case \":\$$PATH:\" in"; \
			echo "  *\":\$$HOME/.local/bin:\"*) ;;"; \
			echo "  *) export PATH=\"\$$HOME/.local/bin:\$$PATH\" ;;"; \
			echo "esac"; \
			echo "# <<< dotfiles: non-interactive PATH <<<"; \
		} >> "$$ZSHENV"; \
		echo "    ✓ ~/.zshenv PATH block appended"; \
	fi
	@ZSHENV="$(HOME)/.zshenv"; \
	MARKER="# >>> dotfiles: claude max auth >>>"; \
	if [ -f "$$ZSHENV" ] && grep -qF "$$MARKER" "$$ZSHENV"; then \
		echo "    · ~/.zshenv claude-auth block (ok)"; \
	else \
		{ \
			echo ""; \
			echo "$$MARKER"; \
			echo "# Managed by dotfiles (make setup). MUST come after the PATH block"; \
			echo "# above — the wrapper calls secrets-run, which lives in ~/.local/bin."; \
			echo "# ~/.zshrc already sources conf.d for interactive shells; this line is"; \
			echo "# what carries the wrapper into \`ssh mini 'claude --bg …'\`, which reads"; \
			echo "# ONLY this file. Sourcing it twice is a no-op (it just defines a"; \
			echo "# function). Self-gates on the 'cache' secrets backend, so a thin"; \
			echo "# client picks up nothing."; \
			echo "[ -r \"\$$HOME/.zsh/conf.d/claude-auth.zsh\" ] && . \"\$$HOME/.zsh/conf.d/claude-auth.zsh\""; \
			echo "# <<< dotfiles: claude max auth <<<"; \
		} >> "$$ZSHENV"; \
		echo "    ✓ ~/.zshenv claude-auth block appended"; \
	fi

.PHONY: _setup-skills
_setup-skills:
	@echo "  Skills (global → ~/.claude/skills/)..."
	@mkdir -p $(CLAUDE_DIR)/skills
	@for skill in $(DOTFILES_DIR)/skills/*/; do \
		name=$$(basename "$$skill"); \
		$(MAKE) --no-print-directory _link SRC="$$skill" DST="$(CLAUDE_DIR)/skills/$$name"; \
	done

.PHONY: _setup-imgcli
_setup-imgcli:
	@echo "  imgcli (→ ~/.local/bin, same PATH lane as secrets-run)..."
	@mkdir -p "$(HOME)/.local/bin"
	@chmod +x $(DOTFILES_DIR)/skills/img/scripts/imgcli
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/skills/img/scripts/imgcli" \
		DST="$(HOME)/.local/bin/imgcli"

.PHONY: _setup-settings
_setup-settings:
	@echo "  Claude Code settings..."
	@if [ ! -f "$(CLAUDE_DIR)/settings.json" ]; then \
		jq 'del(._NOTE)' "$(DOTFILES_DIR)/config/settings.template.json" \
			> "$(CLAUDE_DIR)/settings.json"; \
		echo "    ✓ settings.json created from template"; \
	else \
		jq --slurpfile existing "$(CLAUDE_DIR)/settings.json" \
			'del(._NOTE) * {permissions: (($$existing[0].permissions // .permissions) * {deny: .permissions.deny})} * ($$existing[0] | {model, effortLevel, alwaysThinkingEnabled} | with_entries(select(.value != null)))' \
			"$(DOTFILES_DIR)/config/settings.template.json" \
			> /tmp/claude-settings-merged.json \
		&& mv /tmp/claude-settings-merged.json "$(CLAUDE_DIR)/settings.json"; \
		echo "    ✓ settings.json merged (template applied, allow + model/effort preserved, deny from template)"; \
	fi

.PHONY: _setup-gitignore
_setup-gitignore:
	@echo "  Global gitignore..."
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/config/gitignore_global" \
		DST="$(HOME)/.gitignore_global"
	@git config --global core.excludesfile "~/.gitignore_global"
	@echo "    ✓ git config core.excludesfile"

.PHONY: _setup-ghostty
_setup-ghostty:
	@echo "  Ghostty (One Zinc Dark / One Zinc Light themes)..."
	@mkdir -p $(HOME)/.config/ghostty/themes
	@# Ghostty reads ~/.config/ghostty/config — its own config path, not the
	@# macOS Application Support one an earlier setup used to win precedence
	@# with. If a symlink still points from there into this repo, remove it.
	@_stale="$(HOME)/Library/Application Support/com.mitchellh.ghostty/config"; \
	if [ -L "$$_stale" ] && [ "$$(readlink "$$_stale")" = "$(DOTFILES_DIR)/config/ghostty/config.appsupport" ]; then \
		rm "$$_stale" && echo "    ✓ removed stale config.appsupport symlink"; \
	fi
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/config/ghostty/config" \
		DST="$(HOME)/.config/ghostty/config"
	@# Themes are COPIED, not symlinked — see the _copy helper's own comment.
	@# one-zinc-{dark,light} are the active pair; basalt-ui-{dark,light} stay
	@# installed as the tracked alternative.
	@$(MAKE) --no-print-directory _copy \
		SRC="$(DOTFILES_DIR)/config/ghostty/themes/one-zinc-light" \
		DST="$(HOME)/.config/ghostty/themes/one-zinc-light"
	@$(MAKE) --no-print-directory _copy \
		SRC="$(DOTFILES_DIR)/config/ghostty/themes/one-zinc-dark" \
		DST="$(HOME)/.config/ghostty/themes/one-zinc-dark"
	@$(MAKE) --no-print-directory _copy \
		SRC="$(DOTFILES_DIR)/config/ghostty/themes/basalt-ui-light" \
		DST="$(HOME)/.config/ghostty/themes/basalt-ui-light"
	@$(MAKE) --no-print-directory _copy \
		SRC="$(DOTFILES_DIR)/config/ghostty/themes/basalt-ui-dark" \
		DST="$(HOME)/.config/ghostty/themes/basalt-ui-dark"
	@# Retire superseded theme files an earlier `make setup` installed. Both the
	@# hand-authored one-{dark,light} and the zinc-{dark,light} pair (whose
	@# near-black #09090b background this replaces) are gone as of 2026-07-27.
	@# herdr still uses its BUILT-IN one-dark for chrome — that is herdr's own,
	@# not a file here, so nothing below affects it.
	@for old in ayu-mirage basalt-ui one-dark one-light zinc-dark zinc-light; do \
		if [ -f "$(HOME)/.config/ghostty/themes/$$old" ] && [ ! -L "$(HOME)/.config/ghostty/themes/$$old" ]; then \
			mv "$(HOME)/.config/ghostty/themes/$$old" "$(HOME)/.config/ghostty/themes/$$old.bak"; \
			echo "    ✓ backed up old $$old theme"; \
		fi; \
	done

.PHONY: _setup-browser
_setup-browser:
	@echo "  Chrome DevTools MCP (deferred loading — ~400 tokens overhead)..."
	@claude mcp remove chrome-devtools --scope user 2>/dev/null || true
	@claude mcp add chrome-devtools --scope user -- npx -y chrome-devtools-mcp@latest --isolated --headless --usageStatistics=false
	@echo "    ✓ chrome-devtools MCP registered (use via /browse skill only)"

.PHONY: _setup-sideclaw-mcp
_setup-sideclaw-mcp:
	@echo "  sideclaw MCP..."
	@if [ -f "$(SOURCEROOT)/sideclaw/server/mcp.ts" ]; then \
		claude mcp remove sideclaw --scope user 2>/dev/null || true; \
		claude mcp add sideclaw --scope user -- bun run $(SOURCEROOT)/sideclaw/server/mcp.ts; \
		echo "    ✓ sideclaw MCP registered (check, review, ship tools)"; \
	else \
		echo "    · sideclaw not cloned at $(SOURCEROOT)/sideclaw — skipping"; \
	fi

# research-gateway is a REMOTE HTTP MCP (research.jkrumm.com/mcp) — unlike the
# stdio servers above, it needs a bearer token. The secret never lands in git:
# resolve it from 1Password at provision time and pass it to `claude mcp add`,
# which writes the resolved header into ~/.claude.json (untracked). Re-run after
# rotating op://vps/research-gateway/API_SECRET. Runs after _setup-op-token so op is authed.
.PHONY: _setup-research-gateway-mcp
_setup-research-gateway-mcp:
	@echo "  research-gateway MCP (remote HTTP — bearer via 1Password)..."
	@TOKEN="$$(OP_ACCOUNT=tkrumm $(DOTFILES_DIR)/scripts/secrets-run read op://vps/research-gateway/API_SECRET 2>/dev/null)"; \
	if [ -n "$$TOKEN" ]; then \
		claude mcp remove research-gateway --scope user 2>/dev/null || true; \
		claude mcp add research-gateway --scope user --transport http https://research.jkrumm.com/mcp --header "Authorization: Bearer $$TOKEN"; \
		echo "    ✓ research-gateway MCP registered (research tool)"; \
	else \
		echo "    · could not read op://vps/research-gateway/API_SECRET — skipping (op not authed?)"; \
	fi

# HyperDX/ClickStack is deliberately NOT a registered MCP server. The skill's
# `skills/otel/scripts/hdx.py` speaks the same MCP endpoint over HTTP (tools,
# schema, instructions, prompts, call) and loads only when the skill is used,
# whereas a registration costs every session ~60 deferred tool names plus the
# server's instructions block on every turn. The setup chain removes stale
# registrations; `make hyperdx-mcp-register` re-adds them on purpose.
.PHONY: _cleanup-hyperdx-mcp
_cleanup-hyperdx-mcp:
	@for s in hyperdx-prod hyperdx-local; do \
		claude mcp remove $$s --scope user >/dev/null 2>&1 && echo "  ✓ removed stale $$s MCP registration (use hdx.py via the otel skill)" || true; \
	done

## Opt-in: register hyperdx-prod / hyperdx-local as MCP servers for this user.
## Not part of `make setup` — see _cleanup-hyperdx-mcp for why.
.PHONY: hyperdx-mcp-register
hyperdx-mcp-register:
	@echo "  hyperdx-prod MCP (remote HTTP — bearer via 1Password)..."
	@TOKEN="$$(OP_ACCOUNT=tkrumm $(DOTFILES_DIR)/scripts/secrets-run read op://vps/clickstack/AGENT_ACCESS_KEY 2>/dev/null)"; \
	if [ -n "$$TOKEN" ]; then \
		claude mcp remove hyperdx-prod --scope user 2>/dev/null || true; \
		claude mcp add hyperdx-prod --scope user --transport http https://hyperdx.jkrumm.com/api/mcp --header "Authorization: Bearer $$TOKEN"; \
		echo "    ✓ hyperdx-prod MCP registered (clickstack_* tools)"; \
	else \
		echo "    · could not read op://vps/clickstack/AGENT_ACCESS_KEY — skipping"; \
	fi
	@if [ -f "$(HOME)/.config/hyperdx/local.env" ]; then \
		KEY="$$(grep '^HYPERDX_LOCAL_ACCESS_KEY=' $(HOME)/.config/hyperdx/local.env | cut -d= -f2-)"; \
		[ -n "$$KEY" ] && { claude mcp remove hyperdx-local --scope user 2>/dev/null || true; claude mcp add hyperdx-local --scope user --transport http http://localhost:7707/api/mcp --header "Authorization: Bearer $$KEY"; echo "    ✓ hyperdx-local MCP registered"; }; \
	fi

.PHONY: _setup-colima
_setup-colima:
	@echo "  Colima (Docker runtime — replaces OrbStack/Docker Desktop)..."
	@# colima + docker CLI + Compose plugin + credential helper (osxkeychain) + lazydocker
	@# TUI all ship from the Brewfile (_setup-packages). docker-credential-helper provides
	@# docker-credential-osxkeychain, which the CLI needs because ~/.docker/config.json sets
	@# "credsStore": "osxkeychain" (OrbStack used to supply this binary). This step wires the
	@# Compose plugin path, creates the VM, and installs the socket LaunchDaemon.
	@echo "    ✓ colima $$(colima version 2>/dev/null | head -1 | sed 's/colima version //') · docker $$(docker --version 2>/dev/null | sed 's/Docker version //;s/,.*//')"
	@# Wire the Compose plugin into the docker CLI search path (idempotent).
	@mkdir -p "$(HOME)/.docker"
	@[ -f "$(HOME)/.docker/config.json" ] || echo '{}' > "$(HOME)/.docker/config.json"
	@if jq -e '.cliPluginsExtraDirs | index("$(BREW_PREFIX)/lib/docker/cli-plugins")' "$(HOME)/.docker/config.json" >/dev/null 2>&1; then \
		echo "    · compose plugin path (ok)"; \
	else \
		tmp=$$(mktemp); \
		jq '.cliPluginsExtraDirs = ((.cliPluginsExtraDirs // []) + ["$(BREW_PREFIX)/lib/docker/cli-plugins"] | unique)' \
			"$(HOME)/.docker/config.json" > "$$tmp" && mv "$$tmp" "$(HOME)/.docker/config.json"; \
		echo "    ✓ compose plugin path added to ~/.docker/config.json"; \
	fi
	@# Create the VM with our config if it doesn't exist yet (sized via COLIMA_* vars),
	@# then hand it off to the brew service to manage.
	@if [ -f "$(HOME)/.colima/default/colima.yaml" ]; then \
		echo "    · colima VM config (ok)"; \
	else \
		echo "    Creating colima VM ($(COLIMA_CPU) CPU / $(COLIMA_MEMORY)GB / $(COLIMA_DISK)GB, vz+rosetta)..."; \
		colima start --vm-type vz --vz-rosetta --mount-type virtiofs \
			--cpu $(COLIMA_CPU) --memory $(COLIMA_MEMORY) --disk $(COLIMA_DISK) >/dev/null 2>&1 \
			&& colima stop >/dev/null 2>&1 \
			&& echo "    ✓ colima VM created" \
			|| echo "    ✗ colima create failed — run: make colima-start"; \
	fi
	@# Always-on: brew service (RunAtLoad + KeepAlive) reads the persisted config.
	@if brew services list 2>/dev/null | grep -E '^colima' | grep -q started; then \
		echo "    · colima service (started, auto-starts at login)"; \
	else \
		brew services start colima >/dev/null 2>&1 \
			&& echo "    ✓ colima service started (auto-starts at login)" \
			|| echo "    ✗ colima service failed — run: brew services start colima"; \
	fi
	@$(MAKE) --no-print-directory _colima-supervise
	@# Pin the docker CLI to the colima context (persists across reboots).
	@tmp=$$(mktemp); jq '.currentContext = "colima"' "$(HOME)/.docker/config.json" > "$$tmp" \
		&& mv "$$tmp" "$(HOME)/.docker/config.json"
	@echo "    · docker context → colima"
	@# Maintain /var/run/docker.sock → colima socket via a root LaunchDaemon (what
	@# OrbStack's privileged helper did). Single mechanism covering every default-
	@# socket consumer: docker CLI, Raycast Docker extension (sanitizes env, so
	@# DOCKER_HOST/context can't reach it), IDEs, Testcontainers. Needs sudo.
	@DAEMON=/Library/LaunchDaemons/com.colima.docker-socket.plist; \
	TMP=$$(mktemp); sed "s|__HOME__|$(HOME)|g" \
		"$(DOTFILES_DIR)/colima/com.colima.docker-socket.plist.template" > "$$TMP"; \
	if sudo cmp -s "$$TMP" "$$DAEMON" 2>/dev/null; then \
		echo "    · docker-socket LaunchDaemon (ok)"; \
	else \
		sudo cp "$$TMP" "$$DAEMON" && sudo chown root:wheel "$$DAEMON" && sudo chmod 644 "$$DAEMON" \
			&& sudo launchctl bootout system "$$DAEMON" 2>/dev/null; \
		sudo launchctl bootstrap system "$$DAEMON" \
			&& echo "    ✓ docker-socket LaunchDaemon installed" \
			|| $(MAKE) --no-print-directory _socket-daemon-healthy-or-fail; \
	fi; \
	rm -f "$$TMP"
	@# Create the symlink now too (bootstrap's RunAtLoad also recreates it at boot).
	@sudo ln -sf "$(HOME)/.colima/default/docker.sock" /var/run/docker.sock 2>/dev/null \
		&& echo "    · /var/run/docker.sock → colima" || true
	@# Migration aid: if OrbStack is still installed, Colima now drives Docker but OrbStack
	@# lingers (and its stale /usr/local/bin/docker symlink shadows brew's). Don't auto-remove
	@# here — the Mac Mini may hold live containers. Flag it; remove via `make orbstack-remove`.
	@brew list --cask orbstack >/dev/null 2>&1 \
		&& echo "    ! OrbStack still installed — migrate any containers, then run: make orbstack-remove" \
		|| true

# Fallback reporters for the root-daemon steps above. `sudo brew services` and
# `sudo launchctl bootstrap` fail whenever sudo can't prompt — but the daemon is
# almost always already loaded and healthy from an earlier run, so re-registration
# failing is not a broken service. Assert the end state rather than the mechanism:
# an already-healthy daemon reads ·, only a genuinely dead one reads ✗. Printing
# ✗ for the benign case trains you to ignore ✗. `launchctl print` needs no sudo.

# Long-running daemons (caddy, dnsmasq): the product is the process itself.
# Takes SERVICE (the brew service NAME), not a label — the label differs by
# Homebrew generation (homebrew.mxcl.<name> vs sh.brew.<name>) and this is the
# one place that has to know. An unresolvable plist is reported as its own
# state: on a system daemon that means brew never registered it here, which is
# a different fix from "registered but not running".
.PHONY: _daemon-running-or-fail
_daemon-running-or-fail:
	@LABEL=$$($(BREW_SERVICE) label $(SERVICE) system 2>/dev/null); \
	if [ -z "$$LABEL" ]; then \
		echo "    ✗ $(NAME) failed — no $(SERVICE) plist in /Library/LaunchDaemons under either name; check: $(HINT)"; \
	elif launchctl print "system/$$LABEL" 2>/dev/null | grep -qE '^[[:space:]]*state = running'; then \
		echo "    · $(NAME) (already running — re-registration skipped)"; \
	else \
		echo "    ✗ $(NAME) failed — check: $(HINT)"; \
	fi

# The socket daemon is a one-shot: it recreates the symlink at boot and exits, so
# `state = running` is never true for it. Its product is the symlink — assert that,
# plus that the daemon is still loaded so the symlink survives the next reboot.
.PHONY: _socket-daemon-healthy-or-fail
_socket-daemon-healthy-or-fail:
	@if launchctl print system/com.colima.docker-socket >/dev/null 2>&1 \
		&& [ "$$(readlink /var/run/docker.sock 2>/dev/null)" = "$(HOME)/.colima/default/docker.sock" ]; then \
		echo "    · docker-socket LaunchDaemon (already loaded — reinstall skipped)"; \
	else \
		echo "    ✗ docker-socket LaunchDaemon failed — check: sudo launchctl print system/com.colima.docker-socket"; \
	fi

# Copy (not symlink) — Ghostty ignores symlinked theme files
.PHONY: _copy
_copy:
	@if [ -f "$(DST)" ] && cmp -s "$(SRC)" "$(DST)"; then \
		echo "    · $(notdir $(DST)) (ok)"; \
	else \
		cp "$(SRC)" "$(DST)"; \
		echo "    ✓ $(notdir $(DST)) (copied)"; \
	fi

.PHONY: _link
_link:
	@if [ -L "$(DST)" ] && [ "$$(readlink $(DST))" = "$(SRC)" ]; then \
		echo "    · $(notdir $(DST)) (ok)"; \
	else \
		if [ -e "$(DST)" ] && [ ! -L "$(DST)" ]; then \
			echo "    Backing up $(DST) → $(DST).bak"; \
			mv "$(DST)" "$(DST).bak"; \
		fi; \
		ln -sfn "$(SRC)" "$(DST)"; \
		echo "    ✓ $(notdir $(DST))"; \
	fi

# ============================================================================
# Status
# ============================================================================

.PHONY: status
status:
	@echo ""
	@echo "  Prerequisites"
	@[ -d "/Applications/1Password.app" ] || [ -d "$(HOME)/Applications/1Password.app" ] \
		&& echo "    ✓ 1Password app" || echo "    ✗ 1Password app [not installed]"
	@command -v op >/dev/null 2>&1 && echo "    ✓ op CLI" || echo "    ✗ op CLI [not installed]"
	@command -v brew >/dev/null 2>&1 && echo "    ✓ brew" || echo "    ✗ brew [not installed — run make setup]"
	@command -v claude >/dev/null 2>&1 && echo "    ✓ claude" || echo "    ✗ claude [not installed — run make setup]"
	@echo ""
	@echo "  Symlink health:"
	@echo ""
	@echo "  Config"
	@$(MAKE) --no-print-directory _check DST="$(CLAUDE_DIR)/CLAUDE.md"
	@$(MAKE) --no-print-directory _check DST="$(HOME)/.zshrc"
	@$(MAKE) --no-print-directory _check DST="$(HOME)/.zsh/conf.d"
	@$(MAKE) --no-print-directory _check DST="$(HOME)/.gitconfig"
	@$(MAKE) --no-print-directory _check DST="$(HOME)/.gitconfig-personal"
	@$(MAKE) --no-print-directory _check DST="$(HOME)/.gitconfig-work"
	@$(MAKE) --no-print-directory _check DST="$(HOME)/.config/starship.toml"
	@$(MAKE) --no-print-directory _check DST="$(HOME)/.config/herdr/config.toml"
	@echo "  1Password (personal account)"
	@if bash $(DOTFILES_DIR)/scripts/lib/op-signed-in.sh tkrumm; then \
		echo "    ✓ op session active ($$(op account get --account tkrumm --format=json 2>/dev/null | jq -r '.email // .name // "unknown"'))"; \
	else \
		echo "    ✗ 1Password locked or unavailable [unlock the desktop app]"; \
	fi
	@echo "    · ANTHROPIC_API_KEY not exported (Claude Code uses subscription)"
	@echo "  Agent SDK Keys"
	@security find-generic-password -s claude-sdk-api-key -w >/dev/null 2>&1 \
		&& echo "    ✓ CLAUDE_SDK_API_KEY (Keychain)" \
		|| echo "    ✗ CLAUDE_SDK_API_KEY [not cached — run make setup]"
	@security find-generic-password -s claude-sdk-base-url -w >/dev/null 2>&1 \
		&& echo "    ✓ CLAUDE_SDK_BASE_URL (Keychain)" \
		|| echo "    ✗ CLAUDE_SDK_BASE_URL [not cached — run make setup]"
	@echo "  Rules"
	@$(MAKE) --no-print-directory _check DST="$(CLAUDE_DIR)/rules"
	@echo "  Agents"
	@$(MAKE) --no-print-directory _check DST="$(CLAUDE_DIR)/agents"
	@echo "  Output styles"
	@$(MAKE) --no-print-directory _check DST="$(CLAUDE_DIR)/output-styles"
	@# The style file existing is not the same as it being ACTIVE — a style is only
	@# applied when settings.json names it, and the jq-merge preserves live keys that
	@# the template also sets, so a stale live value survives silently.
	@_s=$$(jq -r '.outputStyle // "unset"' "$(CLAUDE_DIR)/settings.json" 2>/dev/null); \
		[ "$$_s" = "Direct" ] \
			&& echo "    ✓ outputStyle = Direct (active)" \
			|| echo "    ✗ outputStyle = $$_s [expected Direct — set it in ~/.claude/settings.json]"
	@echo "  Settings"
	@if [ -f "$(CLAUDE_DIR)/settings.json" ]; then \
		echo "    ✓ settings.json (hooks + statusline wired)"; \
	else \
		echo "    ✗ settings.json MISSING — run make setup"; \
	fi
	@echo "  Hooks"
	@$(MAKE) --no-print-directory _check DST="$(CLAUDE_DIR)/hooks/notify.ts"
	@$(MAKE) --no-print-directory _check DST="$(CLAUDE_DIR)/hooks/protect-branches.ts"
	@$(MAKE) --no-print-directory _check DST="$(CLAUDE_DIR)/hooks/docker-makefile.ts"
	@$(MAKE) --no-print-directory _check DST="$(CLAUDE_DIR)/hooks/machine-role.ts"
	@echo "  Scripts"
	@$(MAKE) --no-print-directory _check DST="$(CLAUDE_DIR)/statusline.sh"
	@$(MAKE) --no-print-directory _check DST="$(CLAUDE_DIR)/fetch_usage.py"
	@echo "  Gitignore"
	@$(MAKE) --no-print-directory _check DST="$(HOME)/.gitignore_global"
	@echo "  Ghostty"
	@$(MAKE) --no-print-directory _check DST="$(HOME)/.config/ghostty/config"
	@# The ACTIVE pair first — status previously verified only the tracked
	@# alternative, so a missing one-zinc theme (the thing both terminals
	@# actually render) would have reported clean.
	@$(MAKE) --no-print-directory _check-copy \
		SRC="$(DOTFILES_DIR)/config/ghostty/themes/one-zinc-light" \
		DST="$(HOME)/.config/ghostty/themes/one-zinc-light"
	@$(MAKE) --no-print-directory _check-copy \
		SRC="$(DOTFILES_DIR)/config/ghostty/themes/one-zinc-dark" \
		DST="$(HOME)/.config/ghostty/themes/one-zinc-dark"
	@$(MAKE) --no-print-directory _check-copy \
		SRC="$(DOTFILES_DIR)/config/ghostty/themes/basalt-ui-light" \
		DST="$(HOME)/.config/ghostty/themes/basalt-ui-light"
	@$(MAKE) --no-print-directory _check-copy \
		SRC="$(DOTFILES_DIR)/config/ghostty/themes/basalt-ui-dark" \
		DST="$(HOME)/.config/ghostty/themes/basalt-ui-dark"
	@[ -d "/Applications/Ghostty.app" ] \
		&& echo "    ✓ Ghostty.app" \
		|| echo "    · Ghostty.app [not installed — brew bundle install]"
	@echo "  Skills ($(shell ls $(DOTFILES_DIR)/skills/ | wc -l | xargs) — global)"
	@for skill in $(DOTFILES_DIR)/skills/*/; do \
		name=$$(basename "$$skill"); \
		$(MAKE) --no-print-directory _check DST="$(CLAUDE_DIR)/skills/$$name"; \
	done
	@$(MAKE) --no-print-directory _check DST="$(HOME)/.local/bin/imgcli"
	@echo "  Tools"
	@for tool in jq gh fzf zoxide wtp fnm bun uv age coderabbit fallow; do \
		command -v $$tool >/dev/null 2>&1 \
			&& echo "    ✓ $$tool" \
			|| echo "    ✗ $$tool [not installed — run make setup]"; \
	done
	@echo "  Caddy + dnsmasq"
	@brew list caddy &>/dev/null && echo "    ✓ caddy" || echo "    ✗ caddy [not installed — run make setup]"
	@$(MAKE) --no-print-directory _check DST="$(BREW_PREFIX)/etc/Caddyfile"
	@pgrep -x caddy >/dev/null && echo "    ✓ caddy service running" || echo "    ✗ caddy service [not running — run: sudo brew services start caddy]"
	@security dump-trust-settings -d 2>/dev/null | grep -q "Caddy" \
		&& echo "    ✓ Caddy CA trusted" || echo "    ✗ Caddy CA [not trusted — run: make setup]"
	@brew list dnsmasq &>/dev/null && echo "    ✓ dnsmasq" || echo "    ✗ dnsmasq [not installed — run make setup]"
	@[ -f /etc/resolver/test ] && echo "    ✓ /etc/resolver/test" || echo "    ✗ /etc/resolver/test [missing — run make setup]"
	@pgrep -x dnsmasq >/dev/null && echo "    ✓ dnsmasq service running" || echo "    ✗ dnsmasq service [not running — run: sudo brew services start dnsmasq]"
	@brew list sleepwatcher &>/dev/null && echo "    ✓ sleepwatcher" || echo "    ✗ sleepwatcher [not installed — run make setup]"
	@brew services list | grep sleepwatcher | grep -q started && echo "    ✓ sleepwatcher service started" || echo "    ✗ sleepwatcher service [not started — run make setup]"
	@$(MAKE) --no-print-directory _check DST="$(HOME)/.wakeup"
	@echo "  pnpm"
	@if command -v pnpm >/dev/null 2>&1; then \
		echo "    ✓ pnpm $$(pnpm --version)"; \
	else \
		echo "    ✗ pnpm [not installed — run make setup]"; \
	fi
	@echo "  Browser debugging"
	@if claude mcp list 2>/dev/null | grep -q "chrome-devtools"; then \
		echo "    ✓ chrome-devtools MCP (deferred loading)"; \
	else \
		echo "    ✗ chrome-devtools MCP [not registered — run make setup]"; \
	fi
	@echo "  Colima (Docker runtime)"
	@for tool in colima docker lazydocker; do \
		command -v $$tool >/dev/null 2>&1 \
			&& echo "    ✓ $$tool" \
			|| echo "    ✗ $$tool [not installed — run make setup]"; \
	done
	@docker compose version >/dev/null 2>&1 \
		&& echo "    ✓ docker compose plugin" \
		|| echo "    ✗ docker compose plugin [run make setup]"
	@brew services list 2>/dev/null | grep -E '^colima' | grep -q started \
		&& echo "    ✓ colima service (auto-starts at login)" \
		|| echo "    ✗ colima service [not started — run: make colima-start]"
	@colima status >/dev/null 2>&1 \
		&& echo "    ✓ colima VM running" \
		|| echo "    ✗ colima VM [not running — run: make colima-start]"
	@echo "  sideclaw MCP"
	@if [ ! -f "$(SOURCEROOT)/sideclaw/server/mcp.ts" ]; then \
		echo "    · sideclaw not cloned — skipping"; \
	elif claude mcp list 2>/dev/null | grep -q "sideclaw"; then \
		echo "    ✓ sideclaw MCP registered"; \
	else \
		echo "    ✗ sideclaw MCP [not registered — run make setup]"; \
	fi
	@echo "  research-gateway MCP"
	@if claude mcp list 2>/dev/null | grep -q "research-gateway"; then \
		echo "    ✓ research-gateway MCP registered"; \
	else \
		echo "    ✗ research-gateway MCP [not registered — run make setup]"; \
	fi
	@echo "  usage-tracker"
	@if [ ! -f "$(SOURCEROOT)/usage-tracker/package.json" ]; then \
		echo "    · usage-tracker not cloned — skipping"; \
	elif launchctl list 2>/dev/null | grep -q "com.jkrumm.usage-tracker"; then \
		echo "    ✓ ingest LaunchAgent loaded (com.jkrumm.usage-tracker)"; \
	else \
		echo "    ✗ ingest LaunchAgent [not loaded — run make setup]"; \
	fi
	@echo "  Secrets (headless SOPS+age cache)"
	@command -v sops >/dev/null 2>&1 && echo "    ✓ sops" || echo "    ✗ sops [not installed — run make setup]"
	@command -v varlock >/dev/null 2>&1 && echo "    ✓ varlock" || echo "    ✗ varlock [not installed — run make setup]"
	@$(MAKE) --no-print-directory _check DST="$(HOME)/.local/bin/secrets-run"
	@if [ -f "$(HOME)/.config/secrets/backend" ]; then \
		BACKEND=$$(cat "$(HOME)/.config/secrets/backend"); \
		echo "    · backend marker: $$BACKEND"; \
		if [ "$$BACKEND" = "cache" ]; then \
			if [ -f "$(HOME)/.config/sops/age/keys.txt" ]; then \
				PERMS=$$(stat -f "%OLp" "$(HOME)/.config/sops/age/keys.txt" 2>/dev/null); \
				if [ "$$PERMS" = "600" ]; then \
					echo "    ✓ age key (0600)"; \
				else \
					echo "    ✗ age key [permissions $$PERMS, expected 0600 — chmod 600 ~/.config/sops/age/keys.txt]"; \
				fi; \
			else \
				echo "    ✗ age key [missing — run make secrets-backend-cache]"; \
			fi; \
			if [ -f "$(SECRETS_PRIVATE_REPO)/cache/secrets.enc.json" ]; then \
				AGE_DAYS=$$(( ( $$(date +%s) - $$(stat -f %m "$(SECRETS_PRIVATE_REPO)/cache/secrets.enc.json") ) / 86400 )); \
				echo "    · cache/secrets.enc.json (~$${AGE_DAYS}d old)"; \
			else \
				echo "    · no cache yet at $(SECRETS_PRIVATE_REPO)/cache — run make secrets-seed"; \
			fi; \
		fi; \
	else \
		echo "    ✗ backend marker [missing — run make setup]"; \
	fi
	@echo ""
	@echo "  Doctor"
# Non-fatal on purpose: `status` is a report, not a gate, and a findings exit
# would mask every section after it. Surfaced HERE because a dedicated target
# nobody knows to run is how two agents once accumulated 40,000 failed spawns
# unseen.
	@bash $(DOTFILES_DIR)/scripts/doctor.sh --local 2>&1 | sed 's/^/  /' || true
	@echo ""

.PHONY: _check
_check:
	@if [ -L "$(DST)" ] && [ -e "$(DST)" ]; then \
		echo "    ✓ $(notdir $(DST))"; \
	elif [ -L "$(DST)" ]; then \
		echo "    ✗ $(notdir $(DST)) [BROKEN]"; \
	elif [ -e "$(DST)" ]; then \
		echo "    ✗ $(notdir $(DST)) [real file — run make setup]"; \
	else \
		echo "    ✗ $(notdir $(DST)) [missing — run make setup]"; \
	fi

# Check for copied (not symlinked) files — used for Ghostty theme files
.PHONY: _check-copy
_check-copy:
	@if [ -f "$(DST)" ] && ! [ -L "$(DST)" ] && cmp -s "$(SRC)" "$(DST)"; then \
		echo "    ✓ $(notdir $(DST)) (copy)"; \
	elif [ -f "$(DST)" ] && ! [ -L "$(DST)" ]; then \
		echo "    ✗ $(notdir $(DST)) [stale copy — run make setup]"; \
	else \
		echo "    ✗ $(notdir $(DST)) [missing — run make setup]"; \
	fi

# ============================================================================
# GitHub Config — apply branch protection + merge settings to all repos
# ============================================================================

.PHONY: github-config
github-config:
	@chmod +x $(DOTFILES_DIR)/scripts/github-config.sh
	@$(DOTFILES_DIR)/scripts/github-config.sh

.PHONY: github-config-dry
github-config-dry:
	@chmod +x $(DOTFILES_DIR)/scripts/github-config.sh
	@DRY_RUN=1 $(DOTFILES_DIR)/scripts/github-config.sh

# ============================================================================
# Colima — Docker runtime VM management (replaces OrbStack/Docker Desktop)
# ============================================================================
# Resources via COLIMA_CPU / COLIMA_MEMORY / COLIMA_DISK (see top of file).
# Always-on via brew service (RunAtLoad + KeepAlive) — manage with these targets.
# Never bare `colima stop` (KeepAlive relaunches it) and never
# `brew services restart colima`: brew REGENERATES the stock plist and
# bootstraps THAT, so a repaired file never reaches launchd — launchctl keeps
# running `colima start -f` with the inverted KeepAlive while the file on disk
# looks converged. The only reload that re-reads the file is bootout +
# bootstrap (kickstart -k does not), which is what _colima-rearm does.
# GUI: Raycast "Manage Docker" extension + `lazydocker` TUI.

.PHONY: colima-start
colima-start:
	@if [ -z "$$($(BREW_SERVICE) plist colima 2>/dev/null)" ]; then \
		brew services start colima >/dev/null 2>&1 || true; \
	fi
	@$(MAKE) --no-print-directory _colima-supervise
	@$(MAKE) --no-print-directory _colima-rearm

.PHONY: colima-stop
colima-stop:
	@brew services stop colima

# Apply current COLIMA_CPU/MEMORY to the persisted config, converge the plist,
# then bootout + bootstrap so launchd runs the converged definition. Restarts
# the VM and every container on it, by design. (Disk only grows via recreate.)
.PHONY: colima-restart
colima-restart:
	@if [ -f "$(HOME)/.colima/default/colima.yaml" ]; then \
		sed -i '' 's/^cpu: .*/cpu: $(COLIMA_CPU)/; s/^memory: .*/memory: $(COLIMA_MEMORY)/' \
			"$(HOME)/.colima/default/colima.yaml"; \
	fi
	@if [ -z "$$($(BREW_SERVICE) plist colima 2>/dev/null)" ]; then \
		brew services start colima >/dev/null 2>&1 || true; \
	fi
	@$(MAKE) --no-print-directory _colima-supervise
	@$(MAKE) --no-print-directory _colima-rearm FORCE=1

# Make launchd run the converged plist: bootout the loaded job, wait for the
# label to disappear, bootstrap the file. Idempotent unless FORCE=1 — if launchd
# already holds the wrapper as its program there is nothing to re-arm and the
# VM is left alone. Bouncing means a Docker outage of ~30s, so this is reached
# only from colima-start / colima-restart, never from `make setup`.
.PHONY: _colima-rearm
_colima-rearm:
	@PLIST=$$($(BREW_SERVICE) plist colima 2>/dev/null); \
	TARGET=$$($(BREW_SERVICE) target colima 2>/dev/null); \
	WRAP="$(DOTFILES_DIR)/colima/colima-start.sh"; \
	if [ -z "$$PLIST" ] || [ -z "$$TARGET" ]; then \
		echo "  ✗ no colima plist under either name (sh.brew.colima / homebrew.mxcl.colima) — nothing to bootstrap"; exit 1; \
	fi; \
	LOADED=$$(launchctl print "$$TARGET" 2>/dev/null | awk -F' = ' '/^[[:space:]]*program = /{ print $$2; exit }'); \
	if [ "$(FORCE)" != "1" ] && [ "$$LOADED" = "$$WRAP" ]; then \
		echo "    · launchd already runs the supervised job — not bouncing the VM"; exit 0; \
	fi; \
	echo "    Re-arming launchd (bootout + bootstrap — the VM and every container restart)..."; \
	launchctl bootout "$$TARGET" 2>/dev/null || true; \
	i=0; while launchctl print "$$TARGET" >/dev/null 2>&1; do \
		i=$$((i+1)); [ $$i -gt 60 ] && { echo "  ✗ old colima job never went away"; exit 1; }; \
		sleep 0.5; \
	done; \
	launchctl bootstrap "gui/$$(id -u)" "$$PLIST" || { echo "  ✗ bootstrap failed"; exit 1; }; \
	LOADED=$$(launchctl print "$$TARGET" 2>/dev/null | awk -F' = ' '/^[[:space:]]*program = /{ print $$2; exit }'); \
	if [ "$$LOADED" = "$$WRAP" ]; then \
		echo "    ✓ launchd runs $${WRAP##*/} from $${PLIST##*/}"; \
	else \
		echo "  ✗ launchd loaded '$${LOADED:-nothing}' instead of the wrapper"; exit 1; \
	fi

# Converge colima's brew-service plist onto the supervised shape. Called after
# every brew-services operation above AND from _setup-colima, because BREW
# REGENERATES THAT PLIST from the formula's `service` block on every
# start/restart and on every upgrade — a hand-edit alone reverts silently, with
# nothing in any log.
#
# The plist is RESOLVED, never spelled: Homebrew 6 writes `sh.brew.colima.plist`
# and deletes `homebrew.mxcl.colima.plist` on the next start/restart. Hardcoding
# the old name made this step print "absent — nothing to supervise" and exit 0
# over a freshly written STOCK plist — the exact inverted KeepAlive this target
# exists to repair, reported green. See scripts/lib/brew-service.sh.
#
# Two changes, both load-bearing:
#
#   KeepAlive  { SuccessfulExit => true }  ->  true
#       Homebrew's version restarts the job only on a ZERO exit. `colima start
#       -f` runs the VM in the foreground, so exit 0 means "shut down cleanly"
#       and non-zero means "failed to start" — the condition is inverted
#       against what you want. A dirty Lima image after an unclean shutdown
#       therefore leaves Docker down until a human logs in, with nothing
#       checking `docker info`. `{ Crashed => true }` does NOT fix it: launchd's
#       Crashed means death by SIGNAL, not a non-zero exit.
#
#   ProgramArguments  colima start -f  ->  colima/colima-start.sh
#       Bare KeepAlive on its own turns a persistently broken image into a full
#       Lima VM boot attempt every 10s forever. The wrapper bounds that to N
#       fast attempts then a cool-off, and never latches off permanently.
#
# Deliberately does NOT kickstart. Reloading bounces the VM and every container
# on it, and this target is reached from `make setup` — a setup run that
# silently takes Docker down for a minute is the surprise makefile-conventions.md
# exists to prevent. The file is always correct after this; it takes effect at
# the next start, which for a boot-path fix is exactly when it matters.
# `make colima-status` reports whether the running job is the supervised one.
.PHONY: _colima-supervise
_colima-supervise:
	@PLIST=$$($(BREW_SERVICE) plist colima 2>/dev/null); \
	WRAP="$(DOTFILES_DIR)/colima/colima-start.sh"; \
	if [ -z "$$PLIST" ]; then \
		if brew services info colima --json 2>/dev/null | grep -q '"loaded": *true'; then \
			echo "  ✗ colima is a LOADED brew service with NO plist under either name"; \
			echo "    looked for: $(LAUNCHAGENTS)/sh.brew.colima.plist"; \
			echo "                $(LAUNCHAGENTS)/homebrew.mxcl.colima.plist"; \
			echo "    The boot path cannot be converged, so it is DISARMED — never report this green."; \
			echo "    ↳ brew services info colima --json"; \
			exit 1; \
		fi; \
		echo "    · colima brew service not registered here — nothing to supervise"; \
	elif [ "$$(/usr/libexec/PlistBuddy -c 'Print :KeepAlive' "$$PLIST" 2>/dev/null)" = "true" ] \
	  && [ "$$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$$PLIST" 2>/dev/null)" = "$$WRAP" ]; then \
		echo "    · colima supervisor (ok)"; \
	else \
		chmod +x "$$WRAP"; \
		/usr/libexec/PlistBuddy -c 'Delete :KeepAlive' "$$PLIST" >/dev/null 2>&1 || true; \
		/usr/libexec/PlistBuddy -c 'Add :KeepAlive bool true' "$$PLIST" >/dev/null; \
		/usr/libexec/PlistBuddy -c 'Delete :ProgramArguments' "$$PLIST" >/dev/null 2>&1 || true; \
		/usr/libexec/PlistBuddy -c 'Add :ProgramArguments array' "$$PLIST" >/dev/null; \
		/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $$WRAP" "$$PLIST" >/dev/null; \
		plutil -lint "$$PLIST" >/dev/null || { echo "  ✗ colima plist is malformed after edit"; exit 1; }; \
		echo "    ✓ colima supervisor pinned (bare KeepAlive + bounded-retry wrapper)"; \
		TARGET=$$($(BREW_SERVICE) target colima 2>/dev/null); \
		LOADED=$$(launchctl print "$$TARGET" 2>/dev/null | awk -F' = ' '/^[[:space:]]*program = /{ print $$2; exit }'); \
		if [ -n "$$LOADED" ] && [ "$$LOADED" != "$$WRAP" ]; then \
			echo "      ! launchd still runs the STOCK definition ($$LOADED) — the file is fixed, the loaded job is not"; \
			echo "      ↳ make colima-restart   (bootout + bootstrap; restarts the VM — never 'brew services restart', it regenerates the stock plist)"; \
		else \
			echo "      ↳ active at next boot; 'make colima-restart' re-arms it now (restarts the VM)"; \
		fi; \
	fi

.PHONY: colima-status
colima-status:
	@brew services list | grep -E '^colima' || echo "  colima service: not registered"
	@colima status
	@# Assert the boot path, not just the running VM. `brew upgrade colima` and
	@# every `brew services start/restart` rewrite the plist back to Homebrew's
	@# inverted `KeepAlive { SuccessfulExit = true }`, and NOTHING errors when
	@# that happens — the VM keeps running fine and only the next failed start
	@# goes unretried. See _colima-supervise.
	@PLIST=$$($(BREW_SERVICE) plist colima 2>/dev/null); \
	if [ -z "$$PLIST" ]; then \
		echo "  ✗ boot path UNRESOLVABLE — no sh.brew.colima/homebrew.mxcl.colima plist on disk"; \
	elif [ "$$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$$PLIST" 2>/dev/null)" = "$(DOTFILES_DIR)/colima/colima-start.sh" ] \
	  && [ "$$(/usr/libexec/PlistBuddy -c 'Print :KeepAlive' "$$PLIST" 2>/dev/null)" = "true" ]; then \
		echo "  ✓ boot path supervised on disk (bare KeepAlive + bounded-retry wrapper) — $${PLIST##*/}"; \
	else \
		echo "  ✗ boot path NOT supervised — brew regenerated $${PLIST##*/}; run: make colima-restart"; \
	fi; \
	TARGET=$$($(BREW_SERVICE) target colima 2>/dev/null); \
	LOADED=$$(launchctl print "$$TARGET" 2>/dev/null | awk -F' = ' '/^[[:space:]]*program = /{ print $$2; exit }'); \
	if [ -z "$$LOADED" ]; then \
		echo "  ✗ launchd has no colima job loaded ($$TARGET)"; \
	elif [ "$$LOADED" = "$(DOTFILES_DIR)/colima/colima-start.sh" ]; then \
		echo "  ✓ launchd runs the wrapper (loaded job matches the file)"; \
	else \
		echo "  ✗ launchd runs the STOCK definition ($$LOADED) — file repaired, job stale; run: make colima-restart"; \
	fi
	@FAILS="$(HOME)/.local/state/colima-supervisor/consecutive-failures"; \
	[ -f "$$FAILS" ] && [ "$$(cat "$$FAILS")" != "0" ] \
		&& echo "  ! $$(cat "$$FAILS") consecutive start failures recorded — see /opt/homebrew/var/log/colima.log" \
		|| true

# Migrate off OrbStack → Colima. Guarded: refuses unless Colima is already running (so
# Docker never goes down), and aborts if OrbStack still holds containers (override with
# FORCE=1 once they're migrated or discarded). Also clears OrbStack's stale root-owned
# /usr/local/bin/docker symlink, which otherwise shadows brew's docker. Needs sudo for that.
.PHONY: orbstack-remove
orbstack-remove:
	@if ! brew list --cask orbstack >/dev/null 2>&1; then \
		echo "  · OrbStack not installed — nothing to do"; exit 0; \
	fi; \
	if ! colima status >/dev/null 2>&1; then \
		echo "  ✗ Colima not running — run 'make colima-start' first so Docker stays up"; exit 1; \
	fi; \
	if [ "$(FORCE)" != "1" ]; then \
		n=$$(docker --context orbstack ps -aq 2>/dev/null | grep -c . || true); \
		if [ -n "$$n" ] && [ "$$n" != "0" ]; then \
			echo "  ✗ OrbStack still has $$n container(s) — migrate them, then re-run with FORCE=1"; exit 1; \
		fi; \
	fi; \
	osascript -e 'quit app "OrbStack"' 2>/dev/null || true; \
	brew uninstall --cask orbstack --zap && echo "  ✓ OrbStack uninstalled + zapped"; \
	if [ -L /usr/local/bin/docker ] && ! readlink /usr/local/bin/docker | grep -q Cellar; then \
		sudo rm -f /usr/local/bin/docker \
			&& echo "  ✓ removed stale /usr/local/bin/docker symlink" \
			|| echo "  ! couldn't remove /usr/local/bin/docker (sudo) — rm it manually"; \
	fi; \
	echo "  Done. Verify: docker context show (-> colima) && docker ps"

# ============================================================================
# Brew — Brewfile manifest (the git history of Brewfile is the supply-chain
# audit trail; see the Brewfile header). Brewfile is brew-native only
# (taps + formulae + casks); npm/uv tools stay Makefile-managed.
# ============================================================================

.PHONY: brew-check
brew-check:
	@echo "  Checking machine against Brewfile..."
	@brew bundle check --verbose --file=$(DOTFILES_DIR)/Brewfile

.PHONY: brew-diff
brew-diff:
	@echo "  Installed but NOT declared in Brewfile (dry-run — review, then add or remove):"
	@brew bundle cleanup --file=$(DOTFILES_DIR)/Brewfile

.PHONY: brew-dump
brew-dump:
	@brew bundle dump --describe --formulae --casks --taps --force --file=/tmp/Brewfile.gen
	@# Strip restart_service: service lifecycle is owned by the _setup-* config steps
	@# (they handle root vs user correctly); the Brewfile stays install-only/declarative.
	@sed -i '' 's/, restart_service: :changed//' /tmp/Brewfile.gen
	@awk '/^[^#[:space:]]/{exit} {print}' $(DOTFILES_DIR)/Brewfile > /tmp/Brewfile.head
	@cat /tmp/Brewfile.head /tmp/Brewfile.gen > $(DOTFILES_DIR)/Brewfile
	@echo "  ✓ Brewfile regenerated — REVIEW THE DIFF: git -C $(DOTFILES_DIR) diff Brewfile"

.PHONY: brew-upgrade brew-upgrade-dry
# Guarded `brew upgrade` — see scripts/brew-upgrade.sh for the full rationale.
# Blanket-upgrading homebrew/core formulae is NOT the npm-style supply-chain
# risk (reviewed PRs, Homebrew-CI-built bottles) — the real hazard here is
# SILENT CONFIG REVERT on `caddy`: `brew upgrade caddy` drops the xcaddy-built
# dns.providers.cloudflare module (wildcard cert renewal fails ~60 days later,
# fix: make caddy-dns-build). `brew pin` is the actual enforcement — it makes
# a bare, hand-typed `brew upgrade` skip it too, not just this target — this
# script converges the pin and asserts the invariant afterward. Third-party
# taps and casks are reported, never auto-upgraded — that's /upgrade-deps' job.
brew-upgrade:
	@bash $(DOTFILES_DIR)/scripts/brew-upgrade.sh
brew-upgrade-dry:
	@bash $(DOTFILES_DIR)/scripts/brew-upgrade.sh --dry-run

# ============================================================================
# Clean — purge caches (brew, npm, pnpm, bun)
# ============================================================================

.PHONY: clean
clean:
	@echo ""
	@echo "  Cleaning caches..."
	@brew cleanup && echo "    ✓ brew cache"
	@find $(HOME)/.npm -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; echo "    ✓ npm cache ($$(du -sh $(HOME)/.npm 2>/dev/null | cut -f1 || echo 0) freed)"
	@rm -rf $(HOME)/Library/pnpm/store && echo "    ✓ pnpm store"
	@bun pm cache rm 2>/dev/null && echo "    ✓ bun cache"
	@echo ""

LAUNCHAGENTS  := $(HOME)/Library/LaunchAgents
# Source dir for _render-plists; every surviving caller overrides this.
PLIST_DIR     ?= $(DOTFILES_DIR)/scripts

# Internal: render any plist list from $(PLIST_DIR) templates.
.PHONY: _render-plists
_render-plists:
	@for label in $(PLISTS); do \
		SRC="$(PLIST_DIR)/$$label.plist.template"; \
		DST="$(LAUNCHAGENTS)/$$label.plist"; \
		TMP="$$(mktemp)"; \
		sed -e "s|__HOME__|$(HOME)|g" -e "s|__DOTFILES_DIR__|$(DOTFILES_DIR)|g" "$$SRC" > "$$TMP"; \
		if [ ! -f "$$DST" ] || ! diff -q "$$TMP" "$$DST" >/dev/null 2>&1; then \
			mv "$$TMP" "$$DST"; \
			launchctl unload "$$DST" 2>/dev/null || true; \
			launchctl load "$$DST"; \
			echo "    ✓ $$label (installed + loaded)"; \
		else \
			rm "$$TMP"; \
			echo "    · $$label (up to date)"; \
		fi; \
	done

# ============================================================================
# usage-tracker — local SQLite token/cost telemetry across all AI tools
# ============================================================================
# Separate repo (~/SourceRoot/usage-tracker). It owns its own LaunchAgent
# template + installer; here we just install deps and hand off to its installer,
# so the plist (absolute bun + repo paths) stays the repo's concern. Skips
# cleanly if the repo isn't cloned, mirroring _setup-sideclaw-mcp.

.PHONY: _setup-usage-tracker
_setup-usage-tracker:
	@echo "  usage-tracker (token/cost telemetry, 15-min ingest)..."
	@if [ -f "$(SOURCEROOT)/usage-tracker/package.json" ]; then \
		( cd "$(SOURCEROOT)/usage-tracker" \
			&& bun install >/dev/null 2>&1 \
			&& bash launchd/install-agent.sh >/dev/null ) \
			&& echo "    ✓ deps installed + LaunchAgent loaded (com.jkrumm.usage-tracker)" \
			|| echo "    ✗ usage-tracker setup failed — run 'make install-agent' in the repo"; \
	else \
		echo "    · usage-tracker not cloned at $(SOURCEROOT)/usage-tracker — skipping"; \
	fi

# ============================================================================
# Secrets — headless SOPS+age cache (see ~/SourceRoot/dotfiles-private)
# ============================================================================
# Tooling lives here (public); the ref-list (headless.refs) + the encrypted
# cache live in the private repo. secrets-run is a drop-in `op` shim whose
# backend is selected per machine by ~/.config/secrets/backend:
#   op    (MacBook, human present)  — passthrough to live `op` (biometric)
#   cache (mini, headless)          — sops+age decrypt in memory, no prompts
# `secrets-run` (symlinked by `make setup`) is the runtime entrypoint for both.

.PHONY: secrets-seed
secrets-seed:
	@chmod +x $(DOTFILES_DIR)/scripts/secrets-seed.sh
	@SECRETS_PRIVATE_REPO="$(SECRETS_PRIVATE_REPO)" $(DOTFILES_DIR)/scripts/secrets-seed.sh

# Rotate the mini age key + re-seal the cache under a fresh recipient (use if the
# private key may be exposed). Never prints the key; reseeds atomically. MINI-only.
.PHONY: secrets-rotate
secrets-rotate:
	@chmod +x $(DOTFILES_DIR)/scripts/secrets-rotate.sh
	@SECRETS_PRIVATE_REPO="$(SECRETS_PRIVATE_REPO)" DOTFILES_DIR="$(DOTFILES_DIR)" $(DOTFILES_DIR)/scripts/secrets-rotate.sh

# Tailscale serve/funnel bindings — declared in dotfiles-private per machine
# (tailscale-serve.<machine>.conf), applied here. Serve config pins the machine's
# MagicDNS name, so a device rename orphans every binding; re-applying is the fix.
.PHONY: tailscale-serve tailscale-serve-check
tailscale-serve:
	@chmod +x $(DOTFILES_DIR)/scripts/tailscale-serve.sh
	@SECRETS_PRIVATE_REPO="$(SECRETS_PRIVATE_REPO)" $(DOTFILES_DIR)/scripts/tailscale-serve.sh

tailscale-serve-check:
	@chmod +x $(DOTFILES_DIR)/scripts/tailscale-serve.sh
	@SECRETS_PRIVATE_REPO="$(SECRETS_PRIVATE_REPO)" $(DOTFILES_DIR)/scripts/tailscale-serve.sh --check

# Tailnet-wide ACL as code — declared in dotfiles-private/tailscale-acl.jsonc,
# applied here. Moved out of homelab-private 2026-07-27: the ACL governs Mac↔Mac
# ssh/dev-ports, rb, phone and e-reader, none of which is homelab's, and
# living there put it on the one machine that CANNOT apply it (the API key is
# op://Private, refused by the mini's cache by design).
#
# ALWAYS `tailscale-acl-diff` before `-push`: push overwrites the whole tailnet
# ACL, and a bad rule can lock you out of every host at once. Push prompts for
# confirmation; ACL_PUSH_YES=1 bypasses it for non-interactive use.
.PHONY: tailscale-acl-pull tailscale-acl-diff tailscale-acl-push
tailscale-acl-pull:
	@chmod +x $(DOTFILES_DIR)/scripts/tailscale-acl-sync.sh
	@SECRETS_PRIVATE_REPO="$(SECRETS_PRIVATE_REPO)" $(DOTFILES_DIR)/scripts/tailscale-acl-sync.sh pull

tailscale-acl-diff:
	@chmod +x $(DOTFILES_DIR)/scripts/tailscale-acl-sync.sh
	@SECRETS_PRIVATE_REPO="$(SECRETS_PRIVATE_REPO)" $(DOTFILES_DIR)/scripts/tailscale-acl-sync.sh diff

tailscale-acl-push:
	@chmod +x $(DOTFILES_DIR)/scripts/tailscale-acl-sync.sh
	@SECRETS_PRIVATE_REPO="$(SECRETS_PRIVATE_REPO)" $(DOTFILES_DIR)/scripts/tailscale-acl-sync.sh push

# Lint the shim + its harness. Static-only, runs on ANY machine (no cache/age key needed).
.PHONY: secrets-lint
secrets-lint:
	@command -v shellcheck >/dev/null 2>&1 || { echo "  ✗ shellcheck not installed — run 'brew bundle' (it's in the Brewfile)"; exit 1; }
	@shellcheck $(DOTFILES_DIR)/scripts/secrets-run $(DOTFILES_DIR)/scripts/secrets-run-diagnostics.sh \
		$(DOTFILES_DIR)/scripts/secrets-run.test.sh \
		$(DOTFILES_DIR)/scripts/secrets-seed.sh $(DOTFILES_DIR)/scripts/secrets-seed.test.sh \
		$(DOTFILES_DIR)/scripts/secrets-seed-batch.test.sh
	@echo "  ✓ shellcheck clean (secrets-run + diagnostics + secrets-seed + harnesses)"
	@# The batch-resolve harness is hermetic (stubbed op, no account, no age key, no
	@# cache backend), so unlike secrets-seed.test.sh it can run HERE — on the machine
	@# where a human actually runs `make secrets-seed`. It guards how many 1Password
	@# dialogs a reseal costs, which is exactly the thing that regressed.
	@chmod +x $(DOTFILES_DIR)/scripts/secrets-seed-batch.test.sh
	@$(DOTFILES_DIR)/scripts/secrets-seed-batch.test.sh

# Functional regression suite for the shim + the seed. MINI-ONLY: both harnesses'
# preflight requires the `cache` backend (+ secrets-run.test.sh needs an age key).
# Lints first. Run after any change to secrets-run or secrets-seed.sh.
.PHONY: secrets-test
secrets-test: secrets-lint
	@chmod +x $(DOTFILES_DIR)/scripts/secrets-run.test.sh
	@$(DOTFILES_DIR)/scripts/secrets-run.test.sh
	@# Runs BEFORE the mini-gated suite because it is the one that can run here:
	@# it stubs op on PATH and guards the read loop (retries, the time bound, and
	@# the dead-ref collector). It was written as a regression test and then wired
	@# into no target at all — an unrun test is a comment.
	@chmod +x $(DOTFILES_DIR)/scripts/secrets-seed-retry.test.sh
	@$(DOTFILES_DIR)/scripts/secrets-seed-retry.test.sh
	@chmod +x $(DOTFILES_DIR)/scripts/secrets-seed.test.sh
	@$(DOTFILES_DIR)/scripts/secrets-seed.test.sh

# Resolver regression suite. scripts/lib/brew-service.sh decides WHICH plist the
# supervise/status/restart targets read and rewrite, so a bug here disarms a boot
# path silently — the exact failure the resolver exists to end. Hermetic: it
# drives the lib over a scratch dir and never touches a live LaunchAgent.
.PHONY: brew-service-test
brew-service-test:
	@shellcheck -S warning $(DOTFILES_DIR)/scripts/lib/brew-service.sh $(DOTFILES_DIR)/scripts/brew-service.test.sh
	@chmod +x $(DOTFILES_DIR)/scripts/brew-service.test.sh
	@$(DOTFILES_DIR)/scripts/brew-service.test.sh

# Hook regression suite. Hooks are symlinked live into ~/.claude/hooks, so a bug
# here gates real tool calls immediately — run after any hook edit.
.PHONY: hooks-test
hooks-test:
	@bun test $(DOTFILES_DIR)/hooks/

.PHONY: secrets-backend-cache
secrets-backend-cache:
	@mkdir -p "$(HOME)/.config/secrets"
	@echo "cache" > "$(HOME)/.config/secrets/backend"
	@echo "  ✓ backend marker set to 'cache' (this machine now decrypts headlessly)"
	@if [ -f "$(HOME)/.config/sops/age/keys.txt" ]; then \
		echo "  ✓ age key present ($(HOME)/.config/sops/age/keys.txt)"; \
	else \
		echo "  ✗ age key missing — generate one: age-keygen -o $(HOME)/.config/sops/age/keys.txt"; \
		echo "    then add its public key as a recipient in $(SECRETS_PRIVATE_REPO)/.sops.yaml and reseed"; \
	fi

# Weekly staleness reminder for the SOPS+age secrets cache — pushes a heartbeat
# to an Uptime Kuma push monitor (green while fresh, red once past the max
# age). Never an automated reseed; just nudges the human to run
# `make secrets-seed`. See scripts/secrets-freshness-check.sh.
.PHONY: secrets-freshness-setup secrets-freshness-teardown
secrets-freshness-setup:
	@mkdir -p "$(LAUNCHAGENTS)"
	@$(MAKE) --no-print-directory _render-plists PLISTS="com.jkrumm.secrets-freshness" PLIST_DIR="$(DOTFILES_DIR)/scripts"
	@echo "    ↳ weekly Mon 09:15 → push cache staleness to Uptime Kuma"
secrets-freshness-teardown:
	@PLIST="$(LAUNCHAGENTS)/com.jkrumm.secrets-freshness.plist"; \
	launchctl unload "$$PLIST" 2>/dev/null || true; \
	rm -f "$$PLIST"; \
	echo "  ✓ secrets-freshness torn down (unloaded + plist removed)"

.PHONY: secrets-freshness-check
secrets-freshness-check:
	@bash $(DOTFILES_DIR)/scripts/secrets-freshness-check.sh

# Guarded auto-trigger for the 1Password vault backup (`opbackup`). Present-human
# machines only — the backup is biometric end to end and there is deliberately no
# unattended path, so this removes the REMEMBERING, not the human. Hourly fire,
# with every real decision in scripts/opbackup-auto.sh. Opt-in per machine like
# remote-access, not part of the default setup chain.
.PHONY: opbackup-setup opbackup-teardown opbackup-check
opbackup-setup:
	@BACKEND=$$(tr -d '[:space:]' < "$(HOME)/.config/secrets/backend" 2>/dev/null || echo ""); \
	if [ "$$BACKEND" != "op" ]; then \
		echo "  ✗ secrets backend is '$${BACKEND:-unset}', not 'op' — this is not a present-human machine."; \
		echo "    The backup needs a biometric approval nobody is there to give. Refusing."; \
		exit 1; \
	fi
	@MISSING=""; \
	for bin in op age uv rsync; do \
		command -v $$bin >/dev/null 2>&1 || MISSING="$$MISSING $$bin"; \
	done; \
	if [ -n "$$MISSING" ]; then echo "  ✗ missing on PATH:$$MISSING"; exit 1; fi; \
	echo "  ✓ op, age, uv, rsync present"
	@chmod +x $(DOTFILES_DIR)/scripts/opbackup-auto.sh $(DOTFILES_DIR)/scripts/opbackup-seed-auto.sh
	@bash $(DOTFILES_DIR)/scripts/opbackup-auto.sh --seed-stamp
	@mkdir -p "$(LAUNCHAGENTS)"
	@$(MAKE) --no-print-directory _render-plists PLISTS="com.jkrumm.opbackup" PLIST_DIR="$(DOTFILES_DIR)/scripts"
	@echo "    ↳ hourly at :17 → runs opbackup once >5d stale, screen unlocked, homelab reachable"

opbackup-teardown:
	@PLIST="$(LAUNCHAGENTS)/com.jkrumm.opbackup.plist"; \
	launchctl unload "$$PLIST" 2>/dev/null || true; \
	rm -f "$$PLIST"; \
	echo "  ✓ opbackup auto-trigger torn down (unloaded + plist removed; stamps kept)"

# Run the guard once, printing which precondition it stopped at. Add FORCE=1 to
# bypass the freshness/backoff/lock checks and actually back up now.
opbackup-check:
	@bash $(DOTFILES_DIR)/scripts/opbackup-auto.sh $(if $(FORCE),--force,)

# Hourly copytruncate rotation for the LaunchAgent logs this repo owns. Needed
# because moving those logs out of /tmp removed the only thing that had ever
# bounded them — macOS's periodic cleanup, which DELETES rather than truncates
# and left every KeepAlive agent writing into an unlinked inode.
# /tmp/walkingpad.err was 35 MB with nothing rotating it. newsyslog.d is not an
# option: it needs root, and this machine's root password is deliberately
# MacBook-only. See scripts/log-rotate.sh for the copytruncate rationale.
.PHONY: log-rotate-setup log-rotate-teardown log-rotate-check
log-rotate-setup:
	@mkdir -p "$(LAUNCHAGENTS)" "$(HOME)/Library/Logs"
	@$(MAKE) --no-print-directory _render-plists PLISTS="com.jkrumm.log-rotate" PLIST_DIR="$(DOTFILES_DIR)/scripts"
	@echo "    ↳ hourly → copytruncate any owned log past 16 MB, keep one .1 generation"
log-rotate-teardown:
	@PLIST="$(LAUNCHAGENTS)/com.jkrumm.log-rotate.plist"; \
	launchctl unload "$$PLIST" 2>/dev/null || true; \
	rm -f "$$PLIST"; \
	echo "  ✓ log-rotate torn down (unloaded + plist removed)"
log-rotate-check:
	@bash $(DOTFILES_DIR)/scripts/log-rotate.sh

# Order caddy's boot behind the tailnet address it binds. NEEDS SUDO — caddy is
# a SYSTEM LaunchDaemon in /Library, so this cannot run unattended on the mini
# (the root password is deliberately MacBook-only). Drive it from the MacBook:
#
#   ROOT_PW=$$(op read "op://Private/mac-mini-server/password" --account tkrumm) && \
#     ssh mini "echo '$$ROOT_PW' | sudo -S -v && cd ~/SourceRoot/dotfiles && make caddy-boot-order"
#
# The problem it fixes, stated without inflation: caddy starts pre-login, the
# tailnet utun address is created at login by the Tailscale GUI app, and binding
# a not-yet-existent address makes Caddy abort the ENTIRE config — `.test` and
# metabase.iu-aws.de included. launchd's 10s KeepAlive retry means it self-heals
# ~10s later, so this is a bounded outage on every boot, not a dead machine.
# See caddy/caddy-wait-for-tailnet.sh.
#
# Re-run after any `brew upgrade caddy` or `brew services restart caddy` — brew
# regenerates the daemon plist and the change reverts SILENTLY, exactly like the
# Cloudflare DNS module that `make caddy-dns-build` reinstalls.
.PHONY: caddy-boot-order
caddy-boot-order:
	@WRAPPER=/usr/local/libexec/caddy-wait-for-tailnet.sh; \
	SRC="$(DOTFILES_DIR)/caddy/caddy-wait-for-tailnet.sh"; \
	DAEMON=$$($(BREW_SERVICE) plist caddy system 2>/dev/null); \
	if [ -z "$$DAEMON" ]; then \
		if brew services info caddy --json 2>/dev/null | grep -q '"loaded": *true'; then \
			DAEMON=$$($(BREW_SERVICE) expected caddy system); \
			echo "  ! caddy is loaded with no plist under either name — installing $${DAEMON##*/}"; \
		else \
			echo "  ✗ no caddy plist in /Library/LaunchDaemons under either name — is caddy installed as a brew service?"; exit 1; \
		fi; \
	fi; \
	LABEL=$${DAEMON##*/}; LABEL=$${LABEL%.plist}; \
	sudo mkdir -p /usr/local/libexec; \
	sudo install -o root -g wheel -m 0755 "$$SRC" "$$WRAPPER" \
		|| { echo "  ✗ could not install the wrapper (sudo)"; exit 1; }; \
	echo "  ✓ wrapper installed root-owned at $$WRAPPER"; \
	TMP=$$(mktemp); sed -e "s|__WRAPPER__|$$WRAPPER|g" -e "s|__LABEL__|$$LABEL|g" \
		"$(DOTFILES_DIR)/caddy/caddy.plist.template" > "$$TMP"; \
	plutil -lint "$$TMP" >/dev/null || { rm -f "$$TMP"; echo "  ✗ rendered plist is malformed"; exit 1; }; \
	if sudo cmp -s "$$TMP" "$$DAEMON" 2>/dev/null; then \
		rm -f "$$TMP"; echo "  · caddy daemon already ordered behind the tailnet address"; \
	else \
		sudo cp "$$TMP" "$$DAEMON" && sudo chown root:wheel "$$DAEMON" && sudo chmod 644 "$$DAEMON"; \
		rm -f "$$TMP"; \
		sudo launchctl bootout system "$$DAEMON" 2>/dev/null || true; \
		sudo launchctl bootstrap system "$$DAEMON" \
			&& echo "  ✓ caddy daemon re-bootstrapped through the wrapper" \
			|| $(MAKE) --no-print-directory _daemon-running-or-fail SERVICE=caddy; \
	fi; \
	echo "  ↳ verify: sudo launchctl print system/$$LABEL | grep -E 'state|program'"; \
	echo "    and after any brew upgrade of caddy, re-run this AND make caddy-dns-build"

# Start Obsidian at login on the dev host. Not a nicety: `/brain` and Hermes's
# obsidian skill reach the vault through obsidian-cli, and that CLI is a CLIENT
# of the running app — it talks to ~/.obsidian-cli.sock and exits 1 with "make
# sure Obsidian is running" when the app is down, `obsidian version` included
# (verified 2026-07-31). A closed Obsidian is therefore a closed agent door —
# yet Obsidian was not a login item at all, and the running instance had been
# started by hand 2.5 days after the last boot.
# See obsidian/com.jkrumm.obsidian-autostart.plist.template for why `open -a`
# and no KeepAlive.
#
# Dev-host gated on the `cache` backend marker, the same signal collie-setup and
# caddy-dns-build use — the MacBook opens Obsidian when a human wants it.
#
# The WHOLE recipe is one continued shell line, deliberately. `exit 0` in a make
# recipe ends only that line's shell and make happily runs the next one, so a
# gate written as its own line does not gate anything (collie-setup has exactly
# that latent bug — do not copy its shape here).
.PHONY: obsidian-autostart obsidian-autostart-teardown
obsidian-autostart:
	@BACKEND=$$(tr -d '[:space:]' < "$(HOME)/.config/secrets/backend" 2>/dev/null || echo ""); \
	if [ "$$BACKEND" != "cache" ]; then \
		echo "    · not the dev host (backend=$${BACKEND:-unset}) — obsidian-autostart skipped"; \
	elif [ ! -d "/Applications/Obsidian.app" ]; then \
		echo "  ✗ Obsidian not installed at /Applications/Obsidian.app"; exit 1; \
	else \
		mkdir -p "$(LAUNCHAGENTS)" "$(HOME)/Library/Logs"; \
		$(MAKE) --no-print-directory _render-plists \
			PLISTS="com.jkrumm.obsidian-autostart" PLIST_DIR="$(DOTFILES_DIR)/obsidian"; \
		if pgrep -x Obsidian >/dev/null 2>&1; then \
			echo "    ✓ Obsidian running (pid $$(pgrep -x Obsidian | head -1)) — will also start at next login"; \
		else \
			echo "    ! Obsidian not running right now — 'open -a Obsidian' or reboot to verify"; \
		fi; \
		if [ -x /usr/local/bin/obsidian ]; then \
			echo "    · obsidian-cli present (/usr/local/bin/obsidian) — the /brain agent door"; \
		else \
			echo "    ! obsidian-cli missing — /brain falls back to filesystem access"; \
		fi; \
	fi
obsidian-autostart-teardown:
	@PLIST="$(LAUNCHAGENTS)/com.jkrumm.obsidian-autostart.plist"; \
	launchctl unload "$$PLIST" 2>/dev/null || true; \
	rm -f "$$PLIST"; \
	echo "  ✓ obsidian-autostart torn down (unloaded + plist removed; the app is left running)"

# herdr wiring. Two halves with different scopes:
#   - the Claude Code agent-state hook, which makes a pane report real agent
#     status instead of "unknown". Harmless everywhere (it exits 0 unless
#     HERDR_ENV/HERDR_SOCKET_PATH/HERDR_PANE_ID are set), so install it on any
#     machine. Its settings.json entry lives in config/settings.template.json —
#     `make setup` merges with the template winning on `hooks`, so an entry only
#     added by `herdr integration install` would be deleted on the next run.
#   - the herdr *server*, which belongs only on the dev host. Detected the same
#     way as git-headless: the cache backend marker means this is the mini.
#   - a one-shot migration off the herdr-notes plugin, retired 2026-08-04. Its
#     prefix+e now runs scripts/brain-note.sh, which opens the pane's repo page
#     in the brain vault — a store that syncs, backs up and outlives a workspace
#     id. Nothing to install for that: it is a plain `popup` command, which is
#     also why the keybinding is no longer machine-dependent.
.PHONY: herdr-setup
herdr-setup:
	@command -v herdr >/dev/null 2>&1 || { echo "  ✗ herdr not installed — run: brew bundle install"; exit 1; }
	@herdr integration install claude
	@# Two different things, both needed. `integration install claude` writes the
	@# SessionStart hook that makes a pane report real agent state. This writes the
	@# agent SKILL.md that teaches Claude Code to DRIVE herdr — generated from the
	@# binary, never hand-written, so it can't go stale on a brew upgrade.
	@bash $(DOTFILES_DIR)/scripts/herdr-skill-sync.sh
	@$(MAKE) --no-print-directory _setup-settings
	@BACKEND=$$(tr -d '[:space:]' < "$(HOME)/.config/secrets/backend" 2>/dev/null || echo ""); \
	if [ "$$BACKEND" = "cache" ]; then \
		brew services start herdr >/dev/null 2>&1 || true; \
		echo "    ✓ herdr server registered (brew services — RunAtLoad + KeepAlive)"; \
	else \
		echo "    · thin client (backend=$${BACKEND:-unset}) — hook installed, server not started"; \
	fi
	@$(MAKE) --no-print-directory _herdr-supervise
	@# One-shot migration off herdr-notes (retired 2026-08-04). Idempotent and
	@# self-deleting: once the plugin is gone this is a single `plugin list` that
	@# prints nothing, exactly like the collie legacy-agent migration above it.
	@# Its notes are NOT migrated — they were per-workspace scratch in herdr's
	@# plugin state dir, and anything worth keeping was always meant to go to the
	@# vault. The state dir is left on disk rather than deleted; reading it back
	@# is `herdr plugin config-dir`'s sibling path, and destroying data on a
	@# `make setup` is not this target's call.
	@if command -v herdr >/dev/null 2>&1 && herdr plugin list --json 2>/dev/null | jq -e '.result.plugins[]? | select(.plugin_id=="herdr-notes")' >/dev/null 2>&1; then \
		herdr plugin uninstall herdr-notes >/dev/null 2>&1 \
			&& echo "    ✓ herdr-notes uninstalled (prefix+e now opens the vault project note)" \
			|| echo "    · herdr-notes uninstall failed — remove it with: herdr plugin uninstall herdr-notes"; \
	fi
	@# The replacement is a plain script, so the only thing to verify is that it
	@# is where the keybinding says it is. A popup that dies with "no such file"
	@# closes instantly and looks exactly like a dead keybinding.
	@if [ -x "$(DOTFILES_DIR)/scripts/brain-note.sh" ]; then \
		echo "    ✓ project note wired (prefix+e → brain vault Projects/<repo>.md)"; \
	else \
		echo "  ✗ scripts/brain-note.sh missing or not executable"; exit 1; \
	fi
	@# Pick up config/herdr/config.toml (linked by `make setup`) without dropping
	@# panes. Silent no-op when no server is running — the MacBook usually has none.
	@herdr config check
	@herdr server reload-config >/dev/null 2>&1 \
		&& echo "    ✓ config.toml reloaded into the running server" \
		|| echo "    · no running server to reload (config applies on next launch)"

# Converge herdr's brew-service plist so the server starts as a SESSION LEADER.
# Same shape, same trap and same reason as _colima-supervise: BREW REGENERATES
# THIS PLIST on every `brew services start/restart` and every `brew upgrade
# herdr`, silently — and it now regenerates it under a DIFFERENT NAME
# (`sh.brew.herdr.plist`, Homebrew 6), so the file is resolved by service name
# through scripts/lib/brew-service.sh rather than spelled.
#
# WHAT IT FIXES. Every `desk` launch asked "restart the remote server now?
# [y/N]" — and the only correct answer was N, forever, because y restarts the
# server outside brew services and kills every pane. herdr reports
# `detached_server_daemon` from `getsid(0) == getpid()`, and a launchd job is
# not a session leader (measured on the mini: pid 671, pgid 671, **sid 1**), so
# the remote client refuses to attach quietly. The warning is true as asked and
# false as meant: launchd owns the job and no ssh disconnect can reach it.
#
# The wrapper forks and calls setsid() in the child because setsid(2) fails
# with EPERM for a process-group leader, which is exactly what launchd hands
# over — full reasoning in herdr/herdr-server-start.py. Proven by A/B against
# an isolated server started in the launchd process shape:
# `detached_server_daemon` false without it, true with it.
#
# Deliberately does NOT restart the service, for a harder reason than colima's:
# restarting herdr does not bounce a VM, it DESTROYS every pane and every agent
# running in one. A `make setup` may never do that on its own.
.PHONY: _herdr-supervise
_herdr-supervise:
	@PLIST=$$($(BREW_SERVICE) plist herdr 2>/dev/null); \
	WRAP="$(DOTFILES_DIR)/herdr/herdr-server-start.py"; \
	if [ -z "$$PLIST" ]; then \
		if brew services info herdr --json 2>/dev/null | grep -q '"loaded": *true'; then \
			echo "  ✗ herdr is a LOADED brew service with NO plist under either name"; \
			echo "    looked for: $(LAUNCHAGENTS)/sh.brew.herdr.plist"; \
			echo "                $(LAUNCHAGENTS)/homebrew.mxcl.herdr.plist"; \
			echo "    The boot path cannot be converged, so it is DISARMED — never report this green."; \
			echo "    ↳ brew services info herdr --json"; \
			exit 1; \
		fi; \
		echo "    · herdr brew service not registered here — nothing to supervise"; \
	elif [ "$$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$$PLIST" 2>/dev/null)" = "$$WRAP" ] \
	  && [ "$$(/usr/libexec/PlistBuddy -c 'Print :KeepAlive' "$$PLIST" 2>/dev/null)" = "true" ]; then \
		echo "    · herdr session-leader boot path (ok)"; \
	else \
		chmod +x "$$WRAP"; \
		/usr/libexec/PlistBuddy -c 'Delete :KeepAlive' "$$PLIST" >/dev/null 2>&1 || true; \
		/usr/libexec/PlistBuddy -c 'Add :KeepAlive bool true' "$$PLIST" >/dev/null; \
		/usr/libexec/PlistBuddy -c 'Delete :ProgramArguments' "$$PLIST" >/dev/null 2>&1 || true; \
		/usr/libexec/PlistBuddy -c 'Add :ProgramArguments array' "$$PLIST" >/dev/null; \
		/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $$WRAP" "$$PLIST" >/dev/null; \
		plutil -lint "$$PLIST" >/dev/null || { echo "  ✗ herdr plist is malformed after edit"; exit 1; }; \
		echo "    ✓ herdr session-leader boot path pinned (no more desk [y/N] prompt)"; \
		echo "      ↳ active at the next boot, or now with: make herdr-restart (KILLS EVERY PANE)"; \
	fi

# The one command that applies a pinned boot path (or a herdr upgrade) to the
# RUNNING server. Separate from herdr-setup and loudly named because it is
# destructive in a way no other brew service here is: a herdr restart loses
# every process in every pane — see CLAUDE.md "a herdr crash restores the
# layout and loses every process running in it".
#
# NOT `brew services restart`, and not `launchctl kickstart -k`. Both would
# come back on the OLD job definition: brew REGENERATES the plist as part of
# restart (so the wrapper is stripped again on the way up), and kickstart
# restarts from launchd's CACHED definition without re-reading the file at all
# — the trap this repo already paid for with ai.hermes.gateway. Only
# bootout + bootstrap reloads the file, and bootstrap fails with `Input/output
# error` while the old job is still SIGTERMed, hence the wait loop.
.PHONY: herdr-status
herdr-status:
	@# Read-only sibling of colima-status: the server, the brew registration and
	@# the SUPERVISED boot path, which liveness alone cannot see (brew regenerates
	@# this plist on every upgrade/start/restart and nothing errors when it does —
	@# same silent-config-revert class as colima's).
	@herdr status --json 2>/dev/null | jq -r '"  server: v" + .server.version + " running=" + (.server.running|tostring) + " detached_server_daemon=" + (.server.capabilities.detached_server_daemon|tostring)' \
		|| echo "  ✗ herdr server not answering"
	@brew services list | grep -E '^herdr' || echo "  herdr service: not registered"
	@PLIST=$$($(BREW_SERVICE) plist herdr 2>/dev/null); \
	if [ -z "$$PLIST" ]; then \
		echo "  ✗ boot path UNRESOLVABLE — no sh.brew.herdr/homebrew.mxcl.herdr plist on disk"; \
	elif [ "$$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$$PLIST" 2>/dev/null)" = "$(DOTFILES_DIR)/herdr/herdr-server-start.py" ] \
	  && [ "$$(/usr/libexec/PlistBuddy -c 'Print :KeepAlive' "$$PLIST" 2>/dev/null)" = "true" ]; then \
		echo "  ✓ boot path supervised (bare KeepAlive + setsid wrapper) — $${PLIST##*/}"; \
	else \
		echo "  ✗ boot path NOT supervised — brew regenerated $${PLIST##*/}; run: make _herdr-supervise"; \
	fi

.PHONY: herdr-restart
herdr-restart:
	@if [ "$(YES)" != "1" ]; then \
		echo "  This KILLS every pane and every agent running in one."; \
		echo "  Check first:  rd agents"; \
		echo "  Then run:     make herdr-restart YES=1"; \
		exit 1; \
	fi
	@brew services start herdr >/dev/null 2>&1 || true
	@$(MAKE) --no-print-directory _herdr-supervise
	@PLIST=$$($(BREW_SERVICE) plist herdr 2>/dev/null); \
	TARGET=$$($(BREW_SERVICE) target herdr 2>/dev/null); \
	if [ -z "$$PLIST" ] || [ -z "$$TARGET" ]; then \
		echo "  ✗ no herdr plist under either name (sh.brew.herdr / homebrew.mxcl.herdr) — nothing to bootstrap"; \
		echo "    ↳ brew services info herdr --json"; exit 1; \
	fi; \
	U=$$(id -u); \
	launchctl bootout "$$TARGET" 2>/dev/null || true; \
	i=0; while launchctl print "$$TARGET" >/dev/null 2>&1; do \
		i=$$((i+1)); [ $$i -gt 30 ] && { echo "  ✗ old herdr job never went away"; exit 1; }; \
		sleep 0.5; \
	done; \
	launchctl bootstrap "gui/$$U" "$$PLIST" || { echo "  ✗ bootstrap failed"; exit 1; }
	@sleep 2
	@herdr status --json 2>/dev/null | jq -r '"  ✓ server v" + .server.version + " · detached_server_daemon=" + (.server.capabilities.detached_server_daemon|tostring) + " (false still prompts on desk)"' \
		|| echo "  ! could not read herdr status"

# Collie — phone web-UI control surface for the herd (herdr plugin + Bun
# bridge). See CLAUDE.md "Collie — the phone control surface" for the full
# model: what it is, the ACL gate, why COLLIE_SKIP_SERVE=1 is mandatory here.
# Opt-in per machine, NOT in the default `setup` chain — same policy as
# remote-access/devhost-health-setup/batt-setup. Gated on the dev-host marker
# (same signal herdr-setup and git-headless use) because Collie only makes
# sense pointed at the mini's herdr server.
.PHONY: collie-setup collie-upgrade collie-status collie-teardown
# The other half of `make drift-check`. That one NOTICES a drifted pin and
# deliberately never applies it; this applies one, with the review kept and the
# mechanical steps gone — resolve the newest tag, show the changelog + diffstat
# + a scope verdict (did anything outside web/ move?), then on your `y` bump the
# pin, reinstall, assert, and commit. Rolls the pin back if collie-setup's
# rebind-guard assertion fails. No `-dry` sibling on purpose: the prompt IS the
# preview, and a second "same thing but more thorough" target is the choice this
# repo's makefile-conventions rule exists to avoid.
collie-upgrade:
	@bash $(DOTFILES_DIR)/scripts/collie-upgrade.sh

collie-setup:
	@BACKEND=$$(tr -d '[:space:]' < "$(HOME)/.config/secrets/backend" 2>/dev/null || echo ""); \
	if [ "$$BACKEND" != "cache" ]; then \
		echo "    · not the dev host (backend=$${BACKEND:-unset}) — collie-setup skipped"; \
		exit 0; \
	fi
	@command -v herdr >/dev/null 2>&1 || { echo "  ✗ herdr not installed — run: brew bundle install"; exit 1; }
	@command -v bun >/dev/null 2>&1 || { echo "  ✗ bun not installed — run: brew bundle install"; exit 1; }
	@# Install/refresh only when the pin moved: `plugin install` re-clones and
	@# rebuilds every time.
	@if [ "$$(herdr plugin list --json 2>/dev/null | jq -r '.result.plugins[]? | select(.plugin_id=="herdr.collie") | .source.resolved_commit')" = "$(COLLIE_REF)" ]; then \
		echo "    ✓ collie $(COLLIE_VERSION) plugin installed"; \
	else \
		echo "    → installing collie $(COLLIE_VERSION) ($(COLLIE_REF))"; \
		herdr plugin install $(COLLIE_SOURCE) --ref $(COLLIE_REF) -y >/dev/null \
			&& echo "    ✓ collie $(COLLIE_VERSION) installed" \
			|| { echo "  ✗ collie plugin install failed"; exit 1; }; \
	fi
	@# Upstream owns supervision as of collie 0.21.0: `collie-ctl.sh start` writes
	@# ~/Library/LaunchAgents/herdr.collie.plist itself. This repo carried its own
	@# com.jkrumm.collie.plist for exactly as long as macOS launchd support was
	@# missing upstream; keeping both now would mean two RunAtLoad+KeepAlive agents
	@# racing for port 8787, so the block below boots the old one out FIRST.
	@# Upstream's `start` clears only the pidfile tier — it has never heard of our
	@# label and cannot free the port for us.
	@#
	@# The one property that made ours worth carrying is preserved upstream: the
	@# plist execs `collie-ctl.sh _exec-bridge`, and the script sources the .env at
	@# top level (`set -a; . "$$CONFIG_DIR/.env"; set +a`), so the four hardening
	@# vars do reach the process. Asserted behaviourally below, never assumed — a
	@# bridge started without the .env answers 200 exactly the same.
	@#
	@# Comments must stay OUT of the block: make joins backslash-continued lines
	@# before handing them to sh, so a `#` inside would swallow the rest.
	@PLUGIN_ROOT=$$(herdr plugin list --json 2>/dev/null | jq -r '.result.plugins[]? | select(.plugin_id=="herdr.collie") | .plugin_root'); \
	[ -n "$$PLUGIN_ROOT" ] || { echo "  ✗ could not resolve herdr.collie plugin_root"; exit 1; }; \
	CONFIG_DIR=$$(herdr plugin config-dir herdr.collie 2>/dev/null); \
	[ -n "$$CONFIG_DIR" ] || CONFIG_DIR="$(HOME)/.config/herdr/plugins/config/herdr.collie"; \
	[ -f "$$CONFIG_DIR/.env" ] || { echo "  ✗ no .env at $$CONFIG_DIR — write it by hand first (see CLAUDE.md)"; exit 1; }; \
	LEGACY="$(LAUNCHAGENTS)/com.jkrumm.collie.plist"; \
	if [ -f "$$LEGACY" ]; then \
		launchctl bootout gui/$$(id -u)/com.jkrumm.collie 2>/dev/null \
			|| launchctl unload "$$LEGACY" 2>/dev/null || true; \
		rm -f "$$LEGACY"; \
		echo "    ✓ legacy com.jkrumm.collie booted out + removed (upstream supervises now)"; \
	fi; \
	bash "$$PLUGIN_ROOT/scripts/collie-ctl.sh" start || { echo "  ✗ collie-ctl.sh start failed"; exit 1; }; \
	if [ "$$(curl -s -o /dev/null -w '%{http_code}' --retry 5 --retry-delay 1 --retry-connrefused --max-time 20 http://127.0.0.1:8787/ 2>/dev/null)" != "200" ]; then \
		echo "  ✗ bridge is not answering on 127.0.0.1:8787"; \
		echo "    check: launchctl list | grep collie   and   $$CONFIG_DIR/collie.log"; \
		exit 1; \
	fi; \
	if [ "$$(curl -s -H 'Host: evil.example.com' -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8787/api/snapshot 2>/dev/null)" != "403" ]; then \
		echo "  ✗ spoofed Host NOT rejected on /api/snapshot — the .env did not reach the process"; \
		echo "    every hardening setting is silently off; do not leave the front door published"; \
		exit 1; \
	fi; \
	echo "    ✓ bridge up, DNS-rebinding guard in effect (spoofed Host → 403)"; \
	if [ -f "$(LAUNCHAGENTS)/herdr.collie.plist" ] \
		&& launchctl list 2>/dev/null | awk '$$3=="herdr.collie"{f=1} END{exit !f}'; then \
		echo "    ✓ supervised by launchd (RunAtLoad + KeepAlive — survives reboot)"; \
	else \
		echo "  ✗ running UNSUPERVISED (no gui/<uid> to bootstrap into) — dies on reboot"; \
		echo "    log in at the console once, then re-run: make collie-setup"; \
		exit 1; \
	fi
	@echo "    ↳ Front door is declared state, not this target: the tailnet binding is"
	@echo "      a row in dotfiles-private/tailscale-serve.mini.conf, applied by"
	@echo "      'make tailscale-serve'. URL: https://mini.<tailnet>.ts.net"
	@echo "    ↳ The phone additionally needs an ACL grant (tag:phone → tcp:8788),"
	@echo "      applied from the MacBook only — see dotfiles-private's tailscale-acl.jsonc"
	@echo "      + 'make tailscale-acl-diff/push'."

# Read-only. `tailscale` is an alias to the app bundle in interactive shells,
# not in make — call it by absolute path (same trap devhost-health-check.sh hit).
collie-status:
	@echo "  LaunchAgent:"
	@ROW=$$(launchctl list 2>/dev/null | awk '$$3=="herdr.collie" {print $$1" "$$2}'); \
	if [ -z "$$ROW" ]; then \
		echo "    ✗ not loaded — run: make collie-setup"; \
	else \
		set -- $$ROW; \
		if [ "$$1" = "-" ]; then \
			echo "    ✗ loaded but NOT running (last exit $$2) — check $(HOME)/.config/herdr/plugins/config/herdr.collie/collie.log"; \
		else \
			echo "    ✓ loaded and running (pid $$1, last exit $$2)"; \
		fi; \
	fi
	@echo "  Bridge health (http://127.0.0.1:8787):"
	@CODE=$$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:8787/ 2>/dev/null || echo "000"); \
	if [ "$$CODE" = "000" ]; then echo "    ✗ unreachable"; else echo "    ✓ HTTP $$CODE"; fi
	@# Behavioural, not configural: proves COLLIE_PUBLIC_HOSTS actually reached the
	@# process. A bridge started without its .env silently drops every hardening
	@# setting and still answers 200 on the line above. The path matters as much as
	@# the header — `/` serves the SPA shell to any Host and always answers 200, so
	@# probing it reports a perfectly healthy guard as broken.
	@echo "  DNS-rebinding guard (spoofed Host must be rejected):"
	@CODE=$$(curl -s -H "Host: evil.example.com" -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:8787/api/snapshot 2>/dev/null || echo "000"); \
	if [ "$$CODE" = "403" ]; then echo "    ✓ 403 — COLLIE_PUBLIC_HOSTS in effect"; \
	else echo "    ✗ got $$CODE, expected 403 — the .env did not reach the process"; fi
	@echo "  tailscale serve:"
	@# CLI resolved, not hardcoded: the mini runs the brew daemon since
	@# 2026-08-06 and the app bundle there answers from a dormant daemon.
	@TS=$$(bash -c 'source $(DOTFILES_DIR)/scripts/lib/tailscale-cli.sh; echo "$$TAILSCALE_BIN $${TAILSCALE_SOCKET:+--socket=$$TAILSCALE_SOCKET}"'); \
	$$TS serve status 2>/dev/null | sed 's/^/    /' || echo "    · tailscale not reachable"

	@# Deliberately NOT `collie-ctl.sh uninstall`: that always attempts a tailscale
	@# serve teardown, even under COLLIE_SKIP_SERVE=1. Serve is declared state in
	@# this repo (dotfiles-private/tailscale-serve.mini.conf) and no upstream script
	@# gets to mutate it. Booting the agent out by label does the same job locally.
collie-teardown:
	@for L in herdr.collie com.jkrumm.collie; do \
		DST="$(LAUNCHAGENTS)/$$L.plist"; \
		[ -f "$$DST" ] || continue; \
		launchctl bootout gui/$$(id -u)/$$L 2>/dev/null \
			|| launchctl unload "$$DST" 2>/dev/null || true; \
		rm -f "$$DST"; \
		echo "  ✓ $$L LaunchAgent unloaded + removed"; \
	done
	@if command -v herdr >/dev/null 2>&1 && herdr plugin list --json 2>/dev/null | jq -e '.result.plugins[]? | select(.plugin_id=="herdr.collie")' >/dev/null 2>&1; then \
		herdr plugin uninstall herdr.collie >/dev/null 2>&1 \
			&& echo "  ✓ herdr.collie plugin uninstalled" \
			|| echo "  ✗ herdr plugin uninstall failed"; \
	else \
		echo "  · herdr.collie plugin not installed"; \
	fi
	@echo "  · dotfiles-private/tailscale-serve.mini.conf left untouched — that is"
	@echo "    declared state, not this target's to change."

# The look: one command, both machines. Three programs paint one screen and none
# of them can see the other two — the terminal paints pane content from its ANSI
# palette, herdr paints its own chrome, starship paints the prompt inside that.
# Applying the theme therefore means touching all three, and forgetting one is
# how they drift apart. `make theme` is the canonical verb for that; it is a
# subset of `make setup` and safe to run repeatedly on either machine.
#
# Deliberately NOT split into apply/reload variants — a theme change you cannot
# see is indistinguishable from one that did not apply, so the reload is part of
# applying it. Terminates: no watchers, no tailing.
.PHONY: theme
theme:
	@echo ""
	@echo "  Applying One Zinc (terminal) + One Dark/One Light (herdr chrome)"
	@echo ""
	@$(MAKE) --no-print-directory _setup-ghostty
	@# herdr's config.toml is symlinked, so the file is already current — this
	@# only needs to push it into a running server.
	@mkdir -p $(HOME)/.config/herdr
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/config/herdr/config.toml" \
		DST="$(HOME)/.config/herdr/config.toml"
	@if command -v herdr >/dev/null 2>&1; then \
		herdr config check || exit 1; \
		herdr server reload-config >/dev/null 2>&1 \
			&& echo "    ✓ herdr reloaded live (panes kept)" \
			|| echo "    · no running herdr server (applies on next launch)"; \
	else \
		echo "    · herdr not installed here — skipped"; \
	fi
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/config/starship.toml" \
		DST="$(HOME)/.config/starship.toml"
	@# Assert rather than trust: ghostty validates its own config, but it does
	@# NOT validate theme VALUES — a bad hex silently falls back to defaults. So
	@# check the files the config actually names are present and non-empty.
	@for t in one-zinc-dark one-zinc-light; do \
		f="$(HOME)/.config/ghostty/themes/$$t"; \
		[ -s "$$f" ] || { echo "  ✗ theme $$t missing or empty at $$f"; exit 1; }; \
	done
	@# Resolve a ghostty binary rather than trusting PATH. The ghostty CASK ships
	@# no binary (app bundle + manpages + completions only), so `which ghostty`
	@# resolves nothing on a fresh machine. Prefer the standalone app, fall back
	@# to PATH (e.g. a Homebrew formula install of ghostty).
	@GB="/Applications/Ghostty.app/Contents/MacOS/ghostty"; \
	[ -x "$$GB" ] || GB="$$(command -v ghostty 2>/dev/null)"; \
	if [ -n "$$GB" ] && [ -x "$$GB" ]; then \
		"$$GB" +validate-config --config-file="$(HOME)/.config/ghostty/config" >/dev/null || exit 1; \
		echo "    ✓ ghostty config valid ($$GB)"; \
	else \
		echo "    · no ghostty binary found — config not validated"; \
	fi
	@echo ""
	@echo "  Done. Reload Ghostty to pick up the terminal palette."
	@echo ""

# Remote-dev readiness heartbeat (herdr + sshd + tailscaled) pushed to
# Uptime Kuma every 5 minutes. Opt-in per machine like `remote-access` — this
# belongs on the dev host (the mini), not on a laptop that is meant to be
# closed half the day and would just page about itself.
DEVHOST_PUSH_URL_FILE ?= $(HOME)/.config/uptime-kuma/devhost-push-url
.PHONY: devhost-health-setup devhost-health-teardown devhost-health-check
devhost-health-setup:
	@# Assert the push URL exists rather than installing an agent that can only
	@# fail: the Kuma monitor has to exist first so it can hand out a push token.
	@if [ ! -r "$(DEVHOST_PUSH_URL_FILE)" ]; then \
		echo "  ✗ no push URL at $(DEVHOST_PUSH_URL_FILE)"; \
		echo "    1. Declare the monitor in homelab/uptime-kuma/monitors.yaml"; \
		echo "       (group 'Local', interval 600, maxretries 0), then from"; \
		echo "       ~/SourceRoot/homelab run: make uk-sync"; \
		echo "       600s must exceed the agent's 300s cadence so one skipped"; \
		echo "       run does not page; maxretries 0 keeps time-to-DOWN at 10min."; \
		echo "    2. mkdir -p $(dir $(DEVHOST_PUSH_URL_FILE))"; \
		echo "    3. Read the monitor's pushToken back off the Kuma API and write"; \
		echo "       <base>/api/push/<token> to $(DEVHOST_PUSH_URL_FILE), chmod 600."; \
		echo "       Print the token alone — 'op run' masks secret values in its"; \
		echo "       own stdout, so a full URL comes back partly concealed."; \
		echo "    4. Re-run: make devhost-health-setup"; \
		exit 1; \
	fi
	@# Secure the token or refuse. Ignoring a failed chmod would let the agent go
	@# live with a group/world-readable push URL — anyone local could then forge
	@# healthy heartbeats and mask a real outage, which is worse than no monitor.
	@if [ ! -f "$(DEVHOST_PUSH_URL_FILE)" ]; then \
		echo "  ✗ $(DEVHOST_PUSH_URL_FILE) is not a regular file — refusing"; exit 1; \
	fi
	@chmod 600 "$(DEVHOST_PUSH_URL_FILE)" || { \
		echo "  ✗ cannot chmod 600 $(DEVHOST_PUSH_URL_FILE) — refusing to install a forgeable heartbeat"; exit 1; }
	@PERMS=$$(stat -f '%Lp' "$(DEVHOST_PUSH_URL_FILE)"); \
	if [ "$$PERMS" != "600" ]; then \
		echo "  ✗ $(DEVHOST_PUSH_URL_FILE) is mode $$PERMS, expected 600 — refusing"; exit 1; \
	fi
	@mkdir -p "$(LAUNCHAGENTS)"
	@$(MAKE) --no-print-directory _render-plists PLISTS="com.jkrumm.devhost-health" PLIST_DIR="$(DOTFILES_DIR)/scripts"
	@echo "    ↳ every 5 min → push herdr/sshd/tailscale readiness to Uptime Kuma"
devhost-health-teardown:
	@PLIST="$(LAUNCHAGENTS)/com.jkrumm.devhost-health.plist"; \
	launchctl unload "$$PLIST" 2>/dev/null || true; \
	rm -f "$$PLIST"; \
	echo "  ✓ devhost-health torn down (unloaded + plist removed)"
devhost-health-check:
	@bash $(DOTFILES_DIR)/scripts/devhost-health-check.sh

# human-queue — the async present-human channel from the mini. An agent there
# enqueues with `ask-human.sh`; these two targets are the MacBook-side drain,
# run by a human, never by a poller (see scripts/human-queue.sh's header for
# why: the ssh hop rides the per-use biometric 1Password SSH agent, and a
# LaunchAgent draining it would fire Touch ID on its own schedule). No setup/
# teardown pair here on purpose — there is nothing to install.
.PHONY: human-queue human-queue-count
human-queue:
	@bash $(DOTFILES_DIR)/scripts/human-queue.sh list
human-queue-count:
	@bash $(DOTFILES_DIR)/scripts/human-queue.sh count

# ----------------------------------------------------------------------------
# Drift check (dev host only)
#
# Reports what has fallen behind upstream — the commit-pinned herdr plugins, the
# xcaddy/caddy-dns modules built into caddy, brew-upgrade recency, pending macOS
# updates. It NEVER upgrades anything; the full argument for that restraint is
# scripts/drift-check.sh's header, and it is the same one that keeps the runaway
# reaper report-only.
#
# Its OWN scheduler, unlike collie and secrets-freshness which ride the 300s
# devhost-health agent: every check here is a network call, and that agent runs
# with maxretries 0 and deliberately refuses to touch GitHub so a provider
# outage cannot page as "dev host down". Drift moves in days, so: daily.
# ----------------------------------------------------------------------------
DRIFT_PUSH_URL_FILE ?= $(HOME)/.config/uptime-kuma/drift-push-url
.PHONY: drift-check-setup drift-check-teardown

# ----------------------------------------------------------------------------
# The applier for the one drift item drift-check cannot clear on its own. Paired
# with it exactly like collie-upgrade: notice unattended, apply attended — this
# needs a TTY (or YES=1), reboots the dev host, and asserts the version actually
# moved. The procedure is not obvious: `softwareupdate -R` prints "Restarting..."
# and returns without restarting, and forcing a reboot there boots the OLD OS
# with every artifact still looking armed. See the script header.
# ----------------------------------------------------------------------------
.PHONY: mini-macos-update
mini-macos-update:
	@bash $(DOTFILES_DIR)/scripts/mini-macos-update.sh

drift-check-setup:
	@BACKEND=$$(tr -d '[:space:]' < "$(HOME)/.config/secrets/backend" 2>/dev/null || echo ""); \
	if [ "$$BACKEND" != "cache" ]; then \
		echo "    · not the dev host (backend=$${BACKEND:-unset}) — drift-check-setup skipped"; \
		exit 0; \
	fi
	@# The monitor is OPTIONAL here, unlike devhost-health-setup which refuses
	@# without one. Drift is a report a human reads; the agent is useful on a
	@# machine with no Kuma wiring at all, and drift-check.sh skips the push
	@# silently when the URL file is absent (same contract as collie/secrets).
	@if [ -f "$(DRIFT_PUSH_URL_FILE)" ]; then \
		chmod 600 "$(DRIFT_PUSH_URL_FILE)" || { \
			echo "  ✗ cannot chmod 600 $(DRIFT_PUSH_URL_FILE) — refusing to install a forgeable heartbeat"; exit 1; }; \
		echo "    ✓ push URL present (monitor: MacMini Drift - Push)"; \
	else \
		echo "    · no push URL at $(DRIFT_PUSH_URL_FILE) — installing report-only"; \
		echo "      to wire the monitor: declare it in homelab/uptime-kuma/monitors.yaml"; \
		echo "      (group 'Local', interval 172800, maxretries 0 — 2d must exceed the"; \
		echo "      agent's daily cadence), make uk-sync, then write <base>/api/push/<token>"; \
		echo "      to that path, chmod 600."; \
	fi
	@# Seed the brew-upgrade stamp to NOW rather than leaving it absent. Without
	@# this, installing the agent immediately starts a 30-day clock from "never
	@# run" on a machine that has in fact run it — and a monitor whose first act
	@# is to report a fault it invented is one you learn to disbelieve. Same
	@# reasoning as opbackup-setup backdating its stamp off the newest remote
	@# backup. Only ever seeds; an existing stamp is left alone.
	@STAMP="$(HOME)/.local/state/brew-upgrade/last-success"; \
	if [ ! -f "$$STAMP" ]; then \
		mkdir -p "$$(dirname "$$STAMP")" && : > "$$STAMP" \
			&& echo "    ✓ brew-upgrade stamp seeded (clock starts now, not at 'never')"; \
	fi
	@mkdir -p "$(LAUNCHAGENTS)"
	@$(MAKE) --no-print-directory _render-plists PLISTS="com.jkrumm.drift-check" PLIST_DIR="$(DOTFILES_DIR)/drift"
	@echo "    ↳ daily 09:40 → report pin/brew/macOS drift (reports only, never upgrades)"

drift-check-teardown:
	@PLIST="$(LAUNCHAGENTS)/com.jkrumm.drift-check.plist"; \
	launchctl unload "$$PLIST" 2>/dev/null || true; \
	rm -f "$$PLIST"; \
	echo "  ✓ drift-check torn down (unloaded + plist removed)"

# ----------------------------------------------------------------------------
# Lock at boot (dev host only)
#
# FileVault OFF + automatic login is what lets the mini reboot itself after a
# power cut with the login keychain unlocked (Claude Code's Max credential lives
# there and is only reachable from a GUI-session process). The cost is that a
# fresh boot lands on an unlocked desktop. This agent locks it immediately.
#
# Two halves, and the agent alone is useless: `sysadminctl -screenLock immediate`
# removes the grace period, the agent fires the screen-off. The setup target
# refuses to install unless the first half is already in place, because a plist
# that silently sleeps the display and leaves the machine unlocked is worse than
# no plist — it reads as done.
#
# Read the honest scope in docs/remote-dev.md: this stops someone walking up and
# using the desktop. It does NOT stop Mac Sharing Mode, which is a FileVault
# question, not a lock-screen one.
# ----------------------------------------------------------------------------
.PHONY: lock-at-boot-setup lock-at-boot-teardown lock-at-boot-check
lock-at-boot-setup:
	@BACKEND=$$(tr -d '[:space:]' < "$(HOME)/.config/secrets/backend" 2>/dev/null || echo ""); \
	if [ "$$BACKEND" != "cache" ]; then \
		echo "    · not the dev host (backend=$${BACKEND:-unset}) — lock-at-boot skipped"; \
	elif ! sysadminctl -autologin status 2>&1 | grep -q 'Automatic login user'; then \
		echo "    · automatic login is off — nothing to lock at boot, skipped"; \
	else \
		LOCK=$$(sysadminctl -screenLock status 2>&1 | sed 's/.*] //'); \
		case "$$LOCK" in \
		  *immediate*|*"delay is 0 "*) ;; \
		  *) echo "  ✗ screen lock is not immediate — refusing to install"; \
		     echo "      $$LOCK"; \
		     echo "    The agent only sleeps the display; the lock comes from this"; \
		     echo "    setting. Without it the machine still boots into an unlocked"; \
		     echo "    desktop for the configured delay, while looking configured."; \
		     echo "    Fix it, then re-run this target."; \
		     echo ""; \
		     echo "    PREFERRED — no password on any command line:"; \
		     echo "      System Settings > Lock Screen > require password after"; \
		     echo "      screensaver/display off -> Immediately"; \
		     echo "      (Systemeinstellungen > Sperrbildschirm -> 'Sofort')"; \
		     echo ""; \
		     echo "    CLI form, if you prefer it. NOTE sysadminctl does NOT prompt —"; \
		     echo "    unlike -autologin it has no interactive form, so the password"; \
		     echo "    must be inline. histignorespace is OFF on this machine, so a"; \
		     echo "    leading space does NOT keep it out of ~/.zsh_history — enable"; \
		     echo "    it for the current shell first:"; \
		     echo "      setopt histignorespace"; \
		     echo "       sysadminctl -screenLock immediate -password 'YOUR-PASSWORD'"; \
		     echo "    (the argv exposure itself is moot here — that same password"; \
		     echo "     already sits in /etc/kcpassword by design)"; \
		     echo ""; \
		     echo "    Then: make lock-at-boot-setup"; \
		     exit 1;; \
		esac; \
		mkdir -p "$(LAUNCHAGENTS)" "$(HOME)/Library/Logs"; \
		$(MAKE) --no-print-directory _render-plists \
			PLISTS="com.jkrumm.lock-at-boot" PLIST_DIR="$(DOTFILES_DIR)/scripts"; \
		echo "    ↳ auto-login lands on a lock screen; session + keychain stay up"; \
	fi
lock-at-boot-teardown:
	@PLIST="$(LAUNCHAGENTS)/com.jkrumm.lock-at-boot.plist"; \
	launchctl unload "$$PLIST" 2>/dev/null || true; \
	rm -f "$$PLIST"; \
	echo "  ✓ lock-at-boot torn down (screenLock setting left alone — it is not this target's state)"
lock-at-boot-check:
	@echo "  filevault  : $$(fdesetup status 2>&1)"
	@echo "  autologin  : $$(sysadminctl -autologin status 2>&1 | sed 's/.*] //')"
	@echo "  autorestart: $$(pmset -g custom 2>/dev/null | awk '/^ *autorestart /{print $$2}' | head -1) (1 = powers itself on after a power cut)"
	@echo "  screenLock : $$(sysadminctl -screenLock status 2>&1 | sed 's/.*] //')"
	@if [ -f "$(LAUNCHAGENTS)/com.jkrumm.lock-at-boot.plist" ]; then \
		echo "  agent      : installed"; \
	else \
		echo "  agent      : NOT installed"; \
	fi
	@if ioreg -n Root -d1 -a 2>/dev/null | grep -q CGSSessionScreenIsLocked; then \
		echo "  screen     : LOCKED"; \
	else \
		echo "  screen     : unlocked"; \
	fi
	@echo "  keychain   : $$(security show-keychain-info "$(HOME)/Library/Keychains/login.keychain-db" 2>&1 | sed 's/.*db" //')"
	@echo "  last run   : $$(tail -1 "$(HOME)/Library/Logs/lock-at-boot.log" 2>/dev/null || echo '(no log yet — has not booted since install)')"

# ============================================================================
# Help
# ============================================================================

.PHONY: help
help:
	@echo ""
	@echo "  dotfiles"
	@echo ""
	@echo "  make setup              Idempotent full setup — symlinks, secrets, settings, browser"
	@echo "  make clean              Purge brew/npm/pnpm/bun caches"
	@echo "  make status             Verify symlink health + Keychain secrets"
	@echo "  make github-config      Apply branch protection + merge settings + shared secrets to all repos"
	@echo "  make github-config-dry  Preview without applying"
	@echo ""
	@echo "  make brew-check         Verify the machine matches the Brewfile (read-only)"
	@echo "  make brew-diff          List installed packages not declared in the Brewfile (dry-run)"
	@echo "  make brew-dump          Regenerate the Brewfile from the machine — then review the git diff"
	@echo "  make brew-upgrade       Upgrade outdated homebrew/core formulae (skips pinned caddy + casks + third-party taps, then asserts the invariants)"
	@echo "  make brew-upgrade-dry   Preview without upgrading"
	@echo ""
	@echo "  make colima-start    Start the Docker runtime service (auto-starts at login)"
	@echo "  make colima-stop     Stop the Docker runtime service"
	@echo "  make colima-restart  Apply COLIMA_CPU/MEMORY, converge the plist, bootout+bootstrap (restarts the VM)"
	@echo "  make colima-status   Show service + VM status"
	@echo "  make orbstack-remove Uninstall OrbStack after migrating to Colima (guarded; FORCE=1 to override)"
	@echo ""
	@echo "  make batt-setup       MacBook-only: start the charge-limiter daemon + cap at 80% (LIMIT=N)"
	@echo "  make batt-limit       Change the cap, e.g. make batt-limit LIMIT=100 (full charge before travel)"
	@echo "                        Add DAYS=N to also pause the daily 80% auto-reset for N days"
	@echo "  make batt-status      Show the battery charge-limiter status"
	@echo ""
	@echo "  make brain-sync-setup         Load the 5-minute brain vault sync through GitHub (role auto-detected)"
	@echo "  make brain-sync-teardown      Unload + remove the brain-sync LaunchAgent"
	@echo "  make brain-backup-setup       Load the nightly (03:30) brain vault leftover-dirt sweep"
	@echo "  make brain-backup-teardown    Unload + remove the brain-backup LaunchAgent"
	@echo "  make brain-web-refresh-setup      Load the 5-minute brain-web content refresh (rebuilds dist/ when the vault's HEAD moves)"
	@echo "  make brain-web-refresh-teardown   Unload + remove the brain-web-refresh LaunchAgent"
	@echo ""
	@echo "  make secrets-seed           Seed the SOPS+age cache from 1Password (reads dotfiles-private/headless.refs)"
	@echo "  make secrets-backend-cache  One-time: mark this machine as the headless cache backend (mini only)"
	@echo "  make secrets-freshness-setup    Load the weekly secrets-cache staleness heartbeat (Mon 09:15)"
	@echo "  make secrets-freshness-check    Run the staleness check once on demand (for testing)"
	@echo "  make opbackup-setup             Auto-trigger the 1Password vault backup (MacBook; hourly, guarded)"
	@echo "  make opbackup-check             Run the guard once — prints which precondition stopped it (FORCE=1 to run)"
	@echo "  make opbackup-teardown          Remove the auto-trigger (stamps kept)"
	@echo ""
	@echo "  Remote dev"
	@echo "  make authorized-keys            Install trusted SSH keys only — no sudo, no sshd/sharing changes (safe on the IU MacBook)"
	@echo "  make theme                      Apply the look (terminal + herdr + prompt) and reload live — run on BOTH machines"
	@echo "  make herdr-setup                Claude agent-state hook + project-note keybinding (+ server on the dev host)"
	@echo "  make herdr-status               Server + brew registration + supervised boot path (read-only)"
	@echo "  make devhost-health-setup       Load the 5-min herdr/sshd/tailscale heartbeat → Uptime Kuma"
	@echo "  make devhost-health-check       Run the readiness check once on demand (for testing)"
	@echo "  make devhost-health-teardown    Unload + remove the heartbeat agent"
	@echo "  make human-queue                MacBook: list the mini's pending present-human requests"
	@echo "  make human-queue-count          MacBook: print just the pending count (fast; used by the SessionStart hook)"
	@echo "  make log-rotate-setup           Load the hourly copytruncate rotation for this repo's LaunchAgent logs"
	@echo "  make log-rotate-check           Run the rotation once on demand (for testing)"
	@echo "  make log-rotate-teardown        Unload + remove the rotation agent"
	@echo "  make obsidian-autostart         Dev-host only: start Obsidian at login (agent door for /brain + Hermes)"
	@echo "  make lock-at-boot-setup         Dev-host only: lock the screen right after the unattended auto-login"
	@echo "  make lock-at-boot-check         Show FileVault / autologin / autorestart / screenLock / lock state"
	@echo "  make lock-at-boot-teardown      Unload + remove the lock-at-boot agent"
	@echo ""
	@echo "  make caddy-dns-build            Dev-host only: build Caddy w/ Cloudflare DNS module (needed for the clean https://<app>.\$$DEV_DOMAIN door; re-run after any brew upgrade of caddy)"
	@echo "  make caddy-boot-order           NEEDS SUDO: order the caddy daemon behind the tailnet address it binds (re-run after any brew upgrade of caddy)"
	@echo ""
	@echo "  make collie-setup       Dev-host only: install the phone control-surface bridge as a LaunchAgent"
	@echo "  make collie-upgrade     Dev-host only: show the newest release (changelog, diffstat, scope), apply on y"
	@echo "  make collie-status      Show LaunchAgent + bridge + tailscale serve state (read-only)"
	@echo "  make collie-teardown    Unload the LaunchAgent + uninstall the plugin (leaves serve config untouched)"
	@echo ""
	@echo "  make tailscale-serve        Apply this machine's declared serve/funnel bindings"
	@echo "  make tailscale-serve-check  Report drift between declared and live bindings"
	@echo ""
	@echo "  make tailscale-acl-diff     Diff live tailnet ACL vs dotfiles-private (ALWAYS run first)"
	@echo "  make tailscale-acl-pull     Fetch live ACL into dotfiles-private (normalises formatting)"
	@echo "  make tailscale-acl-push     Validate + apply the ACL to the whole tailnet"
	@echo ""
	@echo "  make doctor                 Read-only health of this machine (+ the mini when run from the MacBook)"
	@echo "  make agent-dispatch-smoke   Dispatch a trivial read-only task at dispatch-scratch and assert it returns"
	@echo "  make mini-macos-update      MacBook-only: apply the mini's pending macOS update, then assert the version moved (YES=1 skips the prompt)"
	@echo ""
	@echo "  usage-tracker (token/cost telemetry) is installed by make setup."
	@echo "  Manage it in ~/SourceRoot/usage-tracker — make stats / sources / logs."
	@echo ""
	@echo "  Hermes Agent setup lives in ~/SourceRoot/hermes-agent — run make setup there."
	@echo ""

.DEFAULT_GOAL := help
