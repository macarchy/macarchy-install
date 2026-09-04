#!/bin/bash
# Say WHY every failed user unit failed. Read-only; prints nothing when nothing failed.
#
# clean-machine.sh could only ever report THAT units failed: install.sh runs
# doctor.sh itself, so a MISS reds the run from inside install.sh and the journals
# that would explain it are never read. Three units sat unexplained on #9 for a day
# because of it.
#
# Its own script, not a function in clean-machine.sh: that script sudo-writes into
# /etc and /usr/local/bin, so nothing can exercise it in a hermetic suite, while
# this is pure stdout over two stubbable commands (tests/test_clean_machine_journal.sh).
set -uo pipefail

# macarchy-failed@<unit>.service is the NOTIFIER for <unit> -- its own journal says
# only that it fired. Fold it onto its target, the same sed doctor.sh:63 uses, or
# the dump explains the messenger instead of the message.
dump() {
	echo "=== journal: $1 ==="
	# `|| true`: a unit with no journal at all must not red the run -- the dump
	# is diagnostics, never an assertion.
	journalctl --user -u "$1" --no-pager -n 40 2>&1 || true
}

systemctl --user --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | sort -u \
	| while read -r raw; do
		[[ -n $raw ]] || continue
		# The target first -- that is the message. But when the NOTIFIER instance
		# is itself what failed, its own journal is the only one that says why,
		# and folding it away left a block that explained nothing.
		# Strip ONLY when the prefix is really there: `${raw%.service}` applied
		# unconditionally turns a plain `a.service` into `a` and dumps it twice.
		if [[ $raw == macarchy-failed@* ]]; then
			target=${raw#macarchy-failed@}; target=${target%.service}
		else
			target=$raw
		fi
		dump "$target"
		# An `if`, not `[[ … ]] && dump`: as the LAST statement of the loop body
		# that compound returns 1 whenever the condition is false, which becomes
		# the pipeline's status and then the script's. This is diagnostics; it
		# must never be the reason a run goes red.
		if [[ $raw != "$target" ]]; then
			dump "$raw"
		fi
	done

exit 0
