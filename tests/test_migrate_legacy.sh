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

fails=0
check() { local name=$1; shift; if "$@"; then echo "ok   $name"; else echo "FAIL $name"; fails=$((fails+1)); fi; }

say() { :; }; note() { echo "note: $*"; }; warn() { echo "warn: $*"; }; advise() { echo "advise: $*"; }
eval "$(sed -n '/^migrate_legacy() {$/,/^}$/p' install.sh)"
[[ $(type -t migrate_legacy) == function ]] || { echo "could not extract migrate_legacy from install.sh" >&2; exit 1; }

# --- a machine carrying every old name ---------------------------------------
UD="$HOME/.config/systemd/user"
mkdir -p "$UD/graphical-session.target.wants" "$HOME/.local/bin/__pycache__" \
	"$HOME/.local/state/macarchy-dfr" "$HOME/.local/state/omarchy-als" \
	"$HOME/.config/macarchy-dfr" "$HOME/.config/omarchy-dfr" "$HOME/.config/hypr"
touch "$UD/macarchy-dfr.service" "$UD/omarchy-bar-contrast.timer"
ln -s "$UD/macarchy-dfr.service" "$UD/graphical-session.target.wants/macarchy-dfr.service"
touch "$HOME/.local/state/omarchy-dfr.log" "$HOME/.local/state/omarchy-dfr-device.json"
for b in macarchy-dfr omarchy-als omarchy-dock omarchy-zoom macos-dynamic-wallpaper; do
	touch "$HOME/.local/bin/$b" "$HOME/.local/bin/__pycache__/$b.cpython-313.pyc"
done
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
check "als state moved"           [ -d "$HOME/.local/state/macarchy-als" ]
check "stale log gone"            [ ! -e "$HOME/.local/state/omarchy-dfr.log" ]
check "stale device json gone"    [ ! -e "$HOME/.local/state/omarchy-dfr-device.json" ]
check "old binaries gone"         [ -z "$(ls -A "$HOME/.local/bin")" ]
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

exit $((fails > 0))
