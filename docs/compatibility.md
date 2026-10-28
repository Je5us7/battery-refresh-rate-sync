# Compatibility

Requirements: Linux with **systemd** and **udev** (i.e. essentially every
distribution except runit/runit-based or sysvinit-only setups — see
*Non-systemd* below), `bash`, `awk` (GNU or busybox with `printf`/`SUBSEP`),
`sed`, and a notification daemon with `notify-send` (`libnotify`).

## Desktops and backends

| Desktop | Backend | Command used to change the mode | Notes |
| ------- | ------- | ------------------------------- | ----- |
| KDE Plasma 5 / 6, Wayland | `kscreen-doctor` | `kscreen-doctor output.eDP-1.mode.72` | Needs `WAYLAND_DISPLAY` (Plasma 6 talks to KWin through the Wayland socket). Mode ids come from `kscreen-doctor -o`. |
| KDE Plasma, X11 | `kscreen-doctor` | same | Also works; `xrandr` is a valid alternative here (`--backend=x11`). |
| Hyprland | `hyprctl` + `jq` | `hyprctl output mode 2560x1600@164.98 eDP-1` | `HYPRLAND_INSTANCE_SIGNATURE` is auto-discovered from `/run/user/N/hyprland/`. Handles both `modes` and `availableModes` JSON. |
| Sway | `swaymsg` + `jq` | `swaymsg output eDP-1 mode 1` (index) | `SWAYSOCK` auto-discovered from `/run/user/N/sway-ipc.*/`. Handles `modes` (< 3.0) and `available_modes` (≥ 3.0). |
| i3 on Wayland, Cosmic, river, Wayfire, labwc, Cage, Rootston… | `wlr-randr` | `wlr-randr --output eDP-1 --mode 1920x1080@60` | Any compositor implementing `wl_output_mode` + the `wlr-output-management` protocol. |
| X11 (any WM/DE) | `xrandr` | `xrandr --output eDP-1 --mode 2560x1600 --rate 60` | Also fine inside XWayland-only setups where `xrandr` can reach the X server. |
| GNOME / deepin / others | – | – | Not supported yet; see below. |

If several tools exist (a Plasma session with `xrandr` installed, for example),
`auto` picks the one that matches the running session, and you can force another
one with `RRS_BACKEND=` in the config or `--backend=` on the command line.

## GNOME

Mutter exposes display configuration over
`org.gnome.Mutter.DisplayConfig`, but changing a mode means re-sending the
whole layout (every output, geometry, scale, transform, mode id list). A
`gnome` backend is therefore a bigger chunk of code than the other five and is
not implemented yet; on GNOME the service logs and notifies that no backend is
available and leaves the screen alone.

## Wayland sessions without a CLI

A Wayland compositor with no command line tool at all (some mobile/immutable
setups) cannot be driven from a script; install `wlr-randr` if your compositor
supports the output-management protocol, otherwise nothing can be done.

## Non-systemd setups

The trigger relies on udev `RUN+=` + `systemctl`. On runit / OpenRC / sysvinit
images without systemd you can still use the logic directly from a udev rule:

```
ACTION=="change", SUBSYSTEM=="power_supply", ATTR{type}=="Mains", \
  RUN+="/usr/local/lib/refresh-rate-sync/set-mode.sh auto"
```

In that case the rule runs as root, so `set-mode.sh` needs the session
environment exported into the rule (or wrap it in a small `su`/`setsid` helper).

## Kernel / firmware quirks

* **Multiple uevents per unplug.** Some firmware emits `change` several times;
  the `restart` job merges them and the plan is idempotent, so nothing flips
  back and forth.
* **Charger named differently.** `ADP0`, `AC`, `power`, `PWR`, `820976CA`,
  `tpacpi-bat`… The rule matches on `ATTR{type}=="Mains"`, which is
  distribution- and vendor-neutral, with one fallback rule for drivers that do
  not export `type`.
* **USB-C / dock power.** Devices of `type=USB` (`ucsi-source-psy-*`) are
  deliberately *not* treated as mains, so plugging a hub does not switch rates.
* **Modes re-set after resume.** Handled by the `systemd-suspend.service.d`
  drop-ins; if your driver is very slow, raise `RETRIES` / `RETRY_DELAY`.
* **Fractional scaling / mixed DPI:** untouched — only the mode is changed, so
  KWin/mutter re-applies scaling on its own.
