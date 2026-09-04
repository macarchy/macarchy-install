#!/bin/bash
# tests/test_doctor_notify.sh — doctor.sh --notify is now unattended runtime
# code with an exit-code contract, run by macarchy-doctor.service at every
# login. Hermetic: a temp HOME plus PATH stubs, so it needs no compositor, no
# notification daemon and no Apple hardware.
#
# The one branch this cannot exercise is the silence-when-healthy line
# `(( FAIL )) || exit 0`: from a temp HOME the checks against /etc/udev, a
# masked tiny-dfr and the battery sysfs node can never all pass. Read it in
# review.
set -uo pipefail
cd "$(dirname "$0")/.."

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" SENT="$TMP/sent"
mkdir -p "$HOME" "$TMP/bin"
export PATH="$TMP/bin:$PATH"

fails=0
check() { local name=$1; shift; if "$@"; then echo "ok   $name"; else echo "FAIL $name"; fails=$((fails+1)); fi; }

# One line per notification even though the body is multi-line, so "exactly one
# toast" is a line count and not a guess.
for stub in omarchy-notification-send notify-send; do
	printf '#!/bin/bash\nprintf "%%s\\n" "$(printf "%%s " "$@" | tr "\\n" " ")" >> "$SENT"\n' > "$TMP/bin/$stub"
done
printf '#!/bin/bash\nexit 0\n' > "$TMP/bin/omarchy-notification-wait"
# Absent, not broken: no user manager, no compositor, no tank in a temp HOME.
for stub in systemctl pgrep omarchy-aquarium-toggle; do
	printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/$stub"
done
chmod +x "$TMP/bin"/*

# --- (a) one clickable toast, no stdout, exit 0 -----------------------------
unset WAYLAND_DISPLAY
out=$(./doctor.sh --notify); rc=$?
check "notify exits 0"        [ "$rc" = 0 ]
check "notify prints nothing" [ -z "$out" ]
check "exactly one toast"     [ "$(wc -l < "$SENT")" = 1 ]
check "toast is clickable"    grep -q -- '--exec' "$SENT"
# A real label the plain run also prints, so the body is the checks' own words.
check "toast carries a miss"  grep -q 'macarchy-dfr' "$SENT"

# --- (b) a deliberately-off tank is not a fault -----------------------------
mkdir -p "$XDG_STATE_HOME/omarchy-aquarium"
echo off > "$XDG_STATE_HOME/omarchy-aquarium/enabled"
out=$(WAYLAND_DISPLAY=wayland-9 ./doctor.sh)
check "running-now ran on WAYLAND_DISPLAY" grep -q 'running now' <<<"$out"
check "off tank counts as ok" grep -q 'ok.*aquarium off' <<<"$out"
WAYLAND_DISPLAY=wayland-9 ./doctor.sh --notify
check "the off tank did toast (not vacuous)" [ "$(wc -l < "$SENT")" = 2 ]
check "aquarium off never toasts" grep -qv aquarium <<<"$(tail -1 "$SENT")"

# --- (c) the human-facing contract did not drift ----------------------------
out=$(./doctor.sh); rc=$?
check "plain run exits non-zero" [ "$rc" != 0 ]
check "plain run prints MISS"    grep -q 'MISS' <<<"$out"
check "plain run prints summary" grep -q 'ok, .* missing' <<<"$out"

exit $((fails > 0))
