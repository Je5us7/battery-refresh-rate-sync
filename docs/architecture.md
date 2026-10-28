# Architecture

## The problem with the usual approach

Most "auto refresh rate" hacks are a shell loop that polls
`/sys/class/power_supply/*/online` every few seconds, or a tray applet that
keeps a D-Bus subscription alive. Both sit in RAM forever, wake up on timers,
and have to be started per user, per desktop.

This project has **no resident process at all**.

## The trigger chain

```
   kernel: charger online -> power_supply_changed() -> KOBJ_CHANGE uevent
                                   │
                                   ▼
   udevd (always running, part of every Linux) evaluates its rule table:
       ACTION=="change", SUBSYSTEM=="power_supply", ATTR{type}=="Mains"
         RUN+="/usr/bin/systemctl --no-block restart refresh-rate-sync.service"
                                   │
                                   ▼
   systemd starts a Type=oneshot unit  ──  it runs ~2 s and goes back to
                                          "inactive (dead)": zero cost
                                   │
                                   ▼
   lib/apply.sh        (root)   reads the power state, finds the graphical
                                sessions, reconstructs their environment and
                                drops privileges
                                   │
                                   ▼
   lib/set-mode.sh     (user)   backend detection -> mode table -> plan ->
                                apply -> verify -> retry -> notification
```

Three extra safety nets, all of them oneshot and event-driven:

| Unit | When it runs |
| ---- | ------------ |
| `refresh-rate-sync.service` (`WantedBy=multi-user.target`) | once at boot |
| `refresh-rate-sync-user.service` (`WantedBy=graphical-session.target`) | at each graphical login |
| drop-ins on `systemd-suspend.service` / `systemd-hibernate.service` / `systemd-hybrid-sleep.service` / `systemd-suspend-then-hibernate.service` | right after resume (`ExecStartPost` of those units runs when the machine is awake again) |

## Why "zero resources" is not marketing

* A udev rule is a line in a table evaluated when an event arrives. There is no
  process, no thread, no fd, no timer.
* `Type=oneshot` with `RemainAfterExit=no` means the unit is *dead* between
  events: no PID, no memory, no cgroup.
* There is no `.timer`, no `WatchdogSec`, no socket, no D-Bus name owned.
* `MemoryMax=192M` and `Nice=10` bound the burst, not the idle.

Verify on a running system:

```bash
systemctl status refresh-rate-sync.service      # Active: inactive (dead)
pgrep -af refresh-rate                          # (no output)
systemd-analyze critical-chain refresh-rate-sync.service   # not in the boot path
journalctl -b -t refresh-rate-sync              # what it did, and its peak RAM/CPU
```

Example of a real event, straight from the journal (peak memory 5.7 MB, 60 ms
of CPU, then dead again):

```
Process: 217142 ExecStart=/usr/local/lib/refresh-rate-sync/apply.sh auto (code=exited, status=0/SUCCESS)
     Mem peak: 5.7M
      CPU: 60ms
```

## Responsibilities: why two scripts

`apply.sh` runs as root, because reading the environment of another user's
processes (`/proc/<pid>/environ`) and starting things inside a login session
requires privileges. It never touches the screen itself.

`set-mode.sh` runs as the session user, because display servers and compositors
only accept requests from the owner of the session (Wayland sockets, X11
authority, the compositor's IPC socket, the session D-Bus). Everything screen
related lives here, so it can also be run by hand without root:

```bash
/usr/local/lib/refresh-rate-sync/set-mode.sh ac --dry-run
```

## How the session environment is reconstructed

`loginctl` tells us *which* sessions exist (`Type=wayland|x11`, `Class=user`,
`Remote=no`, with a seat) but not the compositor's socket names. So `apply.sh`:

1. prefers processes of that UID whose `comm` is a known compositor or desktop
   shell (`kwin_wayland`, `Hyprland`, `sway`, `gnome-shell`, `plasmashell`, ...)
   and reads their `environ` (`WAYLAND_DISPLAY`, `DISPLAY`, `SWAYSOCK`,
   `HYPRLAND_INSTANCE_SIGNATURE`, `DBUS_SESSION_BUS_ADDRESS`, `XAUTHORITY`,
   `XDG_CURRENT_DESKTOP`, `LANG`);
2. stops as soon as it has a Wayland socket plus a session bus;
3. otherwise discovers the sockets on its own: `/run/user/N/wayland-*`,
   `/run/user/N/.X11-unix/X*`, `/tmp/.X11-unix/X*`, `/run/user/N/bus`;
4. adds the baseline (`HOME` from the passwd entry, `USER`, `PATH`,
   `XDG_RUNTIME_DIR`, `XDG_SESSION_TYPE`).

The command is then launched with a clean, explicit environment:

```bash
runuser -u alice -- env -i WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR=/run/user/1000 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus ... \
    bash /usr/local/lib/refresh-rate-sync/set-mode.sh bat
```

`runuser` is used when present, otherwise `setpriv`, otherwise `sudo -n -u`.

## Mode selection

`set-mode.sh` normalizes whatever the backend reports into one line per mode:

```
NAME WIDTH HEIGHT Hz MODE_ID IS_CURRENT(0|1)
```

then, **for the current resolution only**:

* `AC_HZ=max` → the highest rate available;
* `BATTERY_HZ=60` → the highest rate ≤ 60 Hz; if the panel has nothing at or
  below 60 Hz, the lowest rate it has;
* `RATE_TOLERANCE` (default 1.0 Hz) prevents pointless switches between
  59.94/60.00 and 164.98/165.00 variants of the same mode.

The resolution is never changed, and only modes reported by the panel (EDID)
are used, so nothing is ever pushed that the screen cannot display. Custom
modes a user created (`xrandr --newmode`) show up in the listings too and are
honored.

After applying, the list is re-read and compared with the target; anything not
confirmed is retried (`RETRIES`/`RETRY_DELAY`). That matters right after
unplugging, when the firmware may still be settling, and after resume.

## Notifications

Only sent when something actually changed, so plugging in an already-max panel
is silent. `notify-send` with:

* an absolute path to the installed SVG (so the "little monitor" pictogram is
  shown whatever the icon theme),
* the transition per output, e.g. `eDP-1: 165 Hz → 60 Hz`,
* optionally a screenshot thumbnail (`NOTIFY_SNAPSHOT=1`, uses
  `grimshot`/`grim`/`spectacle`/`gnome-screenshot`/`scrot`/ImageMagick, and
  down-scales with ImageMagick when available).

Strings exist in Spanish and English; `NOTIFY_LANG=auto` follows `LANG`.
