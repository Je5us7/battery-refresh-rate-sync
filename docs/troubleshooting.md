# Troubleshooting

All the program's output goes to the journal under the tag `refresh-rate-sync`:

```bash
journalctl -t refresh-rate-sync -f              # follow
journalctl -b -t refresh-rate-sync              # this boot
journalctl --user -t refresh-rate-sync          # user unit runs at login
```

---

## Nothing happens when I unplug the charger

Check the trigger first — everything else is downstream:

```bash
sudo udevadm monitor -p -s power_supply         # then unplug
```

* **No event appears.** The kernel is not reporting the change. Look at
  `ls /sys/class/power_supply/` and check which device is the mains one:

  ```bash
  for d in /sys/class/power_supply/*/; do echo "$d $(cat $d/type 2>/dev/null) online=$(cat $d/online 2>/dev/null)"; done
  ```

  If the mains device exists but has no `type` attribute, the fallback rule
  covers only common names (`ADP*`, `AC*`, `power`, …). Add your name to
  `/etc/udev/rules.d/85-refresh-rate-sync.rules`, then
  `sudo udevadm control --reload-rules`.

* **The event appears but no service run.** Validate the rule and see whether it
  matched:

  ```bash
  sudo udevadm verify /etc/udev/rules.d/85-refresh-rate-sync.rules
  sudo udevadm test /sys/class/power_supply/ADP0 2>&1 | grep -E 'refresh-rate|RUN'
  ```

  Common cause: `systemctl` is not at `/usr/bin/systemctl` (Debian-based systems
  with a separate `/bin` symlink are fine, but if your udev runs before
  `/usr` is mounted the rule cannot work).

* **The service ran but did nothing** — read its journal lines: it tells you the
  state it detected, the session it found, the backend and the plan.

## It says "no active local graphical session"

`apply.sh` only accepts a session that is `Class=user`, `Remote=no`, has a seat
and `Type=wayland|x11`. Check:

```bash
loginctl list-sessions
loginctl show-session <ID> -p Type -p Class -p Remote -p Active
sudo /usr/local/lib/refresh-rate-sync/apply.sh --status
```

Typical cases: you are logged in through SSH only, you are inside a display
manager greeter, or the compositor has not started yet.

## It says "no backend available"

The tool for your desktop is missing, or it was called without the session
environment:

```bash
wayland-socket=$(ls /run/user/$UID/wayland-* 2>/dev/null)   # wayland?
echo "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}  DISPLAY=${DISPLAY:-}"
command -v kscreen-doctor hyprctl swaymsg wlr-randr xrandr
```

* Plasma/Wayland: needs `kscreen-doctor` (package `kscreen` / part of Plasma).
* Hyprland / Sway: also needs `jq`.
* wlroots: install `wlr-randr`.
* X11: install `xrandr` (`xorg-xrandr` / `x11-utils`).

Force one to test: `--backend=x11`.

## The rate changes but I see no notification

```bash
notify-send test                                 # does your daemon work at all?
journalctl -t refresh-rate-sync | grep -i notify # did we try?
```

* `libnotify`/`notify-send` may be missing (`pacman -S libnotify`,
  `apt install libnotify-bin`, `dnf install libnotify`).
* The notification *is* suppressed when nothing changed — that is by design.
* Under a notification daemon with "do not disturb" / expired-notification
  filtering, raise `NOTIFY_TIMEOUT` or check the daemon's bell settings.
* If the icon is missing, re-run `install.sh` (it installs
  `/usr/share/icons/hicolor/scalable/apps/refresh-rate-*.svg` and refreshes the
  icon cache).

## The rate does not come back after resume

The resume drop-ins re-apply it. If it still fails:

```bash
systemctl cat systemd-suspend.service | grep -A2 ExecStartPost
journalctl -b -t refresh-rate-sync | grep -i resume   # look for the run right after waking
```

Raise `RETRIES=4` and `RETRY_DELAY=3` for drivers that take their time, or
`SETTLE_DELAY=2`.

## You want different behaviour

Edit `/etc/refresh-rate-sync.conf` (see [configuration.md](configuration.md));
the change takes effect on the next event, no restart needed. To force an event
right now:

```bash
sudo systemctl restart refresh-rate-sync.service
```

## Uninstall

```bash
./uninstall.sh                    # or ./install.sh --uninstall
```

Leaves the current screen mode as it is, and only removes its own files.
