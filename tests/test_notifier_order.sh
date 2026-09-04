#!/bin/bash
# tests/test_notifier_order.sh — the failure notifier has to exist before anything
# can name it, and the doctor has to be able to tell reachable from merely present.
#
# Three units declare `OnFailure=macarchy-failed@%n.service`: macarchy-touchbar,
# macarchy-auto-appearance and macarchy-bar-contrast. All three are installed by
# their own repos, from the component steps in the middle of install.sh. The
# template that answers them used to be installed in the second-to-last section,
# so on a FIRST install every failure before that point was dropped with
#   Failed to enqueue OnFailure= job, ignoring: Unit macarchy-failed@….service not found
# while doctor.sh reported `ok failure notifier` throughout -- it only tested that
# the file existed. #12.
set -uo pipefail
cd "$(dirname "$0")/.."

fails=0
check() { local name=$1; shift; if "$@"; then echo "ok   $name"; else echo "FAIL $name"; fails=$((fails+1)); fi; }
lineno() { grep -n "$1" install.sh | head -1 | cut -d: -f1; }

# --- ordering, read off install.sh itself ------------------------------------
notifier=$(lineno 'systemd/macarchy-failed@\.service')
sanity=$(lineno '^say "Checking this machine"')
repos=$(lineno '^say "Fetching the macarchy repos')
core=$(lineno '^say "Installing the macarchy-core suite')

check "the notifier install is found"      [ -n "$notifier" ]
check "it comes after the sanity checks"   [ "$notifier" -gt "$sanity" ]
check "it comes BEFORE the repo clone"     [ "$notifier" -lt "$repos" ]
check "and before any component install"   [ "$notifier" -lt "$core" ]

# --- the doctor's check, exercised hermetically ------------------------------
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state"
UNITS="$HOME/.config/systemd/user"; mkdir -p "$UNITS" "$TMP/bin"
export PATH="$TMP/bin:$PATH"
for stub in pgrep omarchy-aquarium-toggle systemctl journalctl omarchy; do
	printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/$stub"
done
chmod +x "$TMP/bin"/*

# A unit that names the notifier, with no template beside it.
printf '[Unit]\nOnFailure=macarchy-failed@%%n.service\n' > "$UNITS/some-daemon.service"
out=$(WAYLAND_DISPLAY= ./doctor.sh 2>&1)
check "a named-but-absent notifier is a MISS" grep -q 'MISS.*failure notifier' <<<"$out"
check "and it says which unit needs it"       grep -q 'some-daemon' <<<"$out"

# Same unit, template present.
printf '[Unit]\nDescription=notifier\n' > "$UNITS/macarchy-failed@.service"
out=$(WAYLAND_DISPLAY= ./doctor.sh 2>&1)
check "reachable notifier is ok"              grep -q 'ok.*failure notifier' <<<"$out"
check "and it says what it verified"          grep -qE 'failure notifier \(1 unit' <<<"$out"

# Nothing declares OnFailure= at all: say so rather than passing silently.
rm -f "$UNITS/some-daemon.service"
out=$(WAYLAND_DISPLAY= ./doctor.sh 2>&1)
check "no declarations: says so"              grep -q 'failure notifier (nothing declares' <<<"$out"
check "no declarations: not a MISS"           bash -c '! grep -q "MISS.*failure notifier" <<<"$1"' _ "$out"

(( fails == 0 )) && echo "all ok" || echo "$fails failed"
exit $(( fails > 0 ))
