# macarchy-install

One command from a fresh [Omarchy](https://omarchy.org) install on
[Asahi Linux](https://asahilinux.org) to the full
[macarchy](https://github.com/macarchy) experience:

    curl -fsSL https://raw.githubusercontent.com/macarchy/macarchy-install/main/boot.sh | bash

Or, with the repo already cloned:

    ./install.sh

## What it sets up

| Piece | From | What you get |
|---|---|---|
| [omarchy-mac](https://github.com/macarchy/omarchy-mac) | `install.sh --udev` | Ambient-light auto-brightness, 80% battery charge limit + udev rule, macOS dock, 4-finger pinch gestures, CTRL+scroll screen zoom, Cmd-key grammar, app switcher, light/dark auto-appearance timer |
| [macarchy-dfr](https://github.com/macarchy/macarchy-dfr) | `install.sh` | The Touch Bar, drawn by us: a systemd **user** service that owns the panel over DRM and its touch surface over evdev, with tiny-dfr masked out of the way |
| [omarchy-aquarium](https://github.com/macarchy/omarchy-aquarium) | `make install` | Animated GLSL underwater background (SUPER+ALT+A), theme-set hook, notification startle watcher |
| [apple-glass](https://github.com/macarchy/apple-glass) / [-light](https://github.com/macarchy/apple-glass-light) | rsync into `~/.config/omarchy/themes` | The glass themes, tuned against the aquarium |
| Hyprland wiring | guarded appends | Aquarium bind, zoom binds, daemon autostarts in `~/.config/hypr/{bindings,autostart}.lua` (no Touch Bar binds: macarchy-dfr runs its own commands) |

## Idempotent by design

Every step converges or skips with a note:

- packages go through `pacman --needed`
- repos are cloned into `$MACARCHY_DIR` (default `~/Work`), fast-forwarded
  when clean, and **left alone when you have local changes**
- config blocks are appended once, keyed on the command they wire — your
  edits around them survive
- themes are synced from the repos (the live dirs are copies, per the
  macarchy convention), then re-applied with `omarchy theme set` so the
  running session actually picks them up

Re-running after a partial failure — or just to pull updates — is the
intended workflow.

## Doctor

    ./doctor.sh

Read-only health check: binaries, udev rules, the uinput module-load,
tiny-dfr masked and the macarchy-dfr unit enabled, the auto-appearance timer,
Hyprland wiring, themes, and (inside a session) the running daemons.
`install.sh` runs it at the end.

### Proved in CI

Every pull request, and every push to `main`, runs `tests/clean-machine.sh` on
a clean `ubuntu-24.04-arm` runner — a real aarch64 machine, so the arch gate
passes without a bypass. It runs `install.sh` **twice**, then `doctor.sh`, then
a Lua syntax check on the appended blocks. That proves the `~/.local/bin`
binaries land, the udev rules and the uinput module-load are installed, tiny-dfr
is masked, the systemd user units enable, the Hyprland wiring lands exactly
once, the themes sync, the theme hook installs, and the aquarium C code builds.

What a clean-machine run can **never** prove, and only this laptop can:

- that the Touch Bar draws anything (no DRM card, no evdev panel — only that
  the unit enables)
- that the charge limit caps at 80% (no `macsmc-battery` — the one honest
  `skip` in `doctor.sh`)
- that the aquarium renders (no compositor, no GPU, no layer-shell — only that
  it compiles and installs)
- that the `autostart.lua` lines ever *fire* (only that they parse and are
  present once)
- that `pacman` resolves the named packages on Arch/ALARM (a stub answers yes
  and echoes every call)
- that polkit's interactive path works (replaced by passwordless sudo)
- anything about `omarchy theme set` (neither `omarchy` nor `omarchy-theme-set`
  exists on a runner, so that block self-skips)
- anything about the `video`-group and uinput permissions taking effect after a
  re-login

## Requirements

- Apple Silicon Mac on Asahi Linux (`linux-asahi`, aarch64)
- Omarchy installed
- sudo / polkit (udev rules, packages, masking tiny-dfr)

Machines that aren't Touch Bar Macs still get everything else: the Touch Bar
pieces install but idle without the hardware.
