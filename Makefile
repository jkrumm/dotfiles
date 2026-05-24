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
	@$(MAKE) --no-print-directory _setup-localai
	@$(MAKE) --no-print-directory _setup-litellm
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

.PHONY: _setup-tools
_setup-tools:
	@echo "  Tools..."
	@# jq — required by this Makefile itself
	@brew list jq &>/dev/null || brew install jq
	@echo "    ✓ jq $$(jq --version)"
	@# gh — GitHub CLI (used by /pr skill)
	@brew list gh &>/dev/null || brew install gh
	@echo "    ✓ gh $$(gh --version | head -1)"
	@# fzf — fuzzy finder (Ctrl+R, Ctrl+T, Alt+C)
	@brew list fzf &>/dev/null || brew install fzf
	@echo "    ✓ fzf $$(fzf --version)"
	@# zoxide — smart cd (j command)
	@brew list zoxide &>/dev/null || brew install zoxide
	@echo "    ✓ zoxide $$(zoxide --version)"
	@# wtp — git worktree manager
	@brew list satococoa/tap/wtp &>/dev/null || brew install satococoa/tap/wtp
	@echo "    ✓ wtp $$(wtp --version 2>/dev/null || echo ok)"
	@# fnm — node version manager
	@brew list fnm &>/dev/null || brew install fnm
	@echo "    ✓ fnm $$(fnm --version)"
	@# uv — Python runner (required by statusline.sh + fetch_usage.py)
	@brew list uv &>/dev/null || brew install uv
	@echo "    ✓ uv $$(uv --version)"
	@# python@3.14 — ensure current version; remove older if no dependents
	@brew list python@3.14 &>/dev/null || brew install python@3.14
	@echo "    ✓ python $$(python3.14 --version 2>/dev/null || echo ok)"
	@for old in python@3.11 python@3.12 python@3.13; do \
		if brew list "$$old" &>/dev/null; then \
			if [ -z "$$(brew uses --installed "$$old" 2>/dev/null)" ]; then \
				brew uninstall "$$old" && echo "    ✓ removed $$old (no dependents)"; \
			else \
				echo "    · $$old kept (required by: $$(brew uses --installed $$old | tr '\n' ' '))"; \
			fi; \
		fi; \
	done
	@# age — encryption for 1Password backup
	@brew list age &>/dev/null || brew install age
	@echo "    ✓ age $$(age --version)"
	@# coderabbit — local code review CLI (used by /review and /ship skills)
	@if command -v coderabbit >/dev/null 2>&1; then \
		echo "    · coderabbit $$(coderabbit --version 2>/dev/null || echo ok)"; \
	else \
		brew install coderabbit 2>/dev/null || curl -fsSL https://cli.coderabbit.ai/install.sh | sh; \
		echo "    ✓ coderabbit installed (run: coderabbit auth login)"; \
	fi
	@# fallow — project-graph static analyzer (dead code, dupes, complexity — replaces knip/jscpd)
	@if command -v fallow >/dev/null 2>&1; then \
		echo "    · fallow $$(fallow --version 2>/dev/null | head -1) (ok)"; \
	else \
		npm install -g fallow 2>/dev/null || true; \
		command -v fallow >/dev/null 2>&1 && echo "    ✓ fallow installed" || echo "    · fallow (use npx fallow as fallback)"; \
	fi
	@# bun — JS runtime (hooks, claude-cli skill)
	@if command -v bun >/dev/null 2>&1; then \
		echo "    · bun $$(bun --version) (ok)"; \
	else \
		echo "    Installing bun..."; \
		curl -fsSL https://bun.sh/install | bash; \
		echo "    ✓ bun installed"; \
	fi

.PHONY: _setup-caddy
_setup-caddy:
	@echo "  Caddy (local HTTPS reverse proxy)..."
	@brew list caddy &>/dev/null || brew install caddy
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
	@brew list dnsmasq &>/dev/null || brew install dnsmasq
	@echo "    ✓ dnsmasq installed"
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
	@# sleepwatcher fires wakeup.sh on sleep wake → caddy reload
	@brew list sleepwatcher &>/dev/null || brew install sleepwatcher
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
	@HOSTNAME=$$(op read "op://Private/iumac-server/hostname" --account tkrumm 2>/dev/null || echo ""); \
	if [ -n "$$HOSTNAME" ]; then \
		sed "s/__IUMAC_HOSTNAME__/$$HOSTNAME/" "$(DOTFILES_DIR)/config/ssh_config" > "$(HOME)/.ssh/config"; \
		chmod 600 "$(HOME)/.ssh/config"; \
		echo "    ✓ ~/.ssh/config written (iumac → $$HOSTNAME)"; \
	else \
		echo "    ✗ Could not read iumac-server hostname from 1Password — skipping"; \
	fi

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
	@# Docker CLI + Compose plugin + credential helper (osxkeychain) + lazydocker TUI + colima VM.
	@# docker-credential-helper provides docker-credential-osxkeychain, which the
	@# CLI needs because ~/.docker/config.json sets "credsStore": "osxkeychain"
	@# (OrbStack used to supply this binary).
	@for pkg in colima docker docker-compose docker-credential-helper lazydocker; do \
		brew list $$pkg &>/dev/null || brew install $$pkg; \
	done
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
	@brew list ffmpeg &>/dev/null && echo "    · ffmpeg (ok)" || (brew install ffmpeg >/dev/null 2>&1 && echo "    ✓ ffmpeg installed")
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

# ============================================================================
# LiteLLM — Anthropic↔OpenAI bridge for IU (Kimi-K2.6 etc.), bound to 127.0.0.1:4000
# ============================================================================
# Translates `claude -p` Anthropic Messages calls into OpenAI chat/completions
# against the IU unified endpoint, so worker sessions can run on Kimi-K2.6 (EU)
# with claude-sonnet-4-6-eu failover. Consumed by sideclaw. See
# docs/kimi-litellm-bridge.md.

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
	@echo "  make colima-start    Start the Docker runtime service (auto-starts at login)"
	@echo "  make colima-stop     Stop the Docker runtime service"
	@echo "  make colima-restart  Restart + apply current COLIMA_CPU/MEMORY ceilings"
	@echo "  make colima-status   Show service + VM status"
	@echo ""
	@echo "  make localai-setup  Render audio plist from template + reload if changed"
	@echo "  make start          Start mlx-audio (+ helper if installed)"
	@echo "  make stop           Stop mlx-audio (+ helper if installed)"
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
