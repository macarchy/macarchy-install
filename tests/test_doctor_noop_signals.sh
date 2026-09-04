#!/bin/bash
# tests/test_doctor_noop_signals.sh — the checks that replaced a failed unit.
#
# macarchy-core#12 made macarchy-auto-appearance and macarchy-bar-contrast exit 0
# when they deliberately do nothing, so a oneshot no longer parks itself in
# `systemctl --user --failed` for ever. That was also the only signal a
# MISCONFIGURED laptop had, so the doctor has to ask the two tools directly --
# and a check that can only ever say "ok" would be worse than the unit it
# replaced. These cases exist to prove each one can still say MISS.
set -uo pipefail
cd "$(dirname "$0")/.."

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state"
mkdir -p "$HOME" "$TMP/bin"; export PATH="$TMP/bin:$PATH"

fails=0
check() { local name=$1; shift; if "$@"; then echo "ok   $name"; else echo "FAIL $name"; fails=$((fails+1)); fi; }

for stub in pgrep omarchy-aquarium-toggle systemctl journalctl; do
	printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/$stub"
done
printf '#!/bin/bash\nexit 0\n' > "$TMP/bin/omarchy"
printf '#!/bin/bash\ncat "$AA_STATUS"\n'  > "$TMP/bin/macarchy-auto-appearance"
printf '#!/bin/bash\ncat "$BC_STATUS"\n'  > "$TMP/bin/macarchy-bar-contrast"
chmod +x "$TMP/bin"/*
export AA_STATUS="$TMP/aa" BC_STATUS="$TMP/bc"
echo 'sample=#003575 verdict=light' > "$BC_STATUS"

# --- auto-appearance: on but sunless is a MISS ------------------------------
echo 'mode=solar enabled=yes error=sun' > "$AA_STATUS"
out=$(WAYLAND_DISPLAY= ./doctor.sh 2>&1)
check "sunless-but-enabled is a MISS"  grep -q 'MISS.*cannot compute the sun' <<<"$out"
check "and it says how to fix it"      grep -q 'set coordinates' <<<"$out"

# --- auto-appearance: a normal answer is ok ---------------------------------
echo 'mode=solar enabled=yes want=dark sunrise=06:57 sunset=20:15' > "$AA_STATUS"
out=$(WAYLAND_DISPLAY= ./doctor.sh 2>&1)
check "a working sun is ok"            grep -q 'ok.*auto-appearance can decide' <<<"$out"
check "and not also a MISS"            bash -c '! grep -q "cannot compute the sun" <<<"$1"' _ "$out"

# --- auto-appearance: disabled is not a MISS --------------------------------
# error=sun with the timer OFF is nobody's problem: the user turned it off.
echo 'mode=solar enabled=no error=sun' > "$AA_STATUS"
out=$(WAYLAND_DISPLAY= ./doctor.sh 2>&1)
check "sunless but switched off is not a MISS" bash -c '! grep -q "cannot compute the sun" <<<"$1"' _ "$out"

# --- no omarchy: skipped with a reason, never a silent pass -----------------
# Removing the stub is not enough: the developer running this suite HAS a real
# omarchy on PATH, and `command -v` would find it whatever $TMP/bin holds. So
# build a PATH with every directory containing an omarchy dropped -- on a CI
# runner that is a no-op, on a laptop it is the whole point of the case.
without_omarchy() {
	local d out= dirs
	IFS=: read -ra dirs <<<"$PATH"
	for d in "${dirs[@]}"; do
		[[ -x $d/omarchy ]] && continue
		out="${out:+$out:}$d"
	done
	printf '%s' "$out"
}
echo 'mode=solar enabled=yes error=sun' > "$AA_STATUS"
rm -f "$TMP/bin/omarchy"
out=$(PATH="$(without_omarchy)" WAYLAND_DISPLAY= ./doctor.sh 2>&1)
check "no omarchy skips, not passes"   grep -q 'skip.*auto-appearance sun' <<<"$out"
check "and names why"                  grep -q 'no omarchy on this machine' <<<"$out"
check "and does not MISS"              bash -c '! grep -q "cannot compute the sun" <<<"$1"' _ "$out"
printf '#!/bin/bash\nexit 0\n' > "$TMP/bin/omarchy"; chmod +x "$TMP/bin/omarchy"

# --- bar-contrast: nothing to sample, inside a session, is a MISS -----------
echo 'macarchy-bar-contrast: grim missing; nothing to sample' > "$BC_STATUS"
out=$(WAYLAND_DISPLAY=wayland-0 ./doctor.sh 2>&1)
check "nothing to sample is a MISS"    grep -q 'MISS.*bar-contrast has nothing to sample' <<<"$out"
check "and quotes the reason"          grep -q 'grim missing' <<<"$out"

# --- bar-contrast: no session, no claim -------------------------------------
out=$(WAYLAND_DISPLAY= ./doctor.sh 2>&1)
check "no session: bar-contrast unasked" bash -c '! grep -q "bar-contrast" <<<"$1"' _ "$out"

(( fails == 0 )) && echo "all ok" || echo "$fails failed"
exit $(( fails > 0 ))
