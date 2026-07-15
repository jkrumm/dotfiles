# Secrets — headless SOPS+age cache baseline (cache-backend machines only)
#
# On a machine marked as the `cache` backend (~/.config/secrets/backend), this
# materializes the always-on baseline set (dotfiles-private/baseline.env.tpl)
# into every new shell's ambient env — resolved headlessly from the encrypted
# cache. See ~/SourceRoot/dotfiles-private/docs/design.md.
#
# Fails visible: any missing piece (marker, secrets-run, cache file,
# decrypt/preflight failure) prints a short warning and never blocks shell
# startup. secrets-run's stderr is captured to a temp and surfaced when
# non-empty — this is the channel where the allowlist prints its "cache
# contained undeclared key(s) — DROPPED (tampering)" warning, so it must NOT be
# swallowed. Skips everything immediately when the marker isn't `cache`.

if [[ "$(cat "$HOME/.config/secrets/backend" 2>/dev/null)" == "cache" ]]; then
  if command -v secrets-run >/dev/null 2>&1; then
    _secrets_cache_err="$(mktemp "${TMPDIR:-/tmp}/secrets-cache.XXXXXX")"
    _secrets_cache_export="$(secrets-run export 2>"$_secrets_cache_err")"
    # shellcheck disable=SC2181 -- checking the prior command substitution's
    # status directly would require running secrets-run a second time.
    if [[ $? -eq 0 ]]; then
      eval "$_secrets_cache_export"
      # Surface tamper/staleness warnings that secrets-run wrote to stderr even
      # on a successful export (e.g. dropped undeclared keys).
      [[ -s "$_secrets_cache_err" ]] && cat "$_secrets_cache_err" >&2
    else
      echo "! secrets-cache: failed to load baseline secrets — run 'secrets-run export' to see why" >&2
      [[ -s "$_secrets_cache_err" ]] && cat "$_secrets_cache_err" >&2
    fi
    command rm -f "$_secrets_cache_err"
    unset _secrets_cache_export _secrets_cache_err
  fi
fi
