DOTFILES_DIR := $(shell pwd)
CLAUDE_DIR   := $(HOME)/.claude
SOURCEROOT   := $(HOME)/SourceRoot
BREW_PREFIX  := $(shell brew --prefix 2>/dev/null || echo /opt/homebrew)

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
	@$(MAKE) --no-print-directory _setup-localai
	@$(MAKE) --no-print-directory _setup-orbstack-block
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
	@# bun — JS runtime (cq alias, hooks)
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

.PHONY: _setup-orbstack-block
_setup-orbstack-block:
	@echo "  OrbStack phone-home block (/etc/hosts)..."
	@if [ ! -d "/Applications/OrbStack.app" ]; then \
		echo "    · OrbStack not installed — skipping"; \
	elif grep -q "OrbStack phone-home block" /etc/hosts 2>/dev/null; then \
		echo "    · /etc/hosts entries (ok)"; \
	else \
		echo "    Appending block to /etc/hosts (sudo)..."; \
		printf '\n' | sudo tee -a /etc/hosts >/dev/null \
			&& sudo tee -a /etc/hosts < "$(DOTFILES_DIR)/config/orbstack-hosts.txt" >/dev/null \
			&& sudo dscacheutil -flushcache \
			&& sudo killall -HUP mDNSResponder 2>/dev/null || true; \
		echo "    ✓ /etc/hosts entries added + DNS cache flushed"; \
	fi

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
	@echo "  OrbStack phone-home block"
	@if [ ! -d "/Applications/OrbStack.app" ]; then \
		echo "    · OrbStack not installed — skipping"; \
	elif grep -q "OrbStack phone-home block" /etc/hosts 2>/dev/null; then \
		echo "    ✓ /etc/hosts entries"; \
	else \
		echo "    ✗ /etc/hosts entries [missing — run make setup]"; \
	fi
	@echo "  sideclaw MCP"
	@if [ ! -f "$(SOURCEROOT)/sideclaw/server/mcp.ts" ]; then \
		echo "    · sideclaw not cloned — skipping"; \
	elif claude mcp list 2>/dev/null | grep -q "sideclaw"; then \
		echo "    ✓ sideclaw MCP registered"; \
	else \
		echo "    ✗ sideclaw MCP [not registered — run make setup]"; \
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
# cqueue — web dashboard (http://cqueue.local)
# ============================================================================

.PHONY: up
up:
	cd cqueue && docker compose up -d --build

.PHONY: down
down:
	cd cqueue && docker compose down

.PHONY: rebuild
rebuild:
	cd cqueue && docker compose up -d --build --force-recreate

.PHONY: logs
logs:
	cd cqueue && docker compose logs -f

.PHONY: shell
shell:
	cd cqueue && docker compose exec cqueue sh

.PHONY: ps
ps:
	cd cqueue && docker compose ps

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

# Install mlx-audio + Python deps + ffmpeg + apply m4a STT patch.
# Idempotent — skips work that's already done.
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

# Internal: render any plist list from $(LOCALAI_DIR) templates.
.PHONY: _render-plists
_render-plists:
	@for label in $(PLISTS); do \
		SRC="$(LOCALAI_DIR)/$$label.plist.template"; \
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
	@echo "  make localai-setup  Render audio plist from template + reload if changed"
	@echo "  make start          Start mlx-audio (+ helper if installed)"
	@echo "  make stop           Stop mlx-audio (+ helper if installed)"
	@echo ""
	@echo "  Hermes Agent setup lives in ~/SourceRoot/hermes-agent — run make setup there."
	@echo ""
	@echo "  make up         Start cqueue dashboard"
	@echo "  make down       Stop cqueue"
	@echo "  make rebuild    Force-recreate cqueue container"
	@echo "  make logs       Tail cqueue logs"
	@echo "  make shell      Shell into cqueue container"
	@echo "  make ps         Container status"
	@echo ""

.DEFAULT_GOAL := help
