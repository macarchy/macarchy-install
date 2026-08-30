#!/bin/bash
# macarchy-install — one command from a fresh Omarchy-on-Asahi machine to the
# full macarchy setup: the omarchy-mac suite (Touch Bar, auto-brightness,
# battery limit, dock, gestures, Cmd keys), the aquarium background, and the
# apple-glass themes.
#
# Idempotent: every step either converges or is skipped with a note, so
# re-running after a partial failure (or to pick up repo updates) is the
# intended way to use it.
#
#   MACARCHY_DIR   where the working copies live (default ~/Work)

set -uo pipefail
cd "$(dirname "$0")"

MACARCHY_DIR="${MACARCHY_DIR:-$HOME/Work}"
GH=https://github.com/macarchy
REPOS=(omarchy-mac omarchy-aquarium apple-glass apple-glass-light)

FAILURES=0
say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '    \033[33mwarning: %s\033[0m\n' "$*" >&2; FAILURES=$((FAILURES+1)); }

# ---------------------------------------------------------------- sanity

say "Checking this machine"
if [[ $(uname -m) != aarch64 ]]; then
	echo "macarchy targets Apple Silicon under Asahi Linux (aarch64); this is $(uname -m)." >&2
	exit 1
fi
[[ $(uname -r) == *asahi* ]] || warn "kernel is not linux-asahi; sensors/Touch Bar may be missing"
[[ -d /usr/share/omarchy ]] || warn "Omarchy not found in /usr/share/omarchy; theme and hook steps assume it"
note "aarch64, kernel $(uname -r)"

# -------------------------------------------------------------- packages

say "Installing packages (pacman --needed)"
sudo pacman -S --needed --noconfirm \
	git base-devel pkgconf \
	wayland wayland-protocols mesa python \
	brightnessctl libinput tiny-dfr rsync \
	|| warn "pacman failed; later steps may miss tools"

# ----------------------------------------------------------------- repos

say "Fetching the macarchy repos into $MACARCHY_DIR"
mkdir -p "$MACARCHY_DIR"
for r in "${REPOS[@]}"; do
	d="$MACARCHY_DIR/$r"
	if [[ -d $d/.git ]]; then
		if [[ -n $(git -C "$d" status --porcelain) ]]; then
			note "$r: local changes, leaving as is"
		elif git -C "$d" pull --ff-only -q 2>/dev/null; then
			note "$r: up to date"
		else
			note "$r: could not fast-forward (offline or diverged), using as is"
		fi
	elif [[ -e $d ]]; then
		warn "$r: $d exists but is not a git repo, using as is"
	else
		git clone -q "$GH/$r" "$d" && note "$r: cloned" || warn "$r: clone failed"
	fi
done

# ----------------------------------------------------- omarchy-mac suite

say "Installing the omarchy-mac suite (scripts, hook, timer, udev rule, Touch Bar icons)"
if [[ -x $MACARCHY_DIR/omarchy-mac/install.sh ]]; then
	(cd "$MACARCHY_DIR/omarchy-mac" && ./install.sh --udev) || warn "omarchy-mac install failed"
else
	warn "omarchy-mac/install.sh missing"
fi

# -------------------------------------------------------------- aquarium

say "Building and installing the aquarium"
if [[ -f $MACARCHY_DIR/omarchy-aquarium/Makefile ]]; then
	if make -C "$MACARCHY_DIR/omarchy-aquarium" -s install; then
		install -m755 "$MACARCHY_DIR/omarchy-aquarium/hooks/aquarium-theme" \
			"$HOME/.config/omarchy/hooks/theme-set.d/" 2>/dev/null \
			|| { mkdir -p "$HOME/.config/omarchy/hooks/theme-set.d"; \
			     install -m755 "$MACARCHY_DIR/omarchy-aquarium/hooks/aquarium-theme" \
			     "$HOME/.config/omarchy/hooks/theme-set.d/"; }
		note "renderer, toggle, notify watcher and theme hook installed"
	else
		warn "aquarium build failed"
	fi
else
	warn "omarchy-aquarium repo missing"
fi

# ------------------------------------------------------ hyprland wiring

# Guarded appends: each block lands once, keyed on the command it wires.
append_once() {   # append_once <file> <guard-string> <<'EOF' ... EOF
	local file=$1 guard=$2
	mkdir -p "$(dirname "$file")"
	touch "$file"
	if grep -qF "$guard" "$file"; then
		note "$(basename "$file"): $guard already wired"
	else
		cat >> "$file"
		note "$(basename "$file"): wired $guard"
	fi
}

say "Wiring autostart.lua"
AUTO="$HOME/.config/hypr/autostart.lua"
append_once "$AUTO" "omarchy-dfr daemon" <<'LUA'

-- Context-aware Touch Bar: follows the focused window and rewrites tiny-dfr's config.
o.exec_on_start("omarchy-dfr daemon")
LUA
append_once "$AUTO" "omarchy-dock" <<'LUA'

-- macOS-style dock. Autohiding against a bottom hotspot, so it costs no
-- screen space until you reach for it.
o.exec_on_start(os.getenv("HOME") .. "/.local/bin/omarchy-dock")
LUA
append_once "$AUTO" "omarchy-als daemon" <<'LUA'

-- Ambient-light auto-brightness: panel + keyboard backlight follow the AOP
-- light sensor; brightness keys teach it your preferred offset.
o.exec_on_start("omarchy-als daemon")
LUA
append_once "$AUTO" "omarchy-pinch" <<'LUA'

-- Four-finger pinch gestures (pinch in = launcher). Exits quietly until
-- libinput-tools is installed.
o.exec_on_start("omarchy-pinch")
LUA

say "Wiring bindings.lua"
BIND="$HOME/.config/hypr/bindings.lua"
append_once "$BIND" "omarchy-dfr press" <<'LUA'

-- ── Touch Bar (omarchy-dfr) ────────────────────────────────────────────────
-- tiny-dfr can only emit key codes, so command buttons are drawn with the
-- otherwise-unused F13–F24 and routed back here. The daemon holds the slot
-- map, which is what lets every layout reuse the same twelve codes.
-- Edit the bar itself in ~/.config/omarchy-dfr/layouts.toml.
-- Bind by raw keycode, not keysym: this keymap (pc+us) assigns no keysyms to
-- F13-F24, so a bind on the name "F13" would never match even though tiny-dfr
-- emits the key correctly. X keycode = evdev code + 8, and KEY_F13 is 183.
-- Fire on RELEASE, not press: tiny-dfr redrawing under a held finger panics it.
for slot = 1, 12 do
  o.bind("code:" .. (slot + 190), "Touch Bar slot " .. slot,
    "omarchy-dfr press " .. slot, { release = true })
end
LUA
append_once "$BIND" "omarchy-aquarium-toggle" <<'LUA'

-- ── Aquarium background ───────────────────────────────────────────────────
-- Animated underwater scene on the layer-shell "bottom" layer: above the
-- wallpaper, below every window. Toggling off falls straight back to the
-- normal wallpaper. (github.com/macarchy/omarchy-aquarium)
o.bind("SUPER + ALT + A", "Aquarium background", "omarchy-aquarium-toggle")
LUA
append_once "$BIND" "omarchy-zoom" <<'LUA'

-- ── Screen zoom ───────────────────────────────────────────────────────────
-- macOS accessibility zoom: hold CTRL and scroll to magnify the screen
-- around the cursor; scrolling back out lands exactly at 1x.
o.bind("CTRL + mouse_up", "Screen zoom in", "omarchy-zoom in")
o.bind("CTRL + mouse_down", "Screen zoom out", "omarchy-zoom out")
LUA

# ---------------------------------------------------------------- themes

say "Installing the apple-glass themes"
for t in apple-glass apple-glass-light; do
	src="$MACARCHY_DIR/$t"
	dst="$HOME/.config/omarchy/themes/$t"
	if [[ -d $src ]]; then
		mkdir -p "$dst"
		rsync -a --delete --exclude .git "$src/" "$dst/"
		note "$t synced to ~/.config/omarchy/themes"
	else
		warn "$t repo missing"
	fi
done

# The applied theme is a copy; re-apply so edits actually take. On a box
# that never chose a theme from this pair, apply the dark one.
if command -v omarchy-theme-set >/dev/null || command -v omarchy >/dev/null; then
	current=$(basename "$(realpath "$HOME/.local/state/omarchy/current/theme" 2>/dev/null)" 2>/dev/null || true)
	case $current in
		apple-glass|apple-glass-light) omarchy theme set "$current" && note "re-applied $current" ;;
		*) omarchy theme set apple-glass && note "applied apple-glass" ;;
	esac || warn "omarchy theme set failed"
fi

# ------------------------------------------------------------- live bits

if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
	say "Reloading Hyprland and starting what can start now"
	hyprctl reload >/dev/null && note "hyprctl reload"
	pgrep -f "omarchy-dfr daemon" >/dev/null || { setsid omarchy-dfr daemon >/dev/null 2>&1 & note "started omarchy-dfr"; }
	pgrep -f "omarchy-als daemon" >/dev/null || { setsid omarchy-als daemon >/dev/null 2>&1 & note "started omarchy-als"; }
	pgrep -f omarchy-pinch >/dev/null || { setsid omarchy-pinch >/dev/null 2>&1 & note "started omarchy-pinch"; }
	omarchy-aquarium-toggle on && note "aquarium on"
else
	note "no Hyprland session: daemons start on next login (autostart.lua)"
fi

# ----------------------------------------------------------------- done

say "Checking the result"
./doctor.sh || FAILURES=$((FAILURES+1))

if (( FAILURES )); then
	printf '\n\033[33mFinished with %d warning(s) — re-run after fixing, it is idempotent.\033[0m\n' "$FAILURES"
	exit 1
fi
printf '\n\033[1;32mmacarchy installed.\033[0m Log out and back in for a fully clean start.\n'
