# refresh-rate-sync

Automatic refresh-rate switching for laptops on Linux: **max Hz while plugged
in**, **60 Hz on battery**, with a desktop notification (a little monitor icon)
telling you what changed.

| Power state     | Refresh rate                                        |
| --------------- | --------------------------------------------------- |
| AC adapter in   | the **highest** rate the panel offers (165 Hz here) |
| On battery      | **60 Hz** (configurable, also `min`)                |

**The resolution never changes.** Only the rate is touched, and always inside
the mode list of the resolution you are currently using:

| Current mode               | Plugged in             | On battery              |
| -------------------------- | ---------------------- | ----------------------- |
| `2560x1600 @ 165 Hz`       | `2560x1600 @ 165 Hz`   | `2560x1600 @ 60 Hz`     |
| `1920x1080 @ 144 Hz`       | `1920x1080 @ 144 Hz`   | `1920x1080 @ 60 Hz`     |
| `1680x1050 @ 120 Hz` (non native) | `1680x1050 @ 120 Hz` | `1680x1050 @ 60 Hz`   |
| `1920x1080 @ 144 Hz`, no 60 Hz mode in that resolution | unchanged | `1920x1080 @ 75 Hz` (lowest available) |

Every one of those cases is covered by the test suite ([tests/run-tests.sh](tests/run-tests.sh)).

The change is triggered by a **udev rule**, so while nothing happens the
project costs *nothing*: no daemon, no polling, no resident process. The only
thing that ever runs is a `Type=oneshot` service that lives about two seconds
(≈6 MB peak, ≈60 ms CPU).

Written for generic Linux. Tested on **CachyOS/Arch + KDE Plasma (Wayland)**;
also supports Hyprland, Sway/i3-wayland/Cosmic, any wlroots compositor and any
X11 session. No exotic dependencies: `bash`, `systemd`, `udev`, whatever your
desktop already ships (`kscreen-doctor`, `hyprctl`, `swaymsg`, `wlr-randr`,
`xrandr`) and `notify-send` for the notification.

```
unplug the charger ──► kernel uevent (POWER_SUPPLY_ONLINE=0)
                             │
                             ▼
             udev rule: SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ACTION=="change"
                             │  ← tables inside udev, no process, no CPU
                             ▼
             systemctl restart refresh-rate-sync.service      (oneshot, root)
                             │
                             ▼
             apply.sh  ── finds your graphical session (loginctl + /run/user/N + /proc/N/environ)
                             │
                             ▼
             set-mode.sh (as you, inside your session)
                 ├─ detects backend: KDE / Hyprland / Sway / wlroots / X11
                 ├─ keeps your resolution, picks the best matching Hz
                 ├─ applies, verifies, retries if needed
                 └─ notify-send "Refresh rate reduced"   eDP-1: 165 Hz → 60 Hz
```

---

## Install

```bash
# from a clone
git clone https://github.com/Je5us7/refresh-rate-sync
cd refresh-rate-sync
./install.sh            # re-executes itself through sudo (or a polkit dialog)
```

or the one-liner (it downloads only what it needs, installs and removes itself):

```bash
curl -fsSL https://raw.githubusercontent.com/Je5us7/refresh-rate-sync/main/install.sh \
  | sudo bash -s -- --repo=Je5us7/refresh-rate-sync
```

`--repo=` / `--ref=` select the repository and branch used for the download; if
you publish this project, set your own `Je5us7` in `GITHUB_REPO_DEFAULT` at the
top of `install.sh` and the flag becomes optional.

Uninstall:

```bash
./uninstall.sh              # or: ./install.sh --uninstall
```

Details, options and packaging notes: [docs/installing.md](docs/installing.md).

---

## Configure

`/etc/refresh-rate-sync.conf` — or per user in `~/.config/refresh-rate-sync.conf`.
**No restart is needed**: the service re-reads it on every event.

```ini
AC_HZ=max              # plugged in: "max" = highest the panel offers (or 165, 120, ...)
BATTERY_HZ=60          # on battery: Hz, or "max" / "min"
ONLY_INTERNAL=0        # 1 = never touch external monitors
RRS_BACKEND=auto       # auto | kde | hyprland | sway | wlr | x11
NOTIFY=1               # 0 = silent
NOTIFY_ICON=1          # "little monitor" icon in the notification
NOTIFY_SNAPSHOT=0      # 1 = also attach a screenshot thumbnail
NOTIFY_LANG=auto       # auto (follows $LANG) | es | en
SKIP_OUTPUTS=""        # e.g. "DP-3"
```

Common recipe — 165 Hz plugged in, 60 Hz on battery, laptop panel only:

```ini
AC_HZ=165
BATTERY_HZ=60
ONLY_INTERNAL=1
```

Full reference: [docs/configuration.md](docs/configuration.md).

---

## Test it without touching the cable

```bash
L=/usr/local/lib/refresh-rate-sync

sudo $L/apply.sh --status          # which session/environment it found
sudo $L/apply.sh bat --dry-run     # what it would do on battery
sudo $L/apply.sh ac  --dry-run     # what it would do plugged in
sudo $L/apply.sh bat               # force 60 Hz (notification included)
sudo $L/apply.sh ac                # back to max
$L/set-mode.sh ac --quiet          # run it yourself, no notification

sudo udevadm monitor -p -s power_supply     # watch the real unplug event
journalctl -t refresh-rate-sync -f          # watch what the service does
```

---

## Compatibility

| Desktop                        | Backend            | How the mode is set                     |
| ------------------------------ | ------------------ | --------------------------------------- |
| KDE Plasma (Wayland and X11)   | `kscreen-doctor`   | `output.<name>.mode.<id>`               |
| Hyprland                       | `hyprctl` + `jq`   | `hyprctl output mode WxH@Hz <output>`   |
| Sway / i3-wayland / Cosmic     | `swaymsg` + `jq`   | `swaymsg output <name> mode <index>`    |
| wlroots (labwc, river, Wayfire, …) | `wlr-randr`    | `wlr-randr --output <name> --mode WxH@Hz` |
| X11 sessions                   | `xrandr`           | `xrandr --output <name> --mode WxH --rate Hz` |

* The **resolution is never changed**: only the refresh rate, always among the
  modes the panel declares (EDID).
* 50/59.94/60.00 Hz variants are handled with a tolerance, so it does not
  oscillate between "same" rates.
* **GNOME** is not supported yet (Mutter needs the whole output configuration
  rebuilt through `org.gnome.Mutter.DisplayConfig`); the service just notifies
  and does not touch anything. Adding a `gnome` backend is straightforward.
* After suspend/hibernate the rate is re-applied automatically (drop-ins in
  `systemd-suspend.service.d/`, `systemd-hibernate.service.d/`, ...).
* It also runs when your graphical session starts, so the rate is correct from
  the moment you log in.

More: [docs/compatibility.md](docs/compatibility.md).

---

## What gets installed

| Path | Purpose |
| ---- | ------- |
| `/usr/local/lib/refresh-rate-sync/{apply,set-mode}.sh` | the whole logic |
| `/usr/local/lib/refresh-rate-sync/icons/` | notification icons |
| `/etc/refresh-rate-sync.conf` | configuration |
| `/etc/udev/rules.d/85-refresh-rate-sync.rules` | the trigger |
| `/etc/systemd/system/refresh-rate-sync.service` | oneshot started by that rule |
| `/usr/local/lib/systemd/user/refresh-rate-sync-user.service` | oneshot at session start |
| `/etc/systemd/system/systemd-{suspend,hibernate,...}.service.d/10-refresh-rate-sync.conf` | re-apply after resume |
| `/usr/share/icons/hicolor/scalable/apps/refresh-rate-{ac,battery}.svg` | the "little monitor" icons |
| `/usr/local/share/doc/refresh-rate-sync/` | this README and the docs |

---

## Documentation

* [docs/index.md](docs/index.md) — documentation home
* [docs/architecture.md](docs/architecture.md) — how it works, why it costs nothing
* [docs/configuration.md](docs/configuration.md) — every option
* [docs/compatibility.md](docs/compatibility.md) — desktops, backends, edge cases
* [docs/installing.md](docs/installing.md) — options, packaging, other distros
* [docs/troubleshooting.md](docs/troubleshooting.md) — common problems
* [docs/development.md](docs/development.md) — data flow, adding a backend, style

---

## Tests

The interesting property is that the rate changes and the resolution does not,
so it is pinned by a suite that runs headless, without root and without a
display server: every case feeds a saved `xrandr` / `wlr-randr` / `hyprctl` /
`swaymsg` dump to `set-mode.sh --dry-run` through a stub command in `PATH`.

```bash
./tests/run-tests.sh
# 27 passed, 0 failed
```

Fixtures live in `tests/fixtures/`; how to add a case is described in
[docs/development.md](docs/development.md). GitHub Actions runs the suite plus
`bash -n` and `shellcheck` on every push ([.github/workflows/ci.yml](.github/workflows/ci.yml)).

---

## License

MIT — see [LICENSE](LICENSE).
