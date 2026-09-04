#!/bin/bash
# Prove install.sh + doctor.sh on a machine that is not this laptop.
#
# Two "nobody wired the startup" bugs survived because install.sh only ever ran
# on the one Mac it was written for. This runs it for real on a clean aarch64
# box: the arch gate passes honestly (GitHub's ubuntu-24.04-arm runner IS
# aarch64), pacman and pkexec are shimmed, and doctor.sh -- the same checker the
# laptop uses -- is the assertion. Nothing is faked green; the one check no
# non-Apple machine can satisfy prints "skip".
#
# DESTRUCTIVE: it writes into $HOME, /etc/udev/rules.d, /etc/modules-load.d and
# the system unit state (it masks tiny-dfr). Throwaway machines only.
set -uo pipefail

[[ ${MACARCHY_DESTRUCTIVE_OK:-} == 1 || ${GITHUB_ACTIONS:-} == true ]] || {
	echo "refusing: this installs into /etc and $HOME (MACARCHY_DESTRUCTIVE_OK=1 on a throwaway box)" >&2
	exit 2
}

cd "$(dirname "$0")/.." || exit 1
export MACARCHY_DIR="${MACARCHY_DIR:-$(mktemp -d)}"
export MACARCHY_NO_HARDWARE='no macsmc battery on a CI runner'

# /usr/local/bin because it is inside sudo's secure_path (and ahead of
# /usr/bin, so it also shadows a real polkit pkexec, which cannot work headless).
sudo tee /usr/local/bin/pacman >/dev/null <<'EOF'
#!/bin/bash
# Stub: every package operation is ECHOED, never silent. Exit 0 on -Qi so
# macarchy-dfr believes python-cairo/python-gobject are present instead of
# trying to install them. This is the biggest thing CI cannot prove.
echo "[stub] pacman $*"
EOF
sudo tee /usr/local/bin/pkexec >/dev/null <<'EOF'
#!/bin/bash
# pkexec means "run this as root with authorization". Headless, passwordless
# sudo IS that authorization -- the udev rule, modules-load and the tiny-dfr
# mask really are installed, and doctor really observes them.
exec sudo "$@"
EOF
sudo chmod 755 /usr/local/bin/pacman /usr/local/bin/pkexec

# What a fresh Omarchy machine already has. omarchy-mac/install.sh does
# `install -m644 keys/macarchy-keys.lua "$HOME/.config/hypr/..."` with no mkdir
# under `set -e`, and macarchy-dfr's migration block appends to autostart.lua in
# the same directory: without this the suite dies there.
mkdir -p "$HOME/.config/hypr"
sudo mkdir -p /usr/share/omarchy

# A real systemd user manager, or the `systemctl --user is-enabled` checks would
# report nothing and degrade into passes-by-absence. Loud on failure by design.
sudo loginctl enable-linger "$USER"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
for _ in {1..30}; do
	systemctl --user show -p Version --value >/dev/null 2>&1 && break
	sleep 1
done
systemctl --user show -p Version --value >/dev/null 2>&1 || {
	echo "no systemd --user bus here; the unit checks would be meaningless" >&2
	exit 1
}

./install.sh || exit 1   # it runs doctor.sh itself at the end, so a MISS reds here
sha256sum "$HOME/.config/hypr/autostart.lua" "$HOME/.config/hypr/bindings.lua" >"$MACARCHY_DIR/lua.sha"

# The daemon cannot run without a Touch Bar, so it spends its restart budget;
# a spent budget makes the second install's `systemctl restart` fail for a
# reason that has nothing to do with the install. No-op if it never started.
systemctl --user stop macarchy-dfr.service 2>/dev/null
systemctl --user reset-failed macarchy-dfr.service 2>/dev/null

./install.sh || exit 1
sha256sum -c "$MACARCHY_DIR/lua.sha" || {
	echo 'install.sh is not idempotent: a guarded append landed twice' >&2
	exit 1
}

# The one failure doctor cannot see: a syntax error in an appended block kills
# the whole Hyprland session at next login. Syntax only; it does not follow the
# dofile into macarchy-keys.lua.
luac5.4 -p "$HOME/.config/hypr/autostart.lua" "$HOME/.config/hypr/bindings.lua" || exit 1
