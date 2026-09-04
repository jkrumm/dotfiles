#!/usr/bin/env bash
# brew-service — resolve the plist / label / launchctl target of a Homebrew
# service, under EITHER of the two names Homebrew has used for it.
#
# WHY THIS EXISTS. Homebrew 6 renamed every service label it writes:
#
#   old   ~/Library/LaunchAgents/homebrew.mxcl.<name>.plist   Label homebrew.mxcl.<name>
#   new   ~/Library/LaunchAgents/sh.brew.<name>.plist         Label sh.brew.<name>
#
# The rename is NOT applied at upgrade time. It happens on the next `brew
# services start|restart <name>`, which writes the `sh.brew.` file and DELETES
# the `homebrew.mxcl.` one. So a machine sits on the old name indefinitely and
# flips the moment anything restarts the service — brew itself accepts both and
# globs `{homebrew.*,sh.brew.*}` (Homebrew/services/cli.rb).
#
# Every consumer here hardcoded the old path, and the failure is the silent kind
# this repo keeps paying for: the converge steps (`_colima-supervise`,
# `_herdr-supervise`) test `[ -f "$PLIST" ]` first and print "plist absent —
# nothing to supervise", exit 0, GREEN — while the freshly written stock plist
# carries exactly the inverted `KeepAlive { SuccessfulExit = true }` and the
# stock `colima start -f` those steps exist to repair. Reproduced on the MacBook
# after a `make colima-restart`, 2026-09-04. The boot path disarms itself and
# every liveness probe stays happy until the next dirty shutdown.
#
# So: one resolver, both names accepted, callers ask by SERVICE NAME and never
# spell a label. If Homebrew renames again, this file is the single place that
# is wrong.
#
# Sourceable (no side effects, bash 3.2 — devhost-health-check.sh runs under
# Apple's /bin/bash) or callable as a CLI, which is what the Makefile uses since
# its recipes run under /bin/sh:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/brew-service.sh"
#   brew_service_plist colima            # → ~/Library/LaunchAgents/sh.brew.colima.plist
#   brew_service_plist caddy system      # → /Library/LaunchDaemons/homebrew.mxcl.caddy.plist
#
#   bash scripts/lib/brew-service.sh plist    colima
#   bash scripts/lib/brew-service.sh label    colima
#   bash scripts/lib/brew-service.sh expected colima
#   bash scripts/lib/brew-service.sh target   herdr
#
# Domain is `gui` (default, LaunchAgents) or `system` (LaunchDaemons).
# Every lookup exits 1 and prints NOTHING when no plist exists under either
# name — callers must treat that as "unresolved", never as "absent, fine":
# a loaded service with no resolvable plist is the disarmed state above.
#
# Dirs are overridable so the resolver can be tested against a scratch dir
# without touching a live boot path.

BREW_SERVICE_GUI_DIR="${BREW_SERVICE_GUI_DIR:-$HOME/Library/LaunchAgents}"
BREW_SERVICE_SYSTEM_DIR="${BREW_SERVICE_SYSTEM_DIR:-/Library/LaunchDaemons}"
BREW_SERVICE_PLISTBUDDY="${BREW_SERVICE_PLISTBUDDY:-/usr/libexec/PlistBuddy}"

# Internal: echo the directory for a domain. Unknown domain is a caller bug, not
# a runtime condition — say so on stderr rather than silently probing $HOME.
_brew_service_dir() {
  case "${1:-gui}" in
    gui|"")  printf '%s\n' "$BREW_SERVICE_GUI_DIR" ;;
    system)  printf '%s\n' "$BREW_SERVICE_SYSTEM_DIR" ;;
    *)       echo "brew-service: unknown domain '$1' (want gui|system)" >&2; return 2 ;;
  esac
}

# The path of the plist that EXISTS, new name preferred over old. Prints nothing
# and returns 1 if neither is there.
brew_service_plist() {
  local name="${1:-}" domain="${2:-gui}" dir
  [ -n "$name" ] || { echo "brew-service: brew_service_plist needs a service name" >&2; return 2; }
  dir=$(_brew_service_dir "$domain") || return 2
  if [ -f "$dir/sh.brew.$name.plist" ]; then
    printf '%s\n' "$dir/sh.brew.$name.plist"
  elif [ -f "$dir/homebrew.mxcl.$name.plist" ]; then
    printf '%s\n' "$dir/homebrew.mxcl.$name.plist"
  else
    return 1
  fi
}

# The path brew WOULD write for a fresh start today. For install targets that
# CREATE a file (the caddy daemon template) — never for asserting an existing
# one, which is brew_service_plist's job.
brew_service_expected_plist() {
  local name="${1:-}" domain="${2:-gui}" dir
  [ -n "$name" ] || { echo "brew-service: brew_service_expected_plist needs a service name" >&2; return 2; }
  dir=$(_brew_service_dir "$domain") || return 2
  printf '%s\n' "$dir/sh.brew.$name.plist"
}

# The Label as launchd knows it — read from the file rather than derived from
# its name, because those two can disagree: `make caddy-boot-order` installs a
# RENDERED template, and a stale template would otherwise have us bootout a
# label nothing answers to. Basename fallback for an unreadable/label-less plist.
brew_service_label() {
  local name="${1:-}" domain="${2:-gui}" plist label base
  plist=$(brew_service_plist "$name" "$domain") || return $?
  label=$("$BREW_SERVICE_PLISTBUDDY" -c 'Print :Label' "$plist" 2>/dev/null) || label=""
  if [ -z "$label" ]; then
    base=${plist##*/}
    label=${base%.plist}
  fi
  printf '%s\n' "$label"
}

# `gui/<uid>/<label>` or `system/<label>` — the argument launchctl
# print/bootout/bootstrap actually take.
brew_service_launchctl_target() {
  local name="${1:-}" domain="${2:-gui}" label
  label=$(brew_service_label "$name" "$domain") || return $?
  if [ "${domain:-gui}" = "system" ]; then
    printf 'system/%s\n' "$label"
  else
    printf 'gui/%s/%s\n' "$(/usr/bin/id -u)" "$label"
  fi
}

# CLI mode — only when executed, never when sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  case "${1:-}" in
    plist)    shift; brew_service_plist "$@" ;;
    expected) shift; brew_service_expected_plist "$@" ;;
    label)    shift; brew_service_label "$@" ;;
    target)   shift; brew_service_launchctl_target "$@" ;;
    *) echo "usage: $(basename "$0") plist|expected|label|target <service> [gui|system]" >&2; exit 2 ;;
  esac
fi
