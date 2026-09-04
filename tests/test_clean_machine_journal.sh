#!/bin/bash
# tests/test_clean_machine_journal.sh — the failed-unit journal dump.
#
# clean-machine.sh reports THAT user units failed and never why: it is install.sh
# that runs doctor.sh, so its MISS reds the run from inside, and the journals that
# would explain it are never read. Three units sat unexplained on #9 for exactly
# that reason.
#
# The seam is tests/dump-failed-units.sh's stdout, NOT clean-machine.sh's: that
# script sudo-writes into /etc and /usr/local/bin and enables linger, so it can
# never run in a hermetic suite. The dump lives in its own script so it CAN.
set -uo pipefail
cd "$(dirname "$0")/.."

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"; export PATH="$TMP/bin:$PATH"

fails=0
check() { local name=$1; shift; if "$@"; then echo "ok   $name"; else echo "FAIL $name"; fails=$((fails+1)); fi; }

# systemctl replays whatever the case wrote; journalctl echoes which unit it was asked for.
cat > "$TMP/bin/systemctl" <<'STUB'
#!/bin/bash
[[ $* == *--failed* ]] || exit 1
cat "$TMP_FAILED"
STUB
cat > "$TMP/bin/journalctl" <<'STUB'
#!/bin/bash
for a in "$@"; do [[ $prev == -u ]] && echo "MARKER body of $a"; prev=$a; done
STUB
chmod +x "$TMP/bin"/*
export TMP_FAILED="$TMP/failed"

# --- (a) one failed unit: its name AND its journal reach stdout ---------------
echo 'macarchy-auto-appearance.service loaded failed failed Some daemon' > "$TMP_FAILED"
out=$(./tests/dump-failed-units.sh 2>&1)
check "(a) names the unit"        grep -q 'macarchy-auto-appearance.service' <<<"$out"
check "(a) carries its journal"   grep -q 'MARKER body of macarchy-auto-appearance.service' <<<"$out"

# --- (b) nothing failed: no dump at all ---------------------------------------
: > "$TMP_FAILED"
out=$(./tests/dump-failed-units.sh 2>&1)
check "(b) silence when nothing failed" [ -z "$out" ]

# --- (c) the notifier instance folds onto its target, like doctor.sh:63 -------
# macarchy-failed@macarchy-touchbar.service.service is the NOTIFIER for
# macarchy-touchbar.service. Dumping the notifier's own journal says nothing;
# doctor.sh already folds the pair into one name and so must this.
echo 'macarchy-failed@macarchy-touchbar.service.service loaded failed failed Notifier' > "$TMP_FAILED"
out=$(./tests/dump-failed-units.sh 2>&1)
check "(c) folds onto the target"      grep -q 'MARKER body of macarchy-touchbar.service' <<<"$out"
# ...and the notifier's OWN journal too: when the instance is what failed, that
# is the only place saying why. The target still comes first -- it is the message.
check "(c) dumps the notifier as well" grep -q 'MARKER body of macarchy-failed@macarchy-touchbar.service.service' <<<"$out"
check "(c) target before notifier"     bash -c '[ "$(grep -n "MARKER body of macarchy-touchbar.service" <<<"$1" | cut -d: -f1)" -lt "$(grep -n "MARKER body of macarchy-failed@" <<<"$1" | cut -d: -f1)" ]' _ "$out"

# --- (d) several failed units: one block each ---------------------------------
printf '%s\n' 'a.service loaded failed failed A' 'b.service loaded failed failed B' > "$TMP_FAILED"
out=$(./tests/dump-failed-units.sh 2>&1)
check "(d) one block per unit" [ "$(grep -c 'MARKER body of' <<<"$out")" = 2 ]

# --- (e) a unit with no journal must not kill the run -------------------------
echo 'c.service loaded failed failed C' > "$TMP_FAILED"
printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/journalctl"   # journalctl fails outright
./tests/dump-failed-units.sh >/dev/null 2>&1; rc=$?
# `$?` must be captured FIRST: inside `check "..." [ "$?" = 0 ]` it expands while
# the argument list is built, so the assertion would silently retarget to
# whatever command happened to run just before it.
check "(e) survives a journalctl failure" [ "$rc" = 0 ]

(( fails == 0 )) && echo "all ok" || echo "$fails failed"
exit $(( fails > 0 ))
