#!/bin/bash
# tests/test_doctor_touchbar_modules.sh — the doctor's Touch Bar module check.
#
# A module that fails to load is the one macarchy breakage nothing else
# reports: the daemon logs it once and then runs without that widget, so the
# unit stays active, no toast fires, and the bar just quietly lacks a button.
# It is what a rename in macarchy-touchbar costs jarvis, which ships a module
# and is not even in REPOS.
#
# The branch that matters most is (b): the daemon hot-reloads on the file
# change, so a failure repaired later in the SAME boot must not be reported.
# Hermetic: temp HOME plus PATH stubs, no compositor and no Apple hardware.
set -uo pipefail
cd "$(dirname "$0")/.."

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" WAYLAND_DISPLAY=wayland-0
mkdir -p "$HOME" "$TMP/bin"
export PATH="$TMP/bin:$PATH"

fails=0
check() { local name=$1; shift; if "$@"; then echo "ok   $name"; else echo "FAIL $name"; fails=$((fails+1)); fi; }

# Absent, not broken: no compositor, no tank, no units in a temp HOME.
for stub in pgrep omarchy-aquarium-toggle systemctl; do
	printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/$stub"
done
# journalctl replays whatever the case under test wrote.
printf '#!/bin/bash\ncat "$TMP_JOURNAL"\n' > "$TMP/bin/journalctl"
chmod +x "$TMP/bin"/*
export TMP_JOURNAL="$TMP/journal"

line() { printf 'Sep 04 %s omachi macarchy-touchbar[4242]: [macarchy-touchbar %s] %s\n' "$1" "$1" "$2"; }

# --- (a) a module failed and was never repaired -----------------------------
{ line 22:29:40 "module core: core.button, core.label"
  line 22:29:40 "module notifications: no widgets"
  line 22:29:40 "module macarchy.jarvis failed to load: ModuleNotFoundError(\"No module named 'macarchy_dfr'\")"
} > "$TMP_JOURNAL"
out=$(./doctor.sh 2>&1)
check "(a) names the broken module"  grep -q 'MISS.*macarchy.jarvis' <<<"$out"
check "(a) points at the fix"        grep -q 'repo that ships it' <<<"$out"
check "(a) does not also say loaded" bash -c '! grep -q "ok.*Touch Bar modules loaded" <<<"$1"' _ "$out"

# --- (b) failed, then repaired by a hot-reload in the same boot -------------
{ line 22:29:40 "module macarchy.jarvis failed to load: ModuleNotFoundError(\"No module named 'macarchy_dfr'\")"
  line 23:30:05 "module core: core.button, core.label"
  line 23:30:05 "module macarchy.jarvis: macarchy.jarvis.fish"
} > "$TMP_JOURNAL"
out=$(./doctor.sh 2>&1)
check "(b) repaired module is not a miss" bash -c '! grep -q "MISS.*macarchy.jarvis" <<<"$1"' _ "$out"
check "(b) reports modules loaded"        grep -q 'Touch Bar modules loaded' <<<"$out"

# --- (c) a healthy boot, including a module with no widgets -----------------
{ line 23:30:27 "module core: core.button, core.label"
  line 23:30:27 "module notifications: no widgets"
  line 23:30:27 "module macarchy.jarvis: macarchy.jarvis.fish"
} > "$TMP_JOURNAL"
out=$(./doctor.sh 2>&1)
check "(c) reports modules loaded"  grep -q 'Touch Bar modules loaded' <<<"$out"
check "(c) no module miss"          bash -c '! grep -q "Touch Bar module failed" <<<"$1"' _ "$out"

# --- (d) no journal at all (daemon never ran) -------------------------------
: > "$TMP_JOURNAL"
out=$(./doctor.sh 2>&1)
check "(d) silence is not a miss"   bash -c '! grep -q "Touch Bar module failed" <<<"$1"' _ "$out"

(( fails == 0 )) && echo "all ok" || echo "$fails failed"
exit $(( fails > 0 ))
