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

T="$UNITS/macarchy-failed@.service"

# A macarchy unit that names the notifier, with no template beside it.
printf '[Unit]\nOnFailure=macarchy-failed@%%n.service\n' > "$UNITS/macarchy-probe.service"
out=$(WAYLAND_DISPLAY= ./doctor.sh 2>&1)
check "a named-but-absent notifier is a MISS" grep -q 'MISS.*failure notifier' <<<"$out"
check "and it says which unit needs it"       grep -q 'macarchy-probe' <<<"$out"

# Same unit, template present.
printf '[Unit]\nDescription=notifier\n' > "$T"
out=$(WAYLAND_DISPLAY= ./doctor.sh 2>&1)
check "reachable notifier is ok"              grep -q 'ok.*failure notifier' <<<"$out"
check "and it says what it verified"          grep -qE 'failure notifier \(1 macarchy unit' <<<"$out"

# A SPACE-SEPARATED list: systemd allows it, and stopping at the first target is
# the silent pass this check exists to end.
printf '[Unit]\nOnFailure=macarchy-failed@%%n.service other-notify@%%n.service\n' > "$UNITS/macarchy-probe.service"
out=$(WAYLAND_DISPLAY= ./doctor.sh 2>&1)
check "the second target is checked too"      grep -q 'other-notify@.service needed by' <<<"$out"

# A THIRD-PARTY unit is none of macarchy's business: jarvis, voxtype and aikit-sync
# all live in this directory, and blaming macarchy-install for a template THEY do
# not ship is a false MISS that reds CI and names the wrong installer.
printf '[Unit]\nOnFailure=macarchy-failed@%%n.service\n' > "$UNITS/macarchy-probe.service"
printf '[Unit]\nOnFailure=somebody-elses@%%n.service\n' > "$UNITS/voxtype.service"
out=$(WAYLAND_DISPLAY= ./doctor.sh 2>&1)
check "a third-party unit is not our MISS"    bash -c '! grep -q "somebody-elses" <<<"$1"' _ "$out"
check "and ours still reports ok"             grep -q 'ok.*failure notifier' <<<"$out"
rm -f "$UNITS/voxtype.service"

# A TIMER declaring it counts: this suite ships macarchy-*.timer units.
printf '[Unit]\nOnFailure=macarchy-failed@%%n.service\n' > "$UNITS/macarchy-probe.timer"
out=$(WAYLAND_DISPLAY= ./doctor.sh 2>&1)
check "a .timer is scanned too"               grep -qE 'failure notifier \(2 macarchy units' <<<"$out"
rm -f "$UNITS/macarchy-probe.timer"

# Leading whitespace is legal in a unit file.
printf '[Unit]\n   OnFailure=macarchy-failed@%%n.service\n' > "$UNITS/macarchy-probe.service"
out=$(WAYLAND_DISPLAY= ./doctor.sh 2>&1)
check "indented OnFailure= is parsed"         grep -qE 'failure notifier \(1 macarchy unit' <<<"$out"

# Nothing declares it -- but the template's own absence is STILL a MISS. Otherwise a
# run whose repo clones failed leaves no units and the check congratulates itself.
rm -f "$UNITS/macarchy-probe.service"
out=$(WAYLAND_DISPLAY= ./doctor.sh 2>&1)
check "no declarations, template present: ok" grep -q 'no macarchy unit declares' <<<"$out"
rm -f "$T"
out=$(WAYLAND_DISPLAY= ./doctor.sh 2>&1)
check "no declarations, no template: MISS"    grep -q 'MISS.*is not installed' <<<"$out"

(( fails == 0 )) && echo "all ok" || echo "$fails failed"
exit $(( fails > 0 ))
