#!/bin/bash
# Hermetic suite for doctor.sh's grading: "clean" needs zero warnings, a warning is counted and named in the last line,
# info never counts, and only a failure turns the exit code. Runs single sections (DOCTOR_SECTIONS) against a stub brew.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/cfg/secrets"
printf 'x' > "$TMP/cfg/secrets/backend"   # no mini/MacBook-only sections

pass=0; fail=0
assert_eq() { if [ "$2" = "$3" ]; then echo "  ok  $1"; pass=$((pass + 1)); else echo "  FAIL $1 (expected [$2], got [$3])"; fail=$((fail + 1)); fi; }

# stub brew: `outdated --quiet` lists $OUTDATED packages, `list --pinned` prints $PINNED
cat > "$TMP/bin/brew" <<'STUB'
#!/bin/sh
case "$1" in
  outdated) i=0; while [ "$i" -lt "${OUTDATED:-0}" ]; do echo "pkg$i"; i=$((i + 1)); done ;;
  list) case "$2" in
      --pinned) for p in $PINNED; do echo "$p"; done ;;
      --formula) case " ${INSTALLED:-$PINNED} " in *" $4 "*) echo "$4 1.0" ;; *) exit 1 ;; esac ;;
    esac ;;
esac
STUB
chmod +x "$TMP/bin/brew"
HELD=$(sed -n 's/^HELD=(\(.*\))$/\1/p' "$HERE/brew-upgrade.sh")

# doctor <sections> [ENV=val…] -- [flags]: the human output, or with --json its last line
doctor() { local sections=$1; shift; env PATH="$TMP/bin:$PATH" XDG_CONFIG_HOME="$TMP/cfg" DOCTOR_SECTIONS="$sections" "$@" bash "$HERE/doctor.sh" --local; }
last() { printf '%s\n' "$1" | tail -n 1 | sed 's/^ *//'; }

# every pin held, a pile of outdated packages: info, never a warning
out=$(doctor brew PINNED="$HELD" OUTDATED=26); rc=$?
assert_eq "zero warnings: the last line says clean" "2 passed, 1 info — clean." "$(last "$out" | sed -E 's/^[0-9]+ passed/2 passed/')"
assert_eq "zero warnings: exit 0" 0 "$rc"

# one injected warning: a pin that is not on the HELD list
out=$(doctor brew PINNED="$HELD foo"); rc=$?
assert_eq "one warning: counted in the last line" "0 passed, 1 warnings, 1 info." "$(last "$out")"
assert_eq "one warning: never says clean" 0 "$(printf '%s\n' "$out" | grep -c 'clean\.')"
assert_eq "one warning: a warning does not fail the run" 0 "$rc"
assert_eq "one warning: --json carries the counts" '{"passed":0,"failed":0,"warnings":1,"info":1}' "$(last "$(env PATH="$TMP/bin:$PATH" XDG_CONFIG_HOME="$TMP/cfg" DOCTOR_SECTIONS=brew PINNED="$HELD foo" bash "$HERE/doctor.sh" --local --json)")"

# a held formula this machine does not have is not expected to be pinned (brew-upgrade.sh skips it)
out=$(doctor brew PINNED="caddy" INSTALLED="caddy")
assert_eq "an uninstalled held formula is not a warning" 0 "$(printf '%s\n' "$out" | grep -c 'expected')"

# a held formula whose pin is gone is the same warning
out=$(doctor brew PINNED="caddy" INSTALLED="$HELD")
assert_eq "a missing pin warns too" 1 "$(printf '%s\n' "$out" | grep -c 'expected .*HELD')"

# an unrecognised backend is a warning, named
assert_eq "an unrecognised backend warns" "0 passed, 1 warnings, 0 info." "$(last "$(doctor backend)")"

# a WARN row of claude-accounts-verify is a warning (0 FAIL is not clean), and a failure row still fails the run
mkdir -p "$TMP/dot/scripts/lib"
printf 'core_up() { return 1; }\n' > "$TMP/dot/scripts/lib/core-up.sh"
printf '#!/bin/bash\necho "PASS  auth/iu   fine"\necho "WARN  version   9.9.9 is not stamped"\necho "---"\necho "0 FAIL, 1 WARN"\n' > "$TMP/dot/scripts/claude-accounts-verify.sh"
printf 'cache' > "$TMP/cfg/secrets/backend"
out=$(doctor claude_accounts DOTFILES_DIR="$TMP/dot" HC_TERMINAL_ID=x); rc=$?
assert_eq "a verify WARN row is counted" "0 passed, 1 warnings, 0 info." "$(last "$out")"
assert_eq "a verify WARN row is named" 1 "$(printf '%s\n' "$out" | grep -c 'claude accounts .*9.9.9 is not stamped')"
printf '#!/bin/bash\necho "FAIL  auth/iu   broken"\necho "---"\necho "1 FAIL, 0 WARN"\nexit 1\n' > "$TMP/dot/scripts/claude-accounts-verify.sh"
out=$(doctor claude_accounts DOTFILES_DIR="$TMP/dot" HC_TERMINAL_ID=x); rc=$?
assert_eq "a failure row fails the run" 1 "$rc"


# agent notes: the command on PATH and the path to the other machine; an unreachable MacBook is a warning, never a failure
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/agent-note"; chmod +x "$TMP/bin/agent-note"
printf '#!/bin/sh\ncase "$*" in *term-ls*) [ -n "$SSH_RC" ] && exit "$SSH_RC"; echo "$SSH_OUT" ;; esac\n' > "$TMP/bin/ssh"; chmod +x "$TMP/bin/ssh"
printf 'cache' > "$TMP/cfg/secrets/backend"
out=$(doctor agent_notes SSH_OUT='[{"id":"t7"}]'); rc=$?
assert_eq "agent notes: term-ls answers" "2 passed, 0 info — clean." "$(last "$out")"
out=$(doctor agent_notes SSH_RC=255); rc=$?
assert_eq "agent notes: MacBook unreachable is a warning" "1 passed, 1 warnings, 0 info." "$(last "$out")"
assert_eq "agent notes: …and does not fail the run" 0 "$rc"
out=$(doctor agent_notes SSH_RC=126)
assert_eq "agent notes: a gate without term-ls is a warning that names the fix" 1 "$(printf '%s\n' "$out" | grep -c 'ssh iumac dotfiles-sync')"
out=$(doctor agent_notes SSH_OUT='oops')
assert_eq "agent notes: a non-list answer warns" "1 passed, 1 warnings, 0 info." "$(last "$out")"
rm -f "$TMP/bin/agent-note"
out=$(env PATH="/usr/bin:/bin" XDG_CONFIG_HOME="$TMP/cfg" DOCTOR_SECTIONS=agent_notes bash "$HERE/doctor.sh" --local); rc=$?
assert_eq "agent notes: a missing command fails the run" 1 "$rc"

echo
if [ "$fail" -ne 0 ]; then echo "$fail failed, $pass passed"; exit 1; fi
echo "all $pass passed"
