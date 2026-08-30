#!/bin/bash
# macarchy bootstrap — the curl-able entry point:
#
#   curl -fsSL https://raw.githubusercontent.com/macarchy/macarchy-install/main/boot.sh | bash
#
# Gets git, clones (or updates) this repo into $MACARCHY_DIR, and hands off
# to install.sh, which does everything else and is safe to re-run.
set -euo pipefail

MACARCHY_DIR="${MACARCHY_DIR:-$HOME/Work}"
SELF="$MACARCHY_DIR/macarchy-install"

command -v git >/dev/null || sudo pacman -S --needed --noconfirm git

mkdir -p "$MACARCHY_DIR"
if [[ -d $SELF/.git ]]; then
	git -C "$SELF" pull --ff-only -q || true
else
	git clone -q https://github.com/macarchy/macarchy-install "$SELF"
fi

exec "$SELF/install.sh"
