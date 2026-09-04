#!/bin/bash
# macarchy doctor — verify the pieces install.sh puts in place.
# Read-only; exits non-zero if anything is missing.
set -uo pipefail

PASS=0
FAIL=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mMISS\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
have() { [[ -x $HOME/.local/bin/$1 ]] && ok "~/.local/bin/$1" || bad "~/.local/bin/$1"; }

echo "binaries"
for b in macarchy-dfr omarchy-als omarchy-battery-limit omarchy-dock \
         omarchy-dock-theme omarchy-pinch omarchy-zoom omarchy-gtk-settings \
         omarchy-auto-appearance omarchy-aquarium omarchy-aquarium-toggle \
         omarchy-aquarium-notify; do
	have "$b"
done

echo "system pieces"
[[ -f /etc/udev/rules.d/90-battery-charge-limit.rules ]] \
	&& ok "battery udev rule" || bad "battery udev rule (install.sh runs it with sudo)"
[[ -f /etc/udev/rules.d/70-macarchy-dfr.rules ]] \
	&& ok "Touch Bar uinput udev rule" || bad "Touch Bar uinput udev rule (macarchy-dfr/install.sh)"
[[ -f /etc/modules-load.d/macarchy-dfr.conf ]] \
	&& ok "uinput loaded at boot" || bad "uinput module-load (else /dev/uinput stays root-only)"
[[ $(systemctl is-enabled tiny-dfr 2>/dev/null) == masked ]] \
	&& ok "tiny-dfr masked" || bad "tiny-dfr not masked (it fights macarchy-dfr for the panel)"
systemctl --user is-enabled -q macarchy-dfr.service 2>/dev/null \
	&& ok "macarchy-dfr unit enabled" || bad "macarchy-dfr unit enabled (macarchy-dfr/install.sh)"
systemctl --user is-active -q omarchy-auto-appearance.timer 2>/dev/null \
	&& ok "auto-appearance timer" || bad "auto-appearance timer"
b=/sys/class/power_supply/macsmc-battery/charge_control_end_threshold
[[ -r $b ]] && ok "charge threshold readable ($(cat "$b" 2>/dev/null)%)" \
	|| bad "charge threshold ($b)"

echo "hyprland wiring"
BIND="$HOME/.config/hypr/bindings.lua"
AUTO="$HOME/.config/hypr/autostart.lua"
grep -qF "omarchy-aquarium-toggle"  "$BIND" 2>/dev/null && ok "aquarium bind"      || bad "aquarium bind"
grep -qF "omarchy-zoom"             "$BIND" 2>/dev/null && ok "zoom binds"         || bad "zoom binds"
grep -qF "macarchy-keys"            "$BIND" 2>/dev/null && ok "Cmd-key grammar"    || bad "Cmd-key grammar"
grep -qF "macarchy-dfr.service"     "$AUTO" 2>/dev/null && ok "dfr autostart"      || bad "dfr autostart"
grep -qF "omarchy-als daemon"       "$AUTO" 2>/dev/null && ok "als autostart"      || bad "als autostart"
grep -qF "omarchy-pinch"            "$AUTO" 2>/dev/null && ok "pinch autostart"    || bad "pinch autostart"
grep -qF "omarchy-dock"             "$AUTO" 2>/dev/null && ok "dock autostart"     || bad "dock autostart"
grep -qF "omarchy-aquarium-toggle restore" "$AUTO" 2>/dev/null && ok "aquarium autostart" || bad "aquarium autostart"

echo "themes and hooks"
for t in apple-glass apple-glass-light; do
	[[ -f $HOME/.config/omarchy/themes/$t/colors.toml || -d $HOME/.config/omarchy/themes/$t ]] \
		&& ok "theme $t" || bad "theme $t"
done
[[ -x $HOME/.config/omarchy/hooks/theme-set.d/aquarium-theme ]] \
	&& ok "aquarium theme hook" || bad "aquarium theme hook"

if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
	echo "running now"
	systemctl --user is-active -q macarchy-dfr.service && ok "macarchy-dfr" \
		|| bad "macarchy-dfr not running (journalctl --user -u macarchy-dfr)"
	pgrep -f "omarchy-als daemon" >/dev/null && ok "omarchy-als"   || bad "omarchy-als not running"
	pgrep -f "omarchy-pinch"      >/dev/null && ok "omarchy-pinch" || bad "omarchy-pinch not running"
	omarchy-aquarium-toggle status >/dev/null 2>&1 && ok "aquarium" || bad "aquarium not running (SUPER+ALT+A, or it was left off)"
fi

printf '\n%d ok, %d missing\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
