# Configuration

Two files are read, in this order (the last one wins):

1. `/etc/battery-refresh-rate-sync.conf` — system wide, installed by `install.sh`
2. `~/.config/battery-refresh-rate-sync.conf` — per user (only seen by `set-mode.sh`,
   which is the part that runs inside your session)

Format: plain `KEY=value` shell assignments, `#` comments. Since the service is
started on demand and re-reads the file on every event, **saving the file is
enough** — no daemon to restart, no logout needed.

Verify what is in effect:

```bash
sudo /usr/local/lib/battery-refresh-rate-sync/apply.sh bat --dry-run   # target: BATTERY_HZ
```

---

## Refresh rates

| Key | Default | Meaning |
| --- | ------- | ------- |
| `AC_HZ` | `max` | Rate when the mains adapter is online. `max` = highest mode the panel offers at the current resolution, or a number: `165`, `120`, `90`. |
| `BATTERY_HZ` | `60` | Rate on battery. A number, `max`, or `min` (lowest mode available). If no mode is ≤ the target, the lowest available one is used. |
| `RATE_TOLERANCE` | `1.0` | Hz difference below which the output is considered "already correct". Avoids flip-flopping between `59.94`, `60.00`, `164.98`, `165.00`. |

## Which outputs

| Key | Default | Meaning |
| --- | ------- | ------- |
| `ONLY_INTERNAL` | `0` | `1` = only the built-in panel (`eDP*`, `LVDS*`, `DSI*`, `DSL*`); external monitors untouched. |
| `TARGET_OUTPUTS` | `""` | If non-empty, handle *only* these outputs (space separated), e.g. `"eDP-1 DP-4"`. |
| `SKIP_OUTPUTS` | `""` | Outputs to ignore, e.g. `"DP-3"`. |
| `NO_BATTERY_STATE` | `ac` | Behavior on machines with no battery (desktops): treat as `ac`, as `bat`, or `ignore` (do nothing at all). |

Names come from your backend: `kscreen-doctor -o`, `xrandr -q`, `wlr-randr`,
`hyprctl monitors`, `swaymsg -t get_outputs`.

## Backend

| Key | Default | Meaning |
| --- | ------- | ------- |
| `BFRS_BACKEND` | `auto` | `auto`, or force one of `kde`, `hyprland`, `sway`, `wlr`, `x11`. |

With `auto` the first backend that returns a usable mode list wins, in this
order: KDE (`kscreen-doctor`) → Hyprland (`hyprctl` + `jq`) → Sway (`swaymsg` +
`jq`) → generic wlroots (`wlr-randr`) → X11 (`xrandr`). KDE comes first because
on Plasma/Wayland it is the only CLI that can change modes.

Command line override (wins over the config file): `--backend=kde`.

## Notifications

| Key | Default | Meaning |
| --- | ------- | ------- |
| `NOTIFY` | `1` | `0` = never show anything. |
| `NOTIFY_ICON` | `1` | Use the installed `battery-refresh-rate-ac.svg` / `battery-refresh-rate-battery.svg` (a little monitor with an up/down arrow). |
| `NOTIFY_SNAPSHOT` | `0` | `1` = attach a screenshot thumbnail to the notification. |
| `NOTIFY_TIMEOUT` | `5000` | Lifetime in ms. |
| `NOTIFY_FAIL` | `1` | Also notify when the change could not be made. |

## Retries and timing

| Key | Default | Meaning |
| --- | ------- | ------- |
| `SETTLE_DELAY` | `1` | Seconds between applying a mode and verifying it. |
| `RETRIES` | `2` | Extra apply rounds when the mode did not stick. |
| `RETRY_DELAY` | `2` | Seconds between those rounds. |
| `BACKEND_RETRIES` | `3` | Retries while the desktop is still starting (login race). |
| `BACKEND_RETRY_DELAY` | `2` | Seconds between them. |
| `MIN_WAIT` | `1` | Root side: settling time after the uevent, before doing anything. |

## Multi-user systems

| Key | Default | Meaning |
| --- | ------- | ------- |
| `USERS_WANTED` | `""` | Empty = every local graphical session. Otherwise a space separated list, e.g. `"alice bob"`. |
| `LIBEXEC` | `/usr/local/lib/battery-refresh-rate-sync` | Where `set-mode.sh` lives; only needed with `install.sh --libexec=`. |

Only local, seated, `Class=user`, `Remote=no`, `Type=wayland|x11` sessions are
considered, so SSH sessions and headless users are ignored.

---

## Examples

**Keep the panel at 165 Hz on AC, 60 Hz on battery, and leave the external
monitor alone** (the typical gaming laptop):

```ini
AC_HZ=max
BATTERY_HZ=60
ONLY_INTERNAL=1
```

**Cap everything at 120 Hz and be quiet:**

```ini
AC_HZ=120
BATTERY_HZ=60
NOTIFY=0
```

**Aggressive battery saving** (lowest available rate, plus the mode is
re-asserted after resume):

```ini
BATTERY_HZ=min
RATE_TOLERANCE=0.5
```

**Desktop that should never be touched:**

```ini
NO_BATTERY_STATE=ignore
```

**Per user override**, e.g. user `bob` wants a screenshot thumbnail in the
notification and one monitor left out (`~/.config/battery-refresh-rate-sync.conf`):

```ini
NOTIFY_SNAPSHOT=1
SKIP_OUTPUTS="DP-3 DP-4"
```
