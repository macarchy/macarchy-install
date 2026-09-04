#!/bin/bash
# macarchy doctor — verify the pieces install.sh puts in place.
# Read-only; exits non-zero if anything is missing.
set -uo pipefail

# --notify: the same checks, no stdout, one desktop notification if anything is
# missing. One redirect silences all sixty check lines without touching them,
# and silence on a healthy machine is the whole anti-fatigue strategy.
NOTIFY=0
[[ ${1-} == --notify ]] && { NOTIFY=1; exec >/dev/null; }

PASS=0
FAIL=0
# The toast's payload. bad() keeps the ANSI in the format string, never in "$*",
# so a label can never carry escape bytes into a notification.
MISSES=()
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mMISS\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); MISSES+=("$*"); }
have() { [[ -x $HOME/.local/bin/$1 ]] && ok "~/.local/bin/$1" || bad "~/.local/bin/$1"; }
SKIP=0
# Off this laptop there is no macsmc battery and no Touch Bar panel, and CI
# proves install.sh on a plain aarch64 runner. Counting those checks missing
# would cry wolf; printing them ok would be a lie. Gated on an env var CI sets
# and the laptop never does, so a real MISS here stays a MISS.
skip() { printf '  \033[33mskip\033[0m %s\n' "$*"; SKIP=$((SKIP+1)); }

echo "binaries"
for b in macarchy-touchbar macarchy-doctor macarchy-als macarchy-battery-limit macarchy-dock \
         macarchy-dock-theme macarchy-pinch macarchy-zoom macarchy-gtk-settings \
         macarchy-auto-appearance macos-dynamic-wallpaper omarchy-aquarium \
         omarchy-aquarium-toggle omarchy-aquarium-notify; do
	have "$b"
done

echo "system pieces"
[[ -f /etc/udev/rules.d/90-battery-charge-limit.rules ]] \
	&& ok "battery udev rule" || bad "battery udev rule (install.sh runs it with sudo)"
[[ -f /etc/udev/rules.d/70-macarchy-touchbar.rules ]] \
	&& ok "Touch Bar uinput udev rule" || bad "Touch Bar uinput udev rule (macarchy-touchbar/install.sh)"
[[ -f /etc/modules-load.d/macarchy-touchbar.conf ]] \
	&& ok "uinput loaded at boot" || bad "uinput module-load (else /dev/uinput stays root-only)"
[[ $(systemctl is-enabled tiny-dfr 2>/dev/null) == masked ]] \
	&& ok "tiny-dfr masked" || bad "tiny-dfr not masked (it fights macarchy-touchbar for the panel)"
systemctl --user is-enabled -q macarchy-touchbar.service 2>/dev/null \
	&& ok "macarchy-touchbar unit enabled" || bad "macarchy-touchbar unit enabled (macarchy-touchbar/install.sh)"
# macarchy-core/install.sh:22 — "Auto appearance is on exactly when this timer is
# enabled, and the Control Center flips it." A disabled timer is a preference;
# only a missing unit file is a broken install. A login toast that fires on a
# deliberate setting is muted within a week.
if [[ -e $HOME/.config/systemd/user/macarchy-auto-appearance.timer ]]; then
	systemctl --user is-active -q macarchy-auto-appearance.timer 2>/dev/null \
		&& ok "auto-appearance timer" || ok "auto-appearance timer (off — your choice)"
else
	bad "auto-appearance timer unit (macarchy-core/install.sh)"
fi
# Whatever systemd already knows is broken. The sed is load-bearing: a notifier
# instance that hit its start limit is itself a failed unit, and it must fold
# back onto the unit it is about so sort -u shows the daemon once instead of
# once as itself and once as its own alarm. OnFailure=...@%n.service makes the
# instance the FULL unit name, so the unit is macarchy-failed@x.service.service
# -- the trailing .service has to come off too or the fold never matches.
f=$(systemctl --user --failed --no-legend --plain 2>/dev/null | awk '{print $1}' \
	| sed 's/^macarchy-failed@\(.*\)\.service$/\1/' | sort -u | paste -sd' ' -)
[[ -z $f ]] && ok "no failed user units" || bad "failed user units: $f"
# macarchy-auto-appearance now exits 0 when it cannot compute a sun: a deliberate
# no-op must not park its unit in --failed for ever (macarchy-core#12). That was
# also the only thing a MISCONFIGURED laptop had to tell it, so the doctor asks
# directly instead. Gated on omarchy, because without it the theme switch could
# not happen at all -- false on a CI runner, true on any real machine.
if command -v omarchy >/dev/null 2>&1 && command -v macarchy-auto-appearance >/dev/null 2>&1; then
	aa=$(macarchy-auto-appearance status 2>/dev/null)
	if [[ $aa == *"enabled=yes"*"error=sun"* || $aa == *"error=sun"*"enabled=yes"* ]]; then
		bad "auto-appearance is on but cannot compute the sun (set coordinates; see macarchy-sun)"
	else
		ok "auto-appearance can decide a theme"
	fi
else
	skip "auto-appearance sun (no omarchy on this machine)"
fi

# A muted check is worse than none, so the doctor checks that it can speak. Testing
# that the template FILE exists is not that test: it passed on every first install
# while the units naming it were being told "Unit macarchy-failed@….service not
# found", because the file arrived after they did (#12). Ask the units instead --
# whoever declares OnFailure= is who has to be able to reach it.
declare -A _want=()
for u in "$HOME"/.config/systemd/user/*.service; do
	[[ -f $u ]] || continue                                  # no glob match
	while read -r tmpl; do
		[[ -n $tmpl ]] && _want["$tmpl"]="${_want["$tmpl"]:+${_want["$tmpl"]} }$(basename "$u")"
	done < <(sed -nE 's/^OnFailure=([^ ]*@)%?[nNiIpP]?\.service.*/\1.service/p' "$u")
done
if (( ${#_want[@]} == 0 )); then
	ok "failure notifier (nothing declares OnFailure= yet)"
else
	_miss=()
	for tmpl in "${!_want[@]}"; do
		[[ -e $HOME/.config/systemd/user/$tmpl ]] || _miss+=("$tmpl needed by ${_want[$tmpl]}")
	done
	if (( ${#_miss[@]} )); then
		bad "failure notifier: ${_miss[*]} (macarchy-install/install.sh)"
	else
		# COUNT THE UNITS, not the templates: all three daemons name the same
		# macarchy-failed@.service, so ${#_want[@]} is 1 and saying "1 unit" would
		# have under-reported the three this check actually covers.
		_n=0; for tmpl in "${!_want[@]}"; do
			read -ra _u <<<"${_want[$tmpl]}"; _n=$((_n + ${#_u[@]}))
		done
		if (( _n == 1 )); then
			ok "failure notifier (1 unit declares it, reachable)"
		else
			ok "failure notifier ($_n units declare it, all reachable)"
		fi
	fi
fi
systemctl --user is-enabled -q macarchy-doctor.service 2>/dev/null \
	&& ok "login self-check enabled" || bad "login self-check (macarchy-install/install.sh)"
b=/sys/class/power_supply/macsmc-battery/charge_control_end_threshold
if [[ -n ${MACARCHY_NO_HARDWARE:-} ]]; then
	skip "charge threshold (${MACARCHY_NO_HARDWARE})"
elif [[ -r $b ]]; then
	ok "charge threshold readable ($(cat "$b" 2>/dev/null)%)"
else
	bad "charge threshold ($b)"
fi

echo "hyprland wiring"
BIND="$HOME/.config/hypr/bindings.lua"
AUTO="$HOME/.config/hypr/autostart.lua"
grep -qF "omarchy-aquarium-toggle"  "$BIND" 2>/dev/null && ok "aquarium bind"      || bad "aquarium bind"
grep -qF "macarchy-zoom"            "$BIND" 2>/dev/null && ok "zoom binds"         || bad "zoom binds"
grep -qF "macarchy-keys"            "$BIND" 2>/dev/null && ok "Cmd-key grammar"    || bad "Cmd-key grammar"
grep -qF "macarchy-touchbar.service" "$AUTO" 2>/dev/null && ok "Touch Bar autostart" || bad "Touch Bar autostart"
grep -qF "macarchy-als daemon"      "$AUTO" 2>/dev/null && ok "als autostart"      || bad "als autostart"
grep -qF "macarchy-pinch"           "$AUTO" 2>/dev/null && ok "pinch autostart"    || bad "pinch autostart"
grep -qF "macarchy-dock"            "$AUTO" 2>/dev/null && ok "dock autostart"     || bad "dock autostart"
grep -qF "omarchy-aquarium-toggle restore" "$AUTO" 2>/dev/null && ok "aquarium autostart" || bad "aquarium autostart"

echo "themes and hooks"
for t in apple-glass apple-glass-light; do
	[[ -f $HOME/.config/omarchy/themes/$t/colors.toml || -d $HOME/.config/omarchy/themes/$t ]] \
		&& ok "theme $t" || bad "theme $t"
done
[[ -x $HOME/.config/omarchy/hooks/theme-set.d/aquarium-theme ]] \
	&& ok "aquarium theme hook" || bad "aquarium theme hook"
[[ -x $HOME/.config/omarchy/hooks/theme-set.d/dynamic-wallpaper ]] \
	&& ok "dynamic wallpaper hook" || bad "dynamic wallpaper hook (macarchy-core/install.sh)"
# The timer is the whole mechanism: without it the wallpaper only ever changes
# when a theme is set. Its config is separate because the tool exits non-zero
# on a bad one, and a machine can legitimately have the timer off.
systemctl --user is-enabled -q macos-dynamic-wallpaper.timer 2>/dev/null \
	&& ok "dynamic wallpaper timer" \
	|| bad "dynamic wallpaper timer (macos-dynamic-wallpaper/install.sh)"
w=${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/dynamic-wallpaper.json
if [[ ! -e $w ]]; then
	bad "dynamic wallpaper config (${w/#$HOME/\~})"
elif out=$(macos-dynamic-wallpaper status 2>&1); then
	ok "dynamic wallpaper config ($(awk -F: '/^phase:/{print $2}' <<<"$out" | tr -d ' '))"
else
	bad "dynamic wallpaper config: $(tail -1 <<<"$out")"
fi

# WAYLAND_DISPLAY, not HYPRLAND_INSTANCE_SIGNATURE, matching what
# /usr/lib/systemd/user/omarchy-crash-watch.service already conditions on. uwsm
# does export both into the user manager, so either works today — but this block
# is the half of the doctor that catches a daemon Hyprland (not systemd) starts,
# and it must not go silently missing over an env var it does not need.
if [[ -n ${WAYLAND_DISPLAY:-} ]]; then
	echo "running now"
	systemctl --user is-active -q macarchy-touchbar.service && ok "macarchy-touchbar" \
		|| bad "macarchy-touchbar not running (journalctl --user -u macarchy-touchbar)"
	# A Touch Bar module that fails to load is otherwise SILENT: the daemon says
	# so once, then runs happily without that widget -- no failed unit, no toast,
	# and `status` does not list it. It is what a rename here costs every OTHER
	# repo that ships a module (jarvis ships one, and is not even in REPOS), whose
	# installed copy is a COPY and keeps importing the old package name. The
	# daemon hot-reloads on the file change, so a failure can be repaired later in
	# the same boot: only the LAST word on each module counts.
	broken=$(journalctl --user -u macarchy-touchbar.service -b --no-pager 2>/dev/null \
		| sed -nE 's/.* module ([^ :]+) failed to load.*/FAIL \1/p; s/.* module ([^ :]+):.*/OK \1/p' \
		| awk '{ s[$2] = ($1 == "FAIL") } END { for (m in s) if (s[m]) print m }' | sort | tr '\n' ' ')
	broken=${broken% }
	[[ -z $broken ]] && ok "Touch Bar modules loaded" \
		|| bad "Touch Bar module failed to load: $broken (re-run install.sh in the repo that ships it)"
	# Same as auto-appearance above: bar-contrast now exits 0 when it has
	# nothing to sample, so a session that is missing grim/magick/hyprctl/jq
	# would otherwise say nothing at all. Only meaningful with a session, which
	# is exactly what this block already has.
	if command -v macarchy-bar-contrast >/dev/null 2>&1; then
		bc=$(macarchy-bar-contrast status 2>&1)
		[[ $bc == *"nothing to sample"* ]] \
			&& bad "bar-contrast has nothing to sample: ${bc#*: }" \
			|| ok "bar-contrast can sample the screen"
	fi
	pgrep -f "macarchy-als daemon" >/dev/null && ok "macarchy-als"   || bad "macarchy-als not running"
	pgrep -f "macarchy-pinch"      >/dev/null && ok "macarchy-pinch" || bad "macarchy-pinch not running"
	# The tank remembers off across reboots (omarchy-aquarium-toggle:30, an
	# unwritten state means on). Off on purpose is not a fault.
	aq=$(cat "${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-aquarium/enabled" 2>/dev/null || echo on)
	if [[ $aq == off ]]; then
		ok "aquarium off (your choice)"
	elif omarchy-aquarium-toggle status >/dev/null 2>&1; then
		ok "aquarium"
	else
		bad "aquarium not running (SUPER+ALT+A)"
	fi
else
	skip "running-now checks (no Hyprland session)"
fi

if (( NOTIFY )); then
	# A watchdog that can itself fail is one more silent failure: this unit has
	# no OnFailure and always exits 0.
	(( FAIL )) || exit 0
	# graphical-session.target is reached before the shell has claimed
	# org.freedesktop.Notifications; upstream learned this the hard way.
	command -v omarchy-notification-wait >/dev/null && omarchy-notification-wait >/dev/null 2>&1
	body=$(printf '%s\n' "${MISSES[@]}" | head -3)
	if command -v omarchy-notification-send >/dev/null; then
		# --exec last, and as separate words: the shell runs the argv as-is, so
		# clicking opens the full doctor in a floating terminal. Sent through
		# omarchy-notification-send, not notify-send, to keep the omarchy-action
		# app name the shell's do-not-disturb bypass allows.
		omarchy-notification-send -u normal -g '󰀪' \
			"macarchy: $FAIL check(s) failing" "$body" \
			--exec omarchy-launch-floating-terminal-with-presentation macarchy-doctor
	elif command -v notify-send >/dev/null; then
		notify-send -u normal -a macarchy "macarchy: $FAIL check(s) failing" "$body"
	fi
	exit 0
fi

printf '\n%d ok, %d missing, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
exit $((FAIL > 0))
