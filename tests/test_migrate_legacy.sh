#!/bin/bash
# tests/test_migrate_legacy.sh — install.sh's migrate_legacy() deletes units,
# binaries and state, and rewrites the Hyprland config in place. That is the one
# destructive thing this repo does, and it runs on every install, so it gets a
# check. Hermetic: a temp HOME plus a systemctl stub, like test_doctor_notify.sh.
#
# The function is lifted out of install.sh rather than sourced, because
# install.sh is a script that installs when you run it. Extraction is by the
# `migrate_legacy() {` ... `}` block; keep those at column 0.
set -uo pipefail
cd "$(dirname "$0")/.."

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/bin"
export PATH="$TMP/bin:$PATH"
# A user bus would enable/disable real units on the machine running the test.
printf '#!/bin/bash\nexit 0\n' > "$TMP/bin/systemctl"; chmod +x "$TMP/bin/systemctl"
# The only paths migrate_legacy() does not derive from $HOME are the root-owned
# ones under /etc; point them at the temp tree so the test cannot see this
# machine's real leftovers (or report them as its own).
export MACARCHY_ROOT="$TMP/root"

fails=0
check() { local name=$1; shift; if "$@"; then echo "ok   $name"; else echo "FAIL $name"; fails=$((fails+1)); fi; }

say() { :; }; note() { echo "note: $*"; }; warn() { echo "warn: $*"; }; advise() { echo "advise: $*"; }
eval "$(sed -n '/^migrate_legacy() {$/,/^}$/p' install.sh)"
[[ $(type -t migrate_legacy) == function ]] || { echo "could not extract migrate_legacy from install.sh" >&2; exit 1; }

# --- a machine carrying every old name ---------------------------------------
UD="$HOME/.config/systemd/user"
mkdir -p "$UD/graphical-session.target.wants" "$HOME/.local/bin/__pycache__" \
	"$HOME/.local/state/macarchy-dfr" "$HOME/.local/state/omarchy-als" \
	"$HOME/.config/omarchy-als" \
	"$HOME/.config/macarchy-dfr" "$HOME/.config/omarchy-dfr" "$HOME/.config/hypr" \
	"$HOME/Work/omarchy-mac" "$HOME/Work/macarchy-dfr" \
	"$HOME/.config/omarchy/hooks/theme-set.d" "$HOME/.config/omarchy-aquarium/hooks"
# A checkout counts only if it can reinstall: the gate tests for an executable
# install.sh, not for a directory, so an interrupted clone cannot open it.
for r in omarchy-mac macarchy-dfr; do
	printf '#!/bin/bash\n' >"$HOME/Work/$r/install.sh"; chmod +x "$HOME/Work/$r/install.sh"
done
touch "$HOME/.config/omarchy/hooks/theme-set.d/omarchy-bar-contrast" \
	"$HOME/.config/omarchy/hooks/theme-set.d/omarchy-dock-theme" \
	"$HOME/.config/omarchy/hooks/theme-set.d/macarchy-bar-contrast" \
	"$HOME/.config/omarchy-aquarium/hooks/omarchy-bar-contrast"
touch "$UD/macarchy-dfr.service" "$UD/omarchy-bar-contrast.timer"
ln -s "$UD/macarchy-dfr.service" "$UD/graphical-session.target.wants/macarchy-dfr.service"
touch "$HOME/.local/state/omarchy-dfr.log" "$HOME/.local/state/omarchy-dfr-device.json"
for b in macarchy-dfr omarchy-als omarchy-dock omarchy-zoom; do
	touch "$HOME/.local/bin/$b" "$HOME/.local/bin/__pycache__/$b.cpython-313.pyc"
done
# Protected: no macarchy repo ships macos-dynamic-wallpaper and no package owns
# it, so deleting it here would be irreversible. It must survive untouched.
touch "$HOME/.local/bin/macos-dynamic-wallpaper"
cat > "$HOME/.config/hypr/autostart.lua" <<'LUA'
o.exec_on_start("systemctl --user start macarchy-dfr.service")
o.exec_on_start("omarchy-als daemon")
o.exec_on_start(os.getenv("HOME") .. "/.local/bin/omarchy-dock")
o.exec_on_start("omarchy-aquarium-toggle restore")
LUA

out=$(migrate_legacy)

check "old unit file gone"        [ ! -e "$UD/macarchy-dfr.service" ]
check "old timer gone"            [ ! -e "$UD/omarchy-bar-contrast.timer" ]
check "dangling enablement gone"  [ ! -L "$UD/graphical-session.target.wants/macarchy-dfr.service" ]
check "config moved"              [ -d "$HOME/.config/macarchy-touchbar" ]
check "older config backed up"    [ -d "$HOME/.config/omarchy-dfr.bak" ]
check "older config not clobbering" [ ! -e "$HOME/.config/omarchy-dfr" ]
check "state moved"               [ -d "$HOME/.local/state/macarchy-touchbar" ]
check "als config moved"           [ -d "$HOME/.config/macarchy-als" ]
check "als state moved"           [ -d "$HOME/.local/state/macarchy-als" ]
check "stale log gone"            [ ! -e "$HOME/.local/state/omarchy-dfr.log" ]
check "stale device json gone"    [ ! -e "$HOME/.local/state/omarchy-dfr-device.json" ]
check "old binaries gone"         [ "$(ls -A "$HOME/.local/bin")" = macos-dynamic-wallpaper ]
check "dynamic wallpaper kept"   [ -e "$HOME/.local/bin/macos-dynamic-wallpaper" ]
check "checkout omarchy-mac moved"  [ -d "$HOME/Work/macarchy-core" ]
check "checkout macarchy-dfr moved" [ -d "$HOME/Work/macarchy-touchbar" ]
check "old checkouts gone"       [ ! -e "$HOME/Work/omarchy-mac" ]
check "old theme hook gone"      [ ! -e "$HOME/.config/omarchy/hooks/theme-set.d/omarchy-bar-contrast" ]
check "old dock hook gone"       [ ! -e "$HOME/.config/omarchy/hooks/theme-set.d/omarchy-dock-theme" ]
check "old aquarium hook gone"   [ ! -e "$HOME/.config/omarchy-aquarium/hooks/omarchy-bar-contrast" ]
check "new hook untouched"       [ -e "$HOME/.config/omarchy/hooks/theme-set.d/macarchy-bar-contrast" ]
check "reported what it did"      grep -q 'note: removed old unit macarchy-dfr.service' <<<"$out"

lua=$HOME/.config/hypr/autostart.lua
check "lua rewritten in place"    grep -q 'macarchy-touchbar.service' "$lua"
check "lua daemons renamed"       grep -q 'macarchy-als daemon' "$lua"
check "lua left the aquarium alone" grep -q 'omarchy-aquarium-toggle restore' "$lua"
check "lua block not duplicated"  [ "$(wc -l < "$lua")" = 4 ]

# --- second run changes nothing and says so ----------------------------------
sha=$(sha256sum "$lua")
out=$(migrate_legacy)
check "second run is a no-op"     [ "$(sha256sum "$lua")" = "$sha" ]
check "second run says so"        grep -q 'nothing from the old names is left' <<<"$out"

# --- without the new checkouts, nothing is removed -----------------------------
# The repo loop reinstalls from $MACARCHY_DIR/macarchy-{core,touchbar}; if those
# are missing, deleting the installed binaries first is a one-way trip.
rm -rf "$HOME/Work/macarchy-touchbar"
touch "$HOME/.local/bin/omarchy-dock" "$UD/macarchy-dfr.service"
out=$(migrate_legacy)
check "gate keeps binaries"       [ -e "$HOME/.local/bin/omarchy-dock" ]
check "gate keeps units"          [ -e "$UD/macarchy-dfr.service" ]
check "gate says why"             grep -q 'no macarchy-core/macarchy-touchbar checkout' <<<"$out"

# An interrupted `git clone` leaves the target directory behind, empty. That is
# the state the gate exists for, so a bare directory must not satisfy it.
mkdir -p "$HOME/Work/macarchy-touchbar"
out=$(migrate_legacy)
check "empty checkout keeps binaries" [ -e "$HOME/.local/bin/omarchy-dock" ]
check "empty checkout keeps units"    [ -e "$UD/macarchy-dfr.service" ]

exit $((fails > 0))
