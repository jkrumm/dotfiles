DOTFILES_DIR := $(shell pwd)
CLAUDE_DIR   := $(HOME)/.claude
SOURCEROOT   := $(HOME)/SourceRoot
BREW_PREFIX  := $(shell brew --prefix 2>/dev/null || echo /opt/homebrew)

# Colima (Docker runtime VM — replaces OrbStack/Docker Desktop).
# These are ceilings (not reservations): idle VM holds ~1.3GB regardless;
# CPU is time-shared (free when idle). Bump for heavy stacks like clickstack:
#   COLIMA_MEMORY=10 make colima-restart
COLIMA_CPU    ?= 4
COLIMA_MEMORY ?= 8
COLIMA_DISK   ?= 60

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
	@$(MAKE) --no-print-directory _setup-skills
	@$(MAKE) --no-print-directory _setup-settings
	@$(MAKE) --no-print-directory _setup-gitignore
	@$(MAKE) --no-print-directory _setup-ghostty
	@$(MAKE) --no-print-directory _setup-tools
	@$(MAKE) --no-print-directory _setup-caddy
	@$(MAKE) --no-print-directory _setup-browser
	@$(MAKE) --no-print-directory _setup-sideclaw-mcp
	@$(MAKE) --no-print-directory _setup-pnpm
	@$(MAKE) --no-print-directory _setup-viteplus
	@$(MAKE) --no-print-directory _setup-op-token
	@$(MAKE) --no-print-directory _setup-sdk-keys
	@$(MAKE) --no-print-directory _setup-ssh
	@$(MAKE) --no-print-directory _setup-rules
	@$(MAKE) --no-print-directory _setup-opencode
	@# _setup-localai RETIRED 2026-05-25 — local TTS/STT replaced by the cloud
	@# audio-proxy (~/SourceRoot/audio-proxy, :7716). Targets kept below for an
	@# easy re-add; tear down a live install with `make localai-teardown`.
	@$(MAKE) --no-print-directory _setup-litellm
	@$(MAKE) --no-print-directory _setup-usage-tracker
	@$(MAKE) --no-print-directory _setup-audio-proxy
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
	@# Clean up legacy Caddyfile.localai.conf from older Tailscale-fronted setup
	@LEGACY="$(BREW_PREFIX)/etc/Caddyfile.localai.conf"; \
	if [ -f "$$LEGACY" ]; then \
		rm "$$LEGACY" && echo "    ✓ removed legacy Caddyfile.localai.conf"; \
	fi
	@# Clean up any root-owned Caddy data left in user Library from earlier failed runs
	@CADDY_LIB="$(HOME)/Library/Application Support/Caddy"; \
	if [ -d "$$CADDY_LIB" ] && [ "$$(stat -f %Su "$$CADDY_LIB" 2>/dev/null)" = "root" ]; then \
		sudo rm -rf "$$CADDY_LIB" && echo "    ✓ removed stale root-owned Caddy data"; \
	fi
	@# Start Caddy as LaunchDaemon (root — required for port 443)
	@# LaunchDaemon plist sets HOME=/opt/homebrew/var/lib so CA lands there
	@sudo brew services restart caddy >/dev/null 2>&1 \
		&& echo "    ✓ caddy service" \
		|| echo "    ✗ caddy service failed — check: sudo brew services list"
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
		|| echo "    ✗ dnsmasq service failed — check: sudo brew services list"
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

.PHONY: _setup-viteplus
_setup-viteplus:
	@echo "  Vite+..."
	@if [ -f "$$HOME/.vite-plus/env" ]; then \
		echo "    · Vite+ (ok)"; \
	else \
		echo "    Installing Vite+..."; \
		curl -fsSL https://vite.plus | bash; \
		echo "    ✓ Vite+ installed (node version managed via fnm)"; \
	fi

.PHONY: _setup-op-token
_setup-op-token:
	@echo "  1Password CLI (personal account: tkrumm)..."
	@if [ ! -S "$$HOME/.config/op/op-daemon.sock" ]; then \
		echo "    ✗ op daemon socket missing — is 1Password app running?"; \
		echo "      Start 1Password, then re-run: make setup"; \
		exit 1; \
	fi
	@echo "    · op-daemon.sock (ok)"
	@if op whoami --account tkrumm >/dev/null 2>&1; then \
		echo "    · op session (ok, $$(op whoami --account tkrumm --format=json 2>/dev/null | jq -r '.email // "unknown"'))"; \
	else \
		echo "    Triggering Touch ID sign-in for tkrumm..."; \
		op vault list --account tkrumm >/dev/null 2>&1 || true; \
		if op whoami --account tkrumm >/dev/null 2>&1; then \
			echo "    ✓ op session established"; \
		else \
			echo "    ✗ op sign-in failed — run manually: op vault list --account tkrumm"; \
		fi; \
	fi
	@echo "    · ANTHROPIC_API_KEY not exported (Claude Code uses subscription)"
	@#
	@# [SERVICE ACCOUNT — disabled]
	@# TOKEN=$$(security find-generic-password -a "$$USER" -s "op-service-account-token" -w 2>/dev/null); \
	@# KEY=$$(OP_SERVICE_ACCOUNT_TOKEN="$$TOKEN" op read "op://CLI/Anthropic/credential" 2>/dev/null); \
	@# security add-generic-password -U -a "$$USER" -s "anthropic-api-key" -w "$$KEY" -T /usr/bin/security

.PHONY: _setup-sdk-keys
_setup-sdk-keys:
	@echo "  API keys (1Password → Keychain cache)..."
	@if security find-generic-password -s claude-sdk-api-key -w >/dev/null 2>&1; then \
		echo "    · CLAUDE_SDK_API_KEY (ok)"; \
	else \
		KEY=$$(op read "op://common/anthropic/API_KEY" --account tkrumm 2>/dev/null || echo ""); \
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
		URL=$$(op read "op://common/anthropic/BASE_URL" --account tkrumm 2>/dev/null || echo ""); \
		if [ -n "$$URL" ]; then \
			security add-generic-password -a "$$USER" -s claude-sdk-base-url -w "$$URL" -T /usr/bin/security; \
			echo "    ✓ CLAUDE_SDK_BASE_URL cached in Keychain"; \
		else \
			echo "    ✗ Could not read op://common/anthropic/BASE_URL — skipping"; \
		fi; \
	fi
	@if security find-generic-password -s tavily-api-key -w >/dev/null 2>&1; then \
		echo "    · TAVILY_API_KEY (ok)"; \
	else \
		KEY=$$(op read "op://common/tavily/API_KEY" --account tkrumm 2>/dev/null || echo ""); \
		if [ -n "$$KEY" ]; then \
			security add-generic-password -a "$$USER" -s tavily-api-key -w "$$KEY" -T /usr/bin/security; \
			echo "    ✓ TAVILY_API_KEY cached in Keychain"; \
		else \
			echo "    ✗ Could not read op://common/tavily/API_KEY — skipping"; \
		fi; \
	fi

.PHONY: _setup-ssh
_setup-ssh:
	@echo "  SSH config (~/.ssh/config)..."
	@mkdir -p "$(HOME)/.ssh"
	@chmod 700 "$(HOME)/.ssh"
	@IUMAC=$$(op read "op://Private/iumac-server/hostname" --account tkrumm 2>/dev/null || echo ""); \
	MACMINI=$$(op read "op://Private/mac-mini-server/hostname" --account tkrumm 2>/dev/null || echo ""); \
	if [ -n "$$IUMAC" ]; then \
		sed -e "s/__IUMAC_HOSTNAME__/$$IUMAC/" -e "s/__MACMINI_HOSTNAME__/$$MACMINI/" \
			"$(DOTFILES_DIR)/config/ssh_config" > "$(HOME)/.ssh/config"; \
		chmod 600 "$(HOME)/.ssh/config"; \
		echo "    ✓ ~/.ssh/config written (iumac → $$IUMAC, mac-mini → $${MACMINI:-unset})"; \
		[ -z "$$MACMINI" ] && echo "    ! mac-mini hostname missing (op://Private/mac-mini-server/hostname)" || true; \
	else \
		echo "    ✗ Could not read iumac-server hostname from 1Password — skipping"; \
	fi

.PHONY: remote-access _setup-remote-access
# Opt-in per machine — NOT in the default `setup` chain, because enabling an SSH
# server is a deliberate per-host decision. Run `make remote-access` on a Mac you
# want to control remotely (over Tailscale): installs trusted keys + key-only
# sshd hardening; the Remote Login / Screen Sharing toggles are best-effort
# (TCC/SIP usually require System Settings) and reachability is Tailscale-only.
remote-access: _setup-remote-access
_setup-remote-access:
	@echo "  Remote access (SSH + Screen Sharing over Tailscale)..."
	@mkdir -p "$(HOME)/.ssh"; chmod 700 "$(HOME)/.ssh"
	@touch "$(HOME)/.ssh/authorized_keys"; chmod 600 "$(HOME)/.ssh/authorized_keys"
	@# Install trusted public keys (append-if-missing; never clobbers existing keys).
	@grep -E '^ssh-' "$(DOTFILES_DIR)/config/ssh/authorized_keys" | while IFS= read -r key; do \
		grep -qF "$$key" "$(HOME)/.ssh/authorized_keys" 2>/dev/null || printf '%s\n' "$$key" >> "$(HOME)/.ssh/authorized_keys"; \
	done; \
	echo "    ✓ authorized_keys ($$(grep -cE '^ssh-' "$(HOME)/.ssh/authorized_keys" 2>/dev/null) trusted key(s))"
	@# Key-only sshd hardening — only with at least one trusted key (avoid lockout).
	@if ! grep -qE '^ssh-' "$(HOME)/.ssh/authorized_keys" 2>/dev/null; then \
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

.PHONY: _setup-rules
_setup-rules:
	@echo "  Rules (global → ~/.claude/rules/)..."
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/rules" \
		DST="$(CLAUDE_DIR)/rules"

.PHONY: _setup-hooks
_setup-hooks:
	@echo "  Hooks..."
	@mkdir -p $(CLAUDE_DIR)/hooks
	@chmod +x $(DOTFILES_DIR)/hooks/*.ts
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/hooks/notify.ts" \
		DST="$(CLAUDE_DIR)/hooks/notify.ts"
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/hooks/protect-branches.ts" \
		DST="$(CLAUDE_DIR)/hooks/protect-branches.ts"
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/hooks/docker-makefile.ts" \
		DST="$(CLAUDE_DIR)/hooks/docker-makefile.ts"
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

.PHONY: _setup-skills
_setup-skills:
	@echo "  Skills (global → ~/.claude/skills/)..."
	@mkdir -p $(CLAUDE_DIR)/skills
	@for skill in $(DOTFILES_DIR)/skills/*/; do \
		name=$$(basename "$$skill"); \
		$(MAKE) --no-print-directory _link SRC="$$skill" DST="$(CLAUDE_DIR)/skills/$$name"; \
	done

.PHONY: _setup-settings
_setup-settings:
	@echo "  Claude Code settings..."
	@if [ ! -f "$(CLAUDE_DIR)/settings.json" ]; then \
		jq 'del(._NOTE)' "$(DOTFILES_DIR)/config/settings.template.json" \
			> "$(CLAUDE_DIR)/settings.json"; \
		echo "    ✓ settings.json created from template"; \
	else \
		jq --slurpfile existing "$(CLAUDE_DIR)/settings.json" \
			'del(._NOTE) * {permissions: ($$existing[0].permissions // .permissions)} * ($$existing[0] | {model, effortLevel, alwaysThinkingEnabled} | with_entries(select(.value != null)))' \
			"$(DOTFILES_DIR)/config/settings.template.json" \
			> /tmp/claude-settings-merged.json \
		&& mv /tmp/claude-settings-merged.json "$(CLAUDE_DIR)/settings.json"; \
		echo "    ✓ settings.json merged (template applied, permissions + model/effort preserved)"; \
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
	@echo "  Ghostty (Blueprint v6 themes)..."
	@mkdir -p $(HOME)/.config/ghostty/themes
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/config/ghostty/config" \
		DST="$(HOME)/.config/ghostty/config"
	@# cmux primary config (path has spaces — inline instead of _link)
	@_src="$(DOTFILES_DIR)/config/ghostty/config.cmux"; \
	_dst="$(HOME)/Library/Application Support/com.mitchellh.ghostty/config"; \
	if [ -L "$$_dst" ] && [ "$$(readlink "$$_dst")" = "$$_src" ]; then \
		echo "    · config.cmux (ok)"; \
	else \
		if [ -e "$$_dst" ] && [ ! -L "$$_dst" ]; then \
			mv "$$_dst" "$$_dst.bak"; \
			echo "    Backing up $$_dst"; \
		fi; \
		mkdir -p "$$(dirname "$$_dst")"; \
		ln -sfn "$$_src" "$$_dst"; \
		echo "    ✓ config.cmux"; \
	fi
	@$(MAKE) --no-print-directory _copy \
		SRC="$(DOTFILES_DIR)/config/ghostty/themes/basalt-ui-light" \
		DST="$(HOME)/.config/ghostty/themes/basalt-ui-light"
	@$(MAKE) --no-print-directory _copy \
		SRC="$(DOTFILES_DIR)/config/ghostty/themes/basalt-ui-dark" \
		DST="$(HOME)/.config/ghostty/themes/basalt-ui-dark"
	@# Clean up old unmanaged theme files
	@for old in ayu-mirage basalt-ui; do \
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
			|| echo "    ✗ docker-socket LaunchDaemon failed"; \
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

# Copy (not symlink) — for apps like cmux that don't follow symlinks for theme files
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
	@echo "  1Password (personal account)"
	@if op whoami >/dev/null 2>&1; then \
		echo "    ✓ op session active ($$(op whoami --format=json 2>/dev/null | jq -r '.email // "unknown"'))"; \
	else \
		echo "    ✗ op session [expired — run make setup to re-authenticate]"; \
	fi
	@echo "    · ANTHROPIC_API_KEY not exported (Claude Code uses subscription)"
	@echo "  Agent SDK Keys"
	@security find-generic-password -s claude-sdk-api-key -w >/dev/null 2>&1 \
		&& echo "    ✓ CLAUDE_SDK_API_KEY (Keychain)" \
		|| echo "    ✗ CLAUDE_SDK_API_KEY [not cached — run make setup]"
	@security find-generic-password -s claude-sdk-base-url -w >/dev/null 2>&1 \
		&& echo "    ✓ CLAUDE_SDK_BASE_URL (Keychain)" \
		|| echo "    ✗ CLAUDE_SDK_BASE_URL [not cached — run make setup]"
	@security find-generic-password -s tavily-api-key -w >/dev/null 2>&1 \
		&& echo "    ✓ TAVILY_API_KEY (Keychain)" \
		|| echo "    ✗ TAVILY_API_KEY [not cached — run make setup]"
	@echo "  Rules"
	@$(MAKE) --no-print-directory _check DST="$(CLAUDE_DIR)/rules"
	@echo "  OpenCode"
	@if command -v opencode >/dev/null 2>&1 || [ -x "$(HOME)/.opencode/bin/opencode" ]; then \
		echo "    ✓ opencode binary"; \
	else \
		echo "    ✗ opencode [not installed — run make setup]"; \
	fi
	@$(MAKE) --no-print-directory _check DST="$(HOME)/.config/opencode/opencode.json"
	@$(MAKE) --no-print-directory _check DST="$(HOME)/.config/opencode/AGENTS.md"
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
	@echo "  Scripts"
	@$(MAKE) --no-print-directory _check DST="$(CLAUDE_DIR)/statusline.sh"
	@$(MAKE) --no-print-directory _check DST="$(CLAUDE_DIR)/fetch_usage.py"
	@echo "  Gitignore"
	@$(MAKE) --no-print-directory _check DST="$(HOME)/.gitignore_global"
	@echo "  Ghostty"
	@$(MAKE) --no-print-directory _check DST="$(HOME)/.config/ghostty/config"
	@if [ -L "$(HOME)/Library/Application Support/com.mitchellh.ghostty/config" ]; then \
		echo "    ✓ config.cmux"; \
	else \
		echo "    ✗ config.cmux [not symlinked — run make setup]"; \
	fi
	@$(MAKE) --no-print-directory _check-copy \
		SRC="$(DOTFILES_DIR)/config/ghostty/themes/basalt-ui-light" \
		DST="$(HOME)/.config/ghostty/themes/basalt-ui-light"
	@$(MAKE) --no-print-directory _check-copy \
		SRC="$(DOTFILES_DIR)/config/ghostty/themes/basalt-ui-dark" \
		DST="$(HOME)/.config/ghostty/themes/basalt-ui-dark"
	@echo "  Skills ($(shell ls $(DOTFILES_DIR)/skills/ | wc -l | xargs) — global)"
	@for skill in $(DOTFILES_DIR)/skills/*/; do \
		name=$$(basename "$$skill"); \
		$(MAKE) --no-print-directory _check DST="$(CLAUDE_DIR)/skills/$$name"; \
	done
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
	@echo "  Vite+"
	@if [ -f "$$HOME/.vite-plus/env" ]; then \
		echo "    ✓ Vite+ installed"; \
	else \
		echo "    ✗ Vite+ [not installed — run make setup]"; \
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
	@echo "  usage-tracker"
	@if [ ! -f "$(SOURCEROOT)/usage-tracker/package.json" ]; then \
		echo "    · usage-tracker not cloned — skipping"; \
	elif launchctl list 2>/dev/null | grep -q "com.jkrumm.usage-tracker"; then \
		echo "    ✓ ingest LaunchAgent loaded (com.jkrumm.usage-tracker)"; \
	else \
		echo "    ✗ ingest LaunchAgent [not loaded — run make setup]"; \
	fi
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

# Check for copied (not symlinked) files — used for cmux theme files
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
# Always-on via brew service (RunAtLoad + KeepAlive) — manage with these targets,
# not bare `colima stop` (KeepAlive would relaunch it).
# GUI: Raycast "Manage Docker" extension + `lazydocker` TUI.

.PHONY: colima-start
colima-start:
	@brew services start colima

.PHONY: colima-stop
colima-stop:
	@brew services stop colima

# Apply current COLIMA_CPU/MEMORY to the persisted config + restart the service.
# (Disk can only grow via recreate — not handled here.)
.PHONY: colima-restart
colima-restart:
	@if [ -f "$(HOME)/.colima/default/colima.yaml" ]; then \
		sed -i '' 's/^cpu: .*/cpu: $(COLIMA_CPU)/; s/^memory: .*/memory: $(COLIMA_MEMORY)/' \
			"$(HOME)/.colima/default/colima.yaml"; \
	fi
	@brew services restart colima

.PHONY: colima-status
colima-status:
	@brew services list | grep -E '^colima' || echo "  colima service: not registered"
	@colima status

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

# ============================================================================
# LocalAI — mlx-audio (TTS + STT) on every Mac, bound to 127.0.0.1:8000
# ----------------------------------------------------------------------------
# RETIRED 2026-05-25 — superseded by the cloud audio-proxy (~/SourceRoot/
# audio-proxy, :7716, _setup-audio-proxy). No longer run by `make setup`.
# Targets below are kept intact so the stack can be re-added later by
# re-listing `_setup-localai` in the setup chain. To tear down a machine that
# still has it installed, run `make localai-teardown`.
# ============================================================================

LAUNCHAGENTS  := $(HOME)/Library/LaunchAgents
LOCALAI_DIR   := $(DOTFILES_DIR)/localai
MLX_AUDIO_BIN := $(HOME)/.local/bin/mlx_audio.server
MLX_AUDIO_PY  := $(HOME)/.local/share/uv/tools/mlx-audio/bin/python3
MLX_SPEECH_BIN := $(HOME)/.local/bin/mlx-speech
LITELLM_DIR   := $(DOTFILES_DIR)/litellm
LITELLM_BIN   := $(HOME)/.local/share/uv/tools/litellm/bin/litellm
# Source dir for _render-plists; overridden per-call for non-localai services.
PLIST_DIR     ?= $(LOCALAI_DIR)

# Install mlx-audio + Python deps + ffmpeg + apply m4a STT patch.
# Idempotent — skips work that's already done.
.PHONY: _setup-opencode
_setup-opencode:
	@echo "  OpenCode (IU unified-endpoint fallback)..."
	@if [ -x "$(HOME)/.opencode/bin/opencode" ]; then \
		echo "    · opencode $$($(HOME)/.opencode/bin/opencode --version 2>/dev/null || echo ok) (ok)"; \
	else \
		echo "    Installing OpenCode..."; \
		curl -fsSL https://opencode.ai/install | bash >/dev/null 2>&1 \
			&& echo "    ✓ OpenCode installed" \
			|| echo "    ✗ OpenCode install failed — install manually: https://opencode.ai/docs"; \
	fi
	@mkdir -p $(HOME)/.config/opencode
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/config/opencode/opencode.json" \
		DST="$(HOME)/.config/opencode/opencode.json"
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/config/opencode/AGENTS.md" \
		DST="$(HOME)/.config/opencode/AGENTS.md"
	@# Reuses claude-sdk-* Keychain entries (same op://common/anthropic credential).
	@if security find-generic-password -s claude-sdk-api-key -w >/dev/null 2>&1; then \
		echo "    · IU credential (Keychain, shared with Agent SDK) ok"; \
	else \
		echo "    ✗ claude-sdk-api-key not in Keychain — run make setup (_setup-sdk-keys)"; \
	fi

.PHONY: _setup-localai
_setup-localai:
	@echo "  LocalAI (mlx-audio TTS + STT on 127.0.0.1:8000)..."
	@if ! command -v uv >/dev/null 2>&1; then \
		echo "    ✗ uv not installed — run _setup-tools first"; exit 1; \
	fi
	@if [ -x "$(MLX_AUDIO_BIN)" ]; then \
		echo "    · mlx-audio installed (ok)"; \
	else \
		echo "    Installing mlx-audio[all] via uv (~2-5 min)..."; \
		uv tool install "mlx-audio[all]" >/dev/null 2>&1 || { echo "    ✗ uv tool install failed"; exit 1; }; \
		echo "    ✓ mlx-audio installed"; \
	fi
	@# Pinned dep workarounds — mlx-audio's transitive deps need these specific versions
	@if "$(MLX_AUDIO_PY)" -c "import setuptools, sys; sys.exit(0 if setuptools.__version__ < '81' else 1)" 2>/dev/null; then \
		echo "    · setuptools<81 (ok)"; \
	else \
		uv pip install --quiet --python "$(MLX_AUDIO_PY)" "setuptools<81" \
			&& echo "    ✓ setuptools<81 pinned"; \
	fi
	@if "$(MLX_AUDIO_PY)" -c "import multipart" 2>/dev/null; then \
		echo "    · python-multipart (ok)"; \
	else \
		uv pip install --quiet --python "$(MLX_AUDIO_PY)" python-multipart \
			&& echo "    ✓ python-multipart installed"; \
	fi
	@if "$(MLX_AUDIO_PY)" -c "import misaki, num2words, phonemizer, en_core_web_sm" 2>/dev/null; then \
		echo "    · Kokoro deps (ok)"; \
	else \
		echo "    Installing Kokoro TTS deps..."; \
		uv pip install --quiet --python "$(MLX_AUDIO_PY)" "misaki[en]<0.9" num2words phonemizer espeakng_loader spacy \
			&& uv pip install --quiet --python "$(MLX_AUDIO_PY)" "en-core-web-sm@https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl" \
			&& echo "    ✓ Kokoro deps installed"; \
	fi
	@# pysbd — German-aware sentence splitter for the TTS chunker.
	@# Native regex falls over on "29. April", "9.30 Uhr", "z.B.", "Dr.", "bzw."
	@if "$(MLX_AUDIO_PY)" -c "import pysbd" 2>/dev/null; then \
		echo "    · pysbd (ok)"; \
	else \
		uv pip install --quiet --python "$(MLX_AUDIO_PY)" pysbd \
			&& echo "    ✓ pysbd installed"; \
	fi
	@# supertonic — ONNX/CPU fallback TTS (~99M, ~900 MB RSS).
	@# Used by helper /v1/tts/synthesize/fast and as automatic fallback
	@# when the Fish-S2-Pro primary path times out or errors.
	@if "$(MLX_AUDIO_PY)" -c "import supertonic" 2>/dev/null; then \
		echo "    · supertonic (ok)"; \
	else \
		uv pip install --quiet --python "$(MLX_AUDIO_PY)" supertonic \
			&& echo "    ✓ supertonic installed"; \
	fi
	@command -v ffmpeg >/dev/null 2>&1 && echo "    · ffmpeg (ok)" || echo "    ✗ ffmpeg [from Brewfile — run: make brew-check]"
	@# m4a STT patch — required for MacWhisper / Slack voice memos.
	@# Detect by grepping for a unique post-patch marker (reverse dry-run was unreliable).
	@PATCH="$(LOCALAI_DIR)/patches/mlx-audio-m4a-stt.patch"; \
	PATCH_DIR="$(HOME)/.local/share/uv/tools/mlx-audio/lib/python3.12/site-packages"; \
	SERVER_PY="$$PATCH_DIR/mlx_audio/server.py"; \
	if [ -f "$$SERVER_PY" ] && grep -q "ffmpeg.*src_path" "$$SERVER_PY" 2>/dev/null; then \
		echo "    · m4a STT patch (already applied)"; \
	elif [ -d "$$PATCH_DIR" ] && [ -f "$$PATCH" ]; then \
		if patch -p1 -d "$$PATCH_DIR" < "$$PATCH" >/dev/null 2>&1; then \
			echo "    ✓ m4a STT patch applied"; \
		else \
			echo "    ✗ m4a STT patch failed — re-apply manually after upgrade"; \
		fi; \
	fi
	@# Fish S2 Pro TTS — separate uv tool venv (mlx-speech needs Python 3.13+)
	@if [ -x "$(MLX_SPEECH_BIN)" ]; then \
		echo "    · mlx-speech installed (ok)"; \
	else \
		echo "    Installing mlx-speech via uv (~30s, plus 6.7 GB model on first synthesis)..."; \
		uv tool install mlx-speech --python 3.13 >/dev/null 2>&1 || { echo "    ✗ uv tool install mlx-speech failed"; exit 1; }; \
		echo "    ✓ mlx-speech installed"; \
	fi
	@$(MAKE) --no-print-directory localai-setup

# Universal services (every Mac):
#   com.localai.audio — mlx-audio :8000 (STT only, Parakeet)
#   com.localai.fish  — Fish S2 Pro :8002 (TTS, both DE and EN)
#
# The Hermes-only `com.localai.helper` plist (FastAPI orchestration on :8001)
# is rendered by hermes-agent's `make setup` — its template still lives here
# under `localai/com.localai.helper.plist.template` for colocation with the
# other localai plists.
LOCALAI_AUDIO_PLISTS  := com.localai.audio com.localai.fish

# Render universal plists (audio only) and reload changed ones.
.PHONY: localai-setup
localai-setup:
	@mkdir -p "$(LAUNCHAGENTS)"
	@$(MAKE) --no-print-directory _render-plists PLISTS="$(LOCALAI_AUDIO_PLISTS)"

# Internal: render any plist list from $(PLIST_DIR) templates (default localai).
.PHONY: _render-plists
_render-plists:
	@for label in $(PLISTS); do \
		SRC="$(PLIST_DIR)/$$label.plist.template"; \
		DST="$(LAUNCHAGENTS)/$$label.plist"; \
		TMP="$$(mktemp)"; \
		sed "s|__HOME__|$(HOME)|g" "$$SRC" > "$$TMP"; \
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

# `start`/`stop` cover the Hermes helper too if it's been installed by
# hermes-agent — that's why we glob the LaunchAgents directory rather than just
# iterating LOCALAI_AUDIO_PLISTS.
LOCALAI_ALL_PLISTS := com.localai.audio com.localai.fish com.localai.helper

.PHONY: start
start:
	@for label in $(LOCALAI_ALL_PLISTS); do \
		PLIST="$(LAUNCHAGENTS)/$$label.plist"; \
		[ -f "$$PLIST" ] || continue; \
		launchctl load "$$PLIST" 2>/dev/null \
			&& echo "  · $$label started" \
			|| echo "  · $$label already running"; \
	done

.PHONY: stop
stop:
	@for label in $(LOCALAI_ALL_PLISTS); do \
		PLIST="$(LAUNCHAGENTS)/$$label.plist"; \
		[ -f "$$PLIST" ] || continue; \
		launchctl unload "$$PLIST" 2>/dev/null \
			&& echo "  · $$label stopped" \
			|| true; \
	done

# Retire a live install: unload (RunAtLoad+KeepAlive means we must also delete
# the installed plists or launchd relaunches at next login) and remove the
# rendered LaunchAgents. Leaves the templates, venvs, models, and uv tools
# untouched so the stack can be re-added later. Does not uninstall mlx-audio /
# mlx-speech (cheap to keep; `uv tool uninstall mlx-audio mlx-speech` to reclaim).
.PHONY: localai-teardown
localai-teardown:
	@for label in $(LOCALAI_ALL_PLISTS); do \
		PLIST="$(LAUNCHAGENTS)/$$label.plist"; \
		[ -f "$$PLIST" ] || { echo "  · $$label (not installed)"; continue; }; \
		launchctl unload "$$PLIST" 2>/dev/null || true; \
		rm -f "$$PLIST"; \
		echo "  ✓ $$label torn down (unloaded + plist removed)"; \
	done
	@echo "  Templates + venvs/models kept. Cloud audio-proxy (:7716) is the replacement."

# ============================================================================
# LiteLLM — Anthropic↔OpenAI bridge for IU (DeepSeek-V4-Pro etc.), bound to 127.0.0.1:4000
# ============================================================================
# Translates `claude -p` Anthropic Messages calls into OpenAI chat/completions
# against the IU unified endpoint, so worker sessions can run on DeepSeek-V4-Pro
# with claude-sonnet-4-6-eu failover. Consumed by sideclaw. See
# docs/deepseek-litellm-bridge.md.

.PHONY: _setup-litellm
_setup-litellm:
	@echo "  LiteLLM (Anthropic↔OpenAI bridge on 127.0.0.1:4000)..."
	@if ! command -v uv >/dev/null 2>&1; then \
		echo "    ✗ uv not installed — run _setup-tools first"; exit 1; \
	fi
	@if [ -x "$(LITELLM_BIN)" ]; then \
		echo "    · litellm installed (ok)"; \
	else \
		echo "    Installing litellm[proxy] via uv (~1-2 min)..."; \
		uv tool install "litellm[proxy]" >/dev/null 2>&1 || { echo "    ✗ uv tool install failed"; exit 1; }; \
		echo "    ✓ litellm installed"; \
	fi
	@mkdir -p "$(HOME)/.config/litellm"
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/config/litellm/config.yaml" \
		DST="$(HOME)/.config/litellm/config.yaml"
	@$(MAKE) --no-print-directory _link \
		SRC="$(DOTFILES_DIR)/config/litellm/usage_logger.py" \
		DST="$(HOME)/.config/litellm/usage_logger.py"
	@if security find-generic-password -s claude-sdk-api-key -w >/dev/null 2>&1; then \
		echo "    · IU credential (Keychain, shared with Agent SDK) ok"; \
	else \
		echo "    ✗ claude-sdk-api-key not in Keychain — run make setup (_setup-sdk-keys)"; \
	fi
	@$(MAKE) --no-print-directory litellm-setup

# Render the litellm plist from its template + reload if changed.
.PHONY: litellm-setup
litellm-setup:
	@mkdir -p "$(LAUNCHAGENTS)"
	@$(MAKE) --no-print-directory _render-plists PLISTS="com.litellm.proxy" PLIST_DIR="$(LITELLM_DIR)"

.PHONY: litellm-restart
litellm-restart:
	@launchctl kickstart -k gui/$$(id -u)/com.litellm.proxy && echo "  · litellm restarted"

.PHONY: litellm-logs
litellm-logs:
	@tail -f /tmp/litellm.log

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

_setup-audio-proxy:
	@echo "  audio-proxy (IU audio STT/TTS proxy on 127.0.0.1:7716)..."
	@if [ -f "$(SOURCEROOT)/audio-proxy/package.json" ]; then \
		( cd "$(SOURCEROOT)/audio-proxy" \
			&& bun install >/dev/null 2>&1 \
			&& bash launchd/install-agent.sh >/dev/null ) \
			&& echo "    ✓ deps installed + LaunchAgent loaded (com.jkrumm.audio-proxy)" \
			|| echo "    ✗ audio-proxy setup failed — run 'make install-agent' in the repo"; \
	else \
		echo "    · audio-proxy not cloned at $(SOURCEROOT)/audio-proxy — skipping"; \
	fi

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
	@echo ""
	@echo "  make colima-start    Start the Docker runtime service (auto-starts at login)"
	@echo "  make colima-stop     Stop the Docker runtime service"
	@echo "  make colima-restart  Restart + apply current COLIMA_CPU/MEMORY ceilings"
	@echo "  make colima-status   Show service + VM status"
	@echo "  make orbstack-remove Uninstall OrbStack after migrating to Colima (guarded; FORCE=1 to override)"
	@echo ""
	@echo "  LocalAI (mlx-audio/Fish TTS+STT) is RETIRED — replaced by the cloud"
	@echo "  audio-proxy (~/SourceRoot/audio-proxy, :7716). make setup no longer"
	@echo "  installs it. make localai-teardown removes a live install."
	@echo ""
	@echo "  make litellm-setup    Install + load the LiteLLM bridge LaunchAgent (:4000)"
	@echo "  make litellm-restart  Restart the LiteLLM bridge"
	@echo "  make litellm-logs     Tail /tmp/litellm.log"
	@echo ""
	@echo "  usage-tracker (token/cost telemetry) is installed by make setup."
	@echo "  Manage it in ~/SourceRoot/usage-tracker — make stats / sources / logs."
	@echo ""
	@echo "  Hermes Agent setup lives in ~/SourceRoot/hermes-agent — run make setup there."
	@echo ""

.DEFAULT_GOAL := help
