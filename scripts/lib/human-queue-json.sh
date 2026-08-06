#!/usr/bin/env bash
# human-queue-json.sh — JSON helpers shared by ask-human.sh (mini) and
# human-queue.sh (MacBook). Extracted 2026-08-06: both scripts run out of a
# full `dotfiles` checkout regardless of which machine they're on, so "the two
# scripts run on different machines, sharing via source isn't an option" — the
# comment that used to justify copy-pasting these — was never actually true.
#
# No `jq` hard dependency: the mini's cache-backend allowlist is narrow and
# must not gain a package requirement for a queue file. jq is used
# opportunistically when present, hand-rolled JSON otherwise.
#
# Usage:
#   # shellcheck source=lib/human-queue-json.sh
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/human-queue-json.sh"
# Callers must already define their own `die()` — json_field's
# escape-sequence refusal calls it.

# JSON-string-encode $1, quotes included in the output — so every call site is
# `"field":$(json_escape "$value")`, never hand-adding the surrounding quotes.
# jq -Rs (raw input, slurp) turns arbitrary text into one valid JSON string;
# the fallback covers the four bytes that break a hand-built JSON string
# (backslash, double quote, newline, tab, CR) — everything else in a shell
# command or a short text note is printable ASCII.
json_escape() {
  local s="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$s" | jq -Rs '.'
    return
  fi
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '"%s"\n' "$s"
}

# Read one string field out of a flat (non-nested) JSON string. Good enough
# for our own request/result shape, not a general parser. Takes the JSON BODY
# as $1, not a file path — the two former copies of this function disagreed
# on exactly that (one read a file, one read a string); a caller reading from
# disk now passes `"$(cat "$file")"` so both ask-human.sh (request files on
# the mini) and human-queue.sh (a string already fetched over ssh) go through
# one interface instead of two that could quietly drift apart.
json_field() {
  local json="$1" field="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r --arg f "$field" '.[$f] // empty' 2>/dev/null
    return
  fi
  # The sed pattern below can't tell an escaped quote (\") from the real
  # closing one, so a value carrying one would come back silently truncated
  # and wrong instead of merely incomplete — worse than failing. Refuse
  # instead of guessing: `jq` is in the Brewfile, this path is a last resort.
  if printf '%s' "$json" | grep -qE "\"$field\"[[:space:]]*:[[:space:]]*\"[^\"]*\\\\"; then
    die "jq is required to read a request whose \"$field\" value contains an escape sequence"
  fi
  printf '%s' "$json" | sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n1
}

# Strip control bytes out of a field before it ever reaches a terminal.
#
# WHY THIS EXISTS: every field this queue displays was WRITTEN ON THE MINI —
# the design's own stated adversary — and human-queue.sh shows it immediately
# before a typed-'yes' prompt that then executes with the human's full
# privileges. json_escape above only guards the four bytes that break a
# hand-built JSON string; a raw ESC (0x1B) or other control byte sails through
# it untouched. A crafted ANSI/OSC escape sequence in a `cmd` or `text` field
# can therefore make the terminal SHOW something different from what actually
# runs once confirmed — which defeats the entire point of the confirmation
# step. Keeping `[:print:]` plus newline/tab (so multi-line text stays
# legible) closes that gap.
#
# Display only. The value that gets executed (`bash -c "$cmd_value"` in
# human-queue.sh's cmd_run) must stay the untouched original — callers
# compare the printable() output against the raw value and warn when they
# differ, rather than silently running something other than what was shown.
printable() {
  printf '%s' "$1" | tr -dc '[:print:]\n\t'
}
