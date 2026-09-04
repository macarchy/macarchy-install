#!/bin/bash
# macarchy-install — one command from a fresh Omarchy-on-Asahi machine to the
# full macarchy setup: the omarchy-mac suite (auto-brightness, battery limit,
# dock, gestures, Cmd keys), macarchy-dfr (the Touch Bar), the aquarium
# background, and the apple-glass themes.
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
REPOS=(omarchy-mac macarchy-dfr omarchy-aquarium apple-glass apple-glass-light)

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
	brightnessctl libinput rsync \
	tiny-dfr \
	|| warn "pacman failed; later steps may miss tools"
# tiny-dfr is installed but MASKED: macarchy-dfr owns the Touch Bar now, and
# tiny-dfr is only what `macarchy-dfr/install.sh --uninstall` falls back to.

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

# ---------------------------------------------------------- macarchy-dfr

say "Installing macarchy-dfr (the Touch Bar daemon)"
if [[ -x $MACARCHY_DIR/macarchy-dfr/install.sh ]]; then
	# Its own installer owns the whole story: packages, the icon font, the
	# video group, the uinput udev rule and modules-load, masking tiny-dfr,
	# the user unit, and migrating any old omarchy-dfr Hyprland wiring.
	(cd "$MACARCHY_DIR/macarchy-dfr" && ./install.sh) || warn "macarchy-dfr install failed"
else
	warn "macarchy-dfr/install.sh missing"
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
append_once "$AUTO" "macarchy-dfr.service" <<'LUA'

-- The Touch Bar (macarchy-dfr): a systemd user service, so it restarts on
-- failure and logs to the journal. The unit is enabled too — this line only
-- makes the session-start explicit, and starting it twice is a no-op.
o.exec_on_start("systemctl --user start macarchy-dfr.service")
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
append_once "$AUTO" "omarchy-aquarium-toggle restore" <<'LUA'

-- The animated aquarium background, put back the way it was left: "restore"
-- starts it unless it was deliberately toggled off in an earlier session.
o.exec_on_start("omarchy-aquarium-toggle restore")
LUA

say "Wiring bindings.lua"
BIND="$HOME/.config/hypr/bindings.lua"
# No Touch Bar binds any more: the old F13-F24 bridge existed because tiny-dfr
# could only emit key codes. macarchy-dfr draws the bar itself, runs the
# commands itself, and types through its own uinput device.
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
	systemctl --user start macarchy-dfr.service 2>/dev/null && note "macarchy-dfr started" || warn "macarchy-dfr did not start (journalctl --user -u macarchy-dfr)"
	pgrep -f "omarchy-als daemon" >/dev/null || { setsid omarchy-als daemon >/dev/null 2>&1 & note "started omarchy-als"; }
	pgrep -f omarchy-pinch >/dev/null || { setsid omarchy-pinch >/dev/null 2>&1 & note "started omarchy-pinch"; }
	omarchy-aquarium-toggle restore && note "aquarium restored to its remembered state"
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
