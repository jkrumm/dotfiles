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
# Simple, modern, secure file encryption
brew "age"
# Editor of encrypted files (paired with age for the headless secrets cache)
brew "sops"
# Schema-validated .env loader — resolver plugins (1Password, etc.) + secret redaction
brew "varlock"
# Shell script static analysis — gates the secrets-run shim (make secrets-lint)
brew "shellcheck"
# Codec library for encoding and decoding AV1 video streams
brew "aom"
# Interpreted, interactive, object-oriented programming language
brew "python@3.14"
# B2 Cloud Storage Command-Line Tools
brew "b2-tools"
# Limit max battery charge on Apple silicon (MacBook only — see `make batt-setup`)
brew "batt"
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
# since the MacBook can attach either through mosh or with `herdr --remote`.
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
# Roaming UDP terminal — one of two ways into the mini (the other is herdr's own
# `--remote`, which is ssh). Survives lid-close and network changes that kill TCP,
# and predictive echo hides latency on bad links. Cannot multiplex or
# port-forward: always one mosh connection into herdr.
brew "mosh"
# Libraries for security-enabled client and server applications
brew "nss"
# Package compiler and linker metadata toolkit
brew "pkgconf"
# Fast, disk space efficient package manager
brew "pnpm"
# Fast, efficient and secure backup program
brew "restic"
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
# The daily-driver terminal — a macOS-native multiplexer built ON Ghostty, so it
# reads Ghostty's own config paths and shares the look declared in
# config/ghostty/. Was installed by hand for a long time and therefore invisible
# to `brew bundle` / `make brew-check`; adopted into the manifest 2026-07-27
# (`brew install --cask --adopt cmux` if a stray /Applications/cmux.app exists).
# It also supplies the `ghostty` binary that lands on PATH — see the ghostty cask.
cask "cmux"
# AI code review CLI
cask "coderabbit"
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
# Bare Ghostty, alongside cmux rather than instead of it — the plain terminal for
# when the multiplexer is not wanted, and the upstream reference when a rendering
# question is "is this cmux or is this Ghostty?".
#
# It needs NO config of its own. Measured on Ghostty 1.3.1: both config paths are
# read and MERGED, with ~/Library/Application Support/com.mitchellh.ghostty/config
# winning conflicts over ~/.config/ghostty/config. dotfiles owns both, so Ghostty
# resolves the same One Zinc theme, font and padding as cmux automatically.
#
# The cask installs NO binary on PATH (app bundle + manpages + completions only),
# so `ghostty` on PATH stays cmux's bundled copy. `make theme` therefore resolves
# /Applications/Ghostty.app explicitly rather than trusting PATH.
cask "ghostty"
# Horizontal and vertical rulers
cask "free-ruler"
# Keep your computer awake
cask "jiggler"
# Knowledge base that works on top of a local folder of plain text Markdown files
cask "obsidian"
# Monitors the computer system and optimises its performance
cask "sensei"
# Music streaming service
cask "spotify"
# Multimedia player
cask "vlc"
# Rust-based terminal
cask "warp"
