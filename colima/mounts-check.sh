#!/usr/bin/env bash
# Does the default colima VM run the mounts colima/mounts.mini.txt names, in the mode it names?
#   mounts-check.sh <mounts list>   exit 0 when they match; else name each gap, exit 1
# apply-mounts.sh writes the list into colima.yaml, but only a VM START applies it: a reboot or a plain
# `colima start` keeps the old mounts, and a new bind mount then shows an EMPTY directory in the
# container, with no error. This reads the running VM's virtiofs mounts and compares them with the list.
#   env: COLIMA_BIN, COLIMA_PROFILE (default)
set -uo pipefail

colima="${COLIMA_BIN:-/opt/homebrew/bin/colima}"
profile="${COLIMA_PROFILE:-default}"
list="${1:?usage: mounts-check.sh <mounts list>}"
[ -f "$list" ] || { echo "mounts-check: $list is missing"; exit 1; }

guest=$("$colima" ssh -p "$profile" -- cat /proc/mounts 2>/dev/null) \
  || { echo "colima VM '$profile' mounts unreadable (is the VM running? make colima-start)"; exit 1; }
virtiofs=$(printf '%s\n' "$guest" | awk '$3 == "virtiofs" { print $2, ($4 ~ /(^|,)ro(,|$)/) ? "ro" : "rw" }')

problems=""
names=""
add() { problems="${problems}${problems:+; }$1"; }
while read -r path mode _; do
  case "$path" in '' | \#*) continue ;; esac
  case "$mode" in rw | ro) ;; *) add "list row '$path $mode' needs rw or ro (a path with a space is not supported)"; continue ;; esac
  path="${path/#\~/$HOME}"
  names="${names}${path}"$'\n'
  got=$(printf '%s\n' "$virtiofs" | awk -v p="$path" '$1 == p { print $2; exit }')
  if [ -z "$got" ]; then
    add "$path is not mounted"
  elif [ "$got" != "$mode" ]; then
    add "$path is $got, the list says $mode"
  fi
done <"$list"

# The other way round: a mount under $HOME that the list no longer names is still reachable from containers.
while read -r target _; do
  case "$target" in "$HOME"/*) ;; *) continue ;; esac
  printf '%s' "$names" | grep -qxF -- "$target" || add "$target is mounted, the list does not name it"
done <<<"$virtiofs"

[ -z "$problems" ] && exit 0
echo "colima VM '$profile' mounts differ from colima/mounts.mini.txt: $problems (fix: make colima-restart, from the main checkout)"
exit 1
