# Brewfile — full machine manifest (brew-native: taps + formulae + casks).
#
# SOURCE OF TRUTH for every brew-managed package. `make setup` installs from
# this via `brew bundle install`. npm-global + uv tools stay Makefile-managed
# (they need Node/uv on PATH, which is not ready that early in bootstrap).
#
#   make brew-check   verify machine == Brewfile (read-only)
#   make brew-diff    list installed-but-undeclared packages (dry-run)
#   make brew-dump    regenerate from machine — then REVIEW THE GIT DIFF before commit
#
# The git history of this file is the supply-chain audit trail: nothing joins
# the manifest without a reviewed diff.

tap "oven-sh/bun"
tap "satococoa/tap"
tap "abue-ammar/tinycast"
tap "penso/tap"
tap "jkrumm/tap"
# Simple, modern, secure file encryption
brew "age"
# Editor of encrypted files (paired with age for the headless secrets cache)
brew "sops"
# SQLite with transparent AES encryption (finances vault via bun:sqlite setCustomSQLite)
brew "sqlcipher"
# PDF rendering library + pdftotext (finances document text extraction)
brew "poppler"
# Schema-validated .env loader — resolver plugins (1Password, etc.) + secret redaction
brew "varlock"
# Shell script static analysis — gates the secrets-run shim (make secrets-lint)
brew "shellcheck"
# Codec library for encoding and decoding AV1 video streams
brew "aom"
# Interpreted, interactive, object-oriented programming language
brew "python@3.14"
# Official Amazon AWS command-line interface (imgcli needs `aws`; replaces the 2023 x86_64 pkg under Rosetta)
brew "awscli"
# B2 Cloud Storage Command-Line Tools
brew "b2-tools"
# Limit max battery charge on Apple silicon (MacBook only — see `make batt-setup`)
brew "batt"
# Forward ntfy notifications to macOS Notification Center (own tap; MacBook service)
brew "jkrumm/tap/ntfy-mac"
# Powerful, enterprise-ready, open source web server with automatic HTTPS
brew "caddy"
# Container runtimes on MacOS (and Linux) with minimal setup
brew "colima"
# GNU File, Shell, and Text utilities
brew "coreutils"
# Lightweight DNS forwarder and DHCP server
brew "dnsmasq"
# Pack, ship and run any application as a lightweight container
brew "docker"
# Docker CLI plugin for extended build capabilities with BuildKit
brew "docker-buildx"
# Isolated development environments using Docker
brew "docker-compose"
# Platform keystore credential helper for Docker
brew "docker-credential-helper"
# Opinionated Dockerfile linter — the verifier behind rules/dockerfile.md
brew "droast"
# Play, record, convert, and stream select audio and video codecs
brew "ffmpeg"
# Fast and simple Node.js version manager
brew "fnm"
# Command-line fuzzy finder written in Go
brew "fzf"
# GitHub command-line tool
brew "gh"
# Open-source GitLab command-line tool
brew "glab"
# GNU Transport Layer Security (TLS) Library
brew "gnutls"
# GNU Privacy Guard (OpenPGP)
brew "gnupg"
# Fast linters runner for Go
brew "golangci-lint"
# OpenType text shaping engine
brew "harfbuzz"
# Agent multiplexer — owns the workspace model on the mini (remote persistence
# + per-pane agent state). Runs as a brew service there; needed on BOTH ends,
# since the MacBook attaches with `herdr --remote`.
brew "herdr"
# TIFF library and utilities
brew "libtiff"
# New file format for still image compression
brew "jpeg-xl"
# Lightweight and flexible command-line JSON processor
brew "jq"
# Lazier way to manage everything docker
brew "lazydocker"
# Fast and powerful Git hooks manager for any type of projects
brew "lefthook"
# Image format providing lossless and lossy compression for web images
brew "webp"
# Image processing and image analysis library
brew "leptonica"
# ISO/IEC 23008-12:2017 HEIF file format decoder and encoder
brew "libheif"
# Library for reading RAW files from digital photo cameras
brew "libraw"
# Web based real-time log viewer
brew "logdy"
# Modern and intuitive terminal-based text editor
brew "micro"
# Libraries for security-enabled client and server applications
brew "nss"
# OpenCode — third agent lane on the IU endpoint's Anthropic route
# (config/opencode/, launched with `oc`). Reads AGENTS.md and ~/.claude skills.
# Not on a machine with agent-workflows' pinned build (the mini): there one pinned npm build serves every
# caller via ~/.local/bin/opencode, and a Homebrew copy earlier on PATH silently shadowed it
# with an unpinned version (reinstalled by `brew bundle` 2026-10-16). docs/opencode.md.
brew "opencode" unless File.directory?(File.expand_path("~/.local/share/agent-workflows/opencode-bin"))
# Package compiler and linker metadata toolkit
brew "pkgconf"
# Fast, disk space efficient package manager
brew "pnpm"
# Fast, efficient and secure backup program
brew "restic"
# rsync for cloud storage — `hl` (scripts/hl) drives it against the HomeLab S3 gateway
brew "rclone"
# Search tool like grep and The Silver Searcher
brew "ripgrep"
# Monitors sleep, wakeup, and idleness of a Mac
brew "sleepwatcher"
# Cross-shell prompt — config/starship.toml. Uses ANSI color names rather than
# hex so it follows the one-dark/one-light terminal switch without a second
# config; see that file's header.
brew "starship"
# Send macOS User Notifications from the command-line
brew "terminal-notifier"
# OCR (Optical Character Recognition) engine
brew "tesseract"
# Terminal multiplexer — deliberate fallback, not the daily driver. herdr owns
# the workspace model; tmux is what you reattach with if herdr (pre-1.0) breaks.
brew "tmux"
# Validating, recursive, caching DNS resolver
brew "unbound"
# Extremely fast Python package installer and resolver, written in Rust
brew "uv"
# Executes a program periodically, showing output fullscreen
brew "watch"
# Generate Xcode projects from a YAML spec (iris `apple/project.yml`; .xcodeproj is gitignored)
brew "xcodegen"
# Shell extension to navigate your filesystem faster
brew "zoxide"
# Incredibly fast JavaScript runtime, bundler, transpiler and package manager - all in one.
brew "oven-sh/bun/bun"
# Worktree Plus - Enhanced worktree management with automated setup and hooks
brew "satococoa/tap/wtp"
# Multi-track audio editor and recorder
cask "audacity"
# Downloads videos and audio from websites
cask "clipgrab"
# OpenAI Codex CLI — the non-Anthropic second opinion, pointed at the IU
# unified endpoint (config/codex/, launched with `cx`/`cxa`). Cask, so it is
# reported by `make brew-upgrade` and never auto-upgraded.
cask "codex"
# All-in-one toolbox for developers
cask "devutils"
# Both are declared on purpose — the Nerd Font cask does NOT register a family
# called "JetBrains Mono", it registers "JetBrainsMono Nerd Font [Mono]". Any
# app still configured with the plain name (editors, IDEs) would silently fall
# back to a system font if the plain cask were dropped.
cask "font-jetbrains-mono"
# Terminal font. herdr's sidebar state icons and starship's prompt glyphs are
# Nerd Font codepoints and render as tofu without it. Ghostty is pointed at the
# "Mono" family so glyphs stay single-width and cannot push herdr's
# column-aligned sidebar rows out of alignment.
cask "font-jetbrains-mono-nerd-font"
# The terminal. Reads ~/.config/ghostty/config (config/ghostty/config here) —
# see that file's header for the full settings list (theme, font, padding).
#
# The cask installs NO binary on PATH (app bundle + manpages + completions
# only), so `make theme` resolves /Applications/Ghostty.app explicitly rather
# than trusting PATH.
cask "ghostty"
# Hermes Agent desktop app. The bundle is Nous's setup shell (bundle version
# 0.0.1 at every release); the cask version tracks the website label.
cask "hermes-desktop"
# Horizontal and vertical rulers
cask "free-ruler"
# Keep your computer awake
cask "jiggler"
# Music streaming service
cask "spotify"
# The launcher (Raycast's replacement since 2026-09-26): native SwiftUI, runs
# Raycast extensions in JavaScriptCore, AGPL-3.0, single maintainer, third-party
# tap (trusted by `_setup-packages` like the others). Settings are tracked in
# config/tinycast/defaults.json (`make tinycast-check`). It owns the keyboard
# layer since 2026-10-16: its Hyper Key turns Caps Lock into ⌃⌥⌘ (a per-keyboard
# HID remap to F18 plus an event tap) and every Hyper+letter launcher is one of
# its hotkeys. Replaced Karabiner-Elements, which only did that remap. Verified
# on the MacBook's built-in keyboard; macOS 26 event taps were measured blind to
# EXTERNAL keyboards with Hyperkey on the mini (2026-07-28) — if the Magic
# Keyboard turns out dead, reinstall karabiner-elements for the remap only.
# The beta channel on purpose: it draws extension menu-bar commands and gives
# extension views more room (stable 0.11.3 does neither) — separate app, own
# com.tinycast.app.beta domain, self-updates within the beta channel.
cask "abue-ammar/tinycast/tinycast@beta"
# Herdr GPUI — native desktop client for herdr (unaffiliated, third-party tap),
# attached to the mini through the saved `herdr machine` profile. Its config is
# ~/.config/herdr/config-gpui.local.toml (machine-local, untracked — the app
# and com.jkrumm.appearance-sync both rewrite it); the light/dark theme flip is
# scripts/appearance-sync.sh, since the app has no system-appearance support.
cask "penso/tap/herdr-gpui"
# Multimedia player
cask "vlc"
