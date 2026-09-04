#!/bin/bash
# macarchy-install — one command from a fresh Omarchy-on-Asahi machine to the
# full macarchy setup: the macarchy-core suite (auto-brightness, battery limit,
# dock, gestures, Cmd keys), macarchy-touchbar (the Touch Bar), the aquarium
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
REPOS=(macarchy-core macarchy-touchbar omarchy-aquarium apple-glass apple-glass-light)

FAILURES=0
say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '    \033[33mwarning: %s\033[0m\n' "$*" >&2; FAILURES=$((FAILURES+1)); }
# A fact about the machine, not a failed step: it must not inflate FAILURES and
# so decide the exit code. doctor.sh is what decides whether the install is good.
advise() { printf '    \033[33mnote: %s\033[0m\n' "$*" >&2; }

# ---------------------------------------------------------------- sanity

say "Checking this machine"
if [[ $(uname -m) != aarch64 ]]; then
	echo "macarchy targets Apple Silicon under Asahi Linux (aarch64); this is $(uname -m)." >&2
	exit 1
fi
[[ $(uname -r) == *asahi* ]] || advise "kernel is not linux-asahi; sensors/Touch Bar may be missing"
[[ -d /usr/share/omarchy ]] || warn "Omarchy not found in /usr/share/omarchy; theme and hook steps assume it"
note "aarch64, kernel $(uname -r)"

# ------------------------------------------------------- legacy migration

# Everything renamed at once: omarchy-mac -> macarchy-core, macarchy-dfr ->
# macarchy-touchbar, and every command that used to sit in upstream Omarchy's
# omarchy-* namespace (where a future upstream omarchy-battery-limit would have
# silently shadowed ours) moved to macarchy-*. The old units keep running, the
# old binaries keep answering on PATH and the old config keeps being read, so
# they have to go BEFORE anything new is installed.
#
# Same contract as the rest of this script: every step converges or says why it
# skipped, and a second run finds nothing left to do.
migrate_legacy() {
	say "Clearing anything left under the old names"
	local UD="$HOME/.config/systemd/user"
	local CFG="$HOME/.config" ST="$HOME/.local/state" BIN="$HOME/.local/bin"
	local u l f b lua before after touched=0 reload=0

	# --- user units. The .wants/ symlink outlives `disable` when the unit file
	# went away first, and a dangling one makes daemon-reload complain forever.
	for u in macarchy-dfr.service \
	         omarchy-auto-appearance.service omarchy-auto-appearance.timer \
	         omarchy-bar-contrast.service omarchy-bar-contrast.timer \
	         macos-dynamic-wallpaper.service macos-dynamic-wallpaper.timer; do
		if [[ -e $UD/$u ]]; then
			systemctl --user disable --now "$u" >/dev/null 2>&1
			rm -f "$UD/$u" && note "removed old unit $u" && reload=1
		fi
		for l in "$UD"/*.wants/"$u"; do
			[[ -L $l ]] || continue          # no glob match, or a real file
			rm -f "$l" && note "removed stale enablement ${l#"$UD"/}" && reload=1
		done
	done
	if (( reload )); then
		systemctl --user daemon-reload 2>/dev/null || advise "systemctl --user daemon-reload failed (no user bus?)"
		touched=1
	fi

	# --- config. macarchy-dfr was the newer name, omarchy-dfr the one before
	# it; when both survived, the newer wins and the older is kept aside.
	if [[ -d $CFG/macarchy-touchbar ]]; then
		[[ -d $CFG/macarchy-dfr ]] \
			&& advise "left ~/.config/macarchy-dfr: ~/.config/macarchy-touchbar already exists"
	elif [[ -d $CFG/macarchy-dfr ]]; then
		mv "$CFG/macarchy-dfr" "$CFG/macarchy-touchbar" \
			&& { note "config: macarchy-dfr -> macarchy-touchbar"; touched=1; }
	elif [[ -d $CFG/omarchy-dfr ]]; then
		mv "$CFG/omarchy-dfr" "$CFG/macarchy-touchbar" \
			&& { note "config: omarchy-dfr -> macarchy-touchbar"; touched=1; }
	fi
	if [[ -d $CFG/omarchy-dfr ]]; then
		if [[ -e $CFG/omarchy-dfr.bak ]]; then
			advise "left ~/.config/omarchy-dfr: ~/.config/omarchy-dfr.bak is already taken"
		else
			mv "$CFG/omarchy-dfr" "$CFG/omarchy-dfr.bak" \
				&& { note "config: kept the newer copy, backed the older up as omarchy-dfr.bak"; touched=1; }
		fi
	fi

	# --- state
	if [[ -d $ST/macarchy-dfr && ! -e $ST/macarchy-touchbar ]]; then
		mv "$ST/macarchy-dfr" "$ST/macarchy-touchbar" \
			&& { note "state: macarchy-dfr -> macarchy-touchbar"; touched=1; }
	elif [[ -d $ST/macarchy-dfr ]]; then
		advise "left ~/.local/state/macarchy-dfr: ~/.local/state/macarchy-touchbar already exists"
	fi
	for f in "$ST/omarchy-dfr.log" "$ST/omarchy-dfr-device.json"; do
		[[ -e $f ]] && rm -f "$f" && { note "removed stale ${f#"$HOME"/}"; touched=1; }
	done
	if [[ -d $ST/omarchy-als && ! -e $ST/macarchy-als ]]; then
		mv "$ST/omarchy-als" "$ST/macarchy-als" \
			&& { note "state: omarchy-als -> macarchy-als"; touched=1; }
	fi

	# --- binaries. ~/.local/bin is on PATH ahead of nothing in particular, so a
	# leftover here is a second, older copy of a daemon that still starts.
	for b in macarchy-dfr omarchy-als omarchy-battery-limit omarchy-bar-contrast \
	         omarchy-auto-appearance omarchy-dock omarchy-dock-theme \
	         omarchy-gtk-settings omarchy-locate omarchy-pinch omarchy-sun \
	         omarchy-zoom macos-dynamic-wallpaper; do
		if [[ -e $BIN/$b || -L $BIN/$b ]]; then
			rm -f "$BIN/$b" && { note "removed old ~/.local/bin/$b"; touched=1; }
		fi
		rm -f "$BIN"/__pycache__/"$b".*.pyc   # bytecode named after the script
	done
	rmdir "$BIN/__pycache__" 2>/dev/null

	# --- root-owned files. Not worth a sudo prompt of its own; say what to run.
	for f in /etc/udev/rules.d/70-macarchy-dfr.rules /etc/modules-load.d/macarchy-dfr.conf; do
		[[ -e $f ]] || continue
		if rm -f "$f" 2>/dev/null; then
			note "removed $f"; touched=1
		else
			advise "old $f is still there; remove it with: sudo rm -f $f"
		fi
	done

	# --- Hyprland wiring. Rewritten IN PLACE, not appended to: the guarded
	# appends below key on the command name, so an un-migrated block would leave
	# them wiring a second copy of every daemon.
	for lua in "$HOME/.config/hypr/autostart.lua" "$HOME/.config/hypr/bindings.lua"; do
		[[ -f $lua ]] || continue
		before=$(md5sum <"$lua")
		sed -i -E \
			-e 's/\b(macarchy|omarchy)-dfr\b/macarchy-touchbar/g' \
			-e 's/\bomarchy-(dock-theme|dock|bar-contrast|battery-limit|auto-appearance|gtk-settings|als|locate|pinch|sun|zoom)\b/macarchy-\1/g' \
			-e 's/\bmacos-dynamic-wallpaper\b/macarchy-dynamic-wallpaper/g' \
			"$lua"
		after=$(md5sum <"$lua")
		[[ $before == "$after" ]] || { note "$(basename "$lua"): renamed the old commands in place"; touched=1; }
	done

	(( touched )) || note "nothing from the old names is left"
}
migrate_legacy

# -------------------------------------------------------------- packages

say "Installing packages (pacman --needed)"
sudo pacman -S --needed --noconfirm \
	git base-devel pkgconf \
	wayland wayland-protocols mesa python \
	brightnessctl libinput rsync \
	tiny-dfr \
	|| warn "pacman failed; later steps may miss tools"
# tiny-dfr is installed but MASKED: macarchy-touchbar owns the Touch Bar now, and
# tiny-dfr is only what `macarchy-touchbar/install.sh --uninstall` falls back to.

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

# ----------------------------------------------------- macarchy-core suite

say "Installing the macarchy-core suite (scripts, hook, timer, udev rule, Touch Bar icons)"
if [[ -x $MACARCHY_DIR/macarchy-core/install.sh ]]; then
	(cd "$MACARCHY_DIR/macarchy-core" && ./install.sh --udev) || warn "macarchy-core install failed"
else
	warn "macarchy-core/install.sh missing"
fi

# ---------------------------------------------------------- macarchy-touchbar

say "Installing macarchy-touchbar (the Touch Bar daemon)"
if [[ -x $MACARCHY_DIR/macarchy-touchbar/install.sh ]]; then
	# Its own installer owns the whole story: packages, the icon font, the
	# video group, the uinput udev rule and modules-load, masking tiny-dfr,
	# the user unit, and migrating the Hyprland wiring left by its old names.
	(cd "$MACARCHY_DIR/macarchy-touchbar" && ./install.sh) || warn "macarchy-touchbar install failed"
else
	warn "macarchy-touchbar/install.sh missing"
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
append_once "$AUTO" "macarchy-touchbar.service" <<'LUA'

-- The Touch Bar (macarchy-touchbar): a systemd user service, so it restarts on
-- failure and logs to the journal. The unit is enabled too — this line only
-- makes the session-start explicit, and starting it twice is a no-op.
o.exec_on_start("systemctl --user start macarchy-touchbar.service")
LUA
append_once "$AUTO" "macarchy-dock" <<'LUA'

-- macOS-style dock. Autohiding against a bottom hotspot, so it costs no
-- screen space until you reach for it.
o.exec_on_start(os.getenv("HOME") .. "/.local/bin/macarchy-dock")
LUA
append_once "$AUTO" "macarchy-als daemon" <<'LUA'

-- Ambient-light auto-brightness: panel + keyboard backlight follow the AOP
-- light sensor; brightness keys teach it your preferred offset.
o.exec_on_start("macarchy-als daemon")
LUA
append_once "$AUTO" "macarchy-pinch" <<'LUA'

-- Four-finger pinch gestures (pinch in = launcher). Exits quietly until
-- libinput-tools is installed.
o.exec_on_start("macarchy-pinch")
LUA
append_once "$AUTO" "omarchy-aquarium-toggle restore" <<'LUA'

-- The animated aquarium background, put back the way it was left: "restore"
-- starts it unless it was deliberately toggled off in an earlier session.
o.exec_on_start("omarchy-aquarium-toggle restore")
LUA

say "Wiring bindings.lua"
BIND="$HOME/.config/hypr/bindings.lua"
# No Touch Bar binds any more: the old F13-F24 bridge existed because tiny-dfr
# could only emit key codes. macarchy-touchbar draws the bar itself, runs the
# commands itself, and types through its own uinput device.
append_once "$BIND" "omarchy-aquarium-toggle" <<'LUA'

-- ── Aquarium background ───────────────────────────────────────────────────
-- Animated underwater scene on the layer-shell "bottom" layer: above the
-- wallpaper, below every window. Toggling off falls straight back to the
-- normal wallpaper. (github.com/macarchy/omarchy-aquarium)
o.bind("SUPER + ALT + A", "Aquarium background", "omarchy-aquarium-toggle")
LUA
append_once "$BIND" "macarchy-zoom" <<'LUA'

-- ── Screen zoom ───────────────────────────────────────────────────────────
-- macOS accessibility zoom: hold CTRL and scroll to magnify the screen
-- around the cursor; scrolling back out lands exactly at 1x.
o.bind("CTRL + mouse_up", "Screen zoom in", "macarchy-zoom in")
o.bind("CTRL + mouse_down", "Screen zoom out", "macarchy-zoom out")
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
	systemctl --user start macarchy-touchbar.service 2>/dev/null && note "macarchy-touchbar started" || warn "macarchy-touchbar did not start (journalctl --user -u macarchy-touchbar)"
	pgrep -f "macarchy-als daemon" >/dev/null || { setsid macarchy-als daemon >/dev/null 2>&1 & note "started macarchy-als"; }
	pgrep -f macarchy-pinch >/dev/null || { setsid macarchy-pinch >/dev/null 2>&1 & note "started macarchy-pinch"; }
	omarchy-aquarium-toggle restore && note "aquarium restored to its remembered state"
else
	note "no Hyprland session: daemons start on next login (autostart.lua)"
fi

# ------------------------------------------------------------ health surface

say "Wiring the machine's own health report"
# doctor.sh becomes runtime code: the login unit needs a stable path for it, and
# it is worth having on PATH by hand anyway.
mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user"
install -m755 doctor.sh "$HOME/.local/bin/macarchy-doctor"
install -m644 systemd/macarchy-doctor.service systemd/macarchy-failed@.service \
	"$HOME/.config/systemd/user/"
systemctl --user daemon-reload
# enable, not --now: firing it here would grade the half-installed state it is
# standing in, and the tail of this script already runs ./doctor.sh once.
systemctl --user enable macarchy-doctor.service >/dev/null 2>&1 \
	&& note "macarchy-doctor runs at each login" \
	|| warn "could not enable macarchy-doctor.service"

# ----------------------------------------------------------------- done

say "Checking the result"
./doctor.sh || FAILURES=$((FAILURES+1))

if (( FAILURES )); then
	printf '\n\033[33mFinished with %d warning(s) — re-run after fixing, it is idempotent.\033[0m\n' "$FAILURES"
	exit 1
fi
printf '\n\033[1;32mmacarchy installed.\033[0m Log out and back in for a fully clean start.\n'
