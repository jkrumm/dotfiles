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
# Send macOS User Notifications from the command-line
brew "terminal-notifier"
# OCR (Optical Character Recognition) engine
brew "tesseract"
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
# AI code review CLI
cask "coderabbit"
# All-in-one toolbox for developers
cask "devutils"
cask "font-jetbrains-mono"
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
