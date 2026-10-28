# Development

## Repository layout

```
install.sh                     installer (root escalation, optional GitHub bootstrap)
uninstall.sh                   remover
etc/refresh-rate-sync.conf     default configuration  -> /etc/
lib/apply.sh                   root side              -> /usr/local/lib/refresh-rate-sync/
lib/set-mode.sh                session side           -> /usr/local/lib/refresh-rate-sync/
udev/85-refresh-rate-sync.rules                       -> /etc/udev/rules.d/
systemd/refresh-rate-sync.service                     -> /etc/systemd/system/
systemd/user/refresh-rate-sync-user.service           -> /usr/local/lib/systemd/user/
systemd/suspend.d/*.conf       resume drop-ins        -> /etc/systemd/system/<unit>.service.d/
icons/refresh-rate-*.svg       notification icons     -> /usr/share/icons/hicolor/scalable/apps/
docs/*.md                      this documentation    -> /usr/local/share/doc/refresh-rate-sync/docs/
tests/run-tests.sh             headless behavior tests (not installed)
tests/fixtures/*.txt|json      saved dumps of xrandr / wlr-randr / hyprctl / swaymsg
.github/workflows/ci.yml       CI: bash -n, shellcheck, test suite
```

The two shell scripts hold 100 % of the logic; the rest is glue.

## Data flow inside `set-mode.sh`

```
power_state()          -> "ac" | "bat" | "ignore"   (reads /sys/class/power_supply/*)
backend_candidates()   -> ordered list of candidate backends
list_<backend>()       -> normalized mode list          <-- the only per-desktop code
keep_output()          -> output filter (ONLY_INTERNAL / TARGET / SKIP)
pick_modes()           -> plan: NAME CUR_HZ TARGET_HZ MODE_ID WxH   (pure awk, 2 passes)
apply_one()            -> the actual command for the backend
list_<backend>() again -> verification
diff_modes()           -> "NAME OLD_HZ NEW_HZ" for what really changed
notify_change()        -> notify-send
```

### The normalized mode list

Every `list_*` function must print one line per mode:

```
NAME WIDTH HEIGHT Hz MODE_ID IS_CURRENT(0|1)
```

* `NAME` — output name as the backend reports it (`eDP-1`, `DP-4`, `HDMI-A-1`).
* `Hz` — the rate exactly as the backend prints it, so it can be fed back
  verbatim (`165.00`, `59.94`, `164.98`).
* `MODE_ID` — anything the apply command needs to identify that mode: a
  `kscreen-doctor` mode index, a Sway array index, or a generated `WxH@Hz`
  string for `xrandr`/`wlr-randr`/`hyprctl` (those ignore it and use W/H/Hz).
* `IS_CURRENT` — 1 on exactly one line per output: the mode in use now.

`WIDTH`/`HEIGHT`/`Hz` must be numeric; lines that fail that check are dropped.

## Adding a backend

1. Write `list_<name>()`: parse your tool's output into the format above.
2. Add a branch to `apply_one()`: `name w h rate id -> command`.
3. Add detection in `backend_candidates()` (a cheap, unambiguous probe: tool
   present **and** the session variable/socket it needs).
4. Add the name to the two `case` lists that validate `RRS_BACKEND`
   (`backend_candidates()` and the `--backend=` argument) and to `list_modes()`.
5. Test it offline with a fake tool (see below), then on a real session.

Keep resolution handling untouched: `pick_modes()` only ever considers modes
with the same `WIDTHxHEIGHT` as the current one.

## Testing

Run the suite first -- it needs no root, no display and no desktop session:

```bash
./tests/run-tests.sh
```

It runs `set-mode.sh --dry-run` against the dumps in `tests/fixtures/` using
stub commands injected through `PATH`, and asserts the guarantees:

* the resolution in the plan line is always the current one (`..., 1920x1080)`);
* `AC_HZ=max` picks the highest rate of that resolution, `BATTERY_HZ` the highest
  rate at or below the target, `min` the lowest;
* when no mode satisfies the target, the lowest mode of the *same* resolution is
  used instead of jumping to another resolution;
* `RATE_TOLERANCE` treats 59.94 as 60, and the output filters (`ONLY_INTERNAL`,
  `SKIP_OUTPUTS`, `TARGET_OUTPUTS`) work. Note the fixtures use `DP-1` and
  `eDP-1` on purpose: assert with an anchored regex (`^dry-run: DP-1 `), because
  `DP-1` is a substring of `eDP-1`.

The suite is hermetic: each case writes its own `XDG_CONFIG_HOME` override, which
is the last config file read, so an installed `/etc/refresh-rate-sync.conf`
cannot influence a test.

To exercise a single backend by hand:

```bash
mkdir -p /tmp/rrsfake && cd /tmp/rrsfake
printf '#!/bin/sh\ncat %s\n' "$OLDPWD/tests/fixtures/xrandr-1080p144.txt" > xrandr
chmod +x xrandr
PATH=/tmp/rrsfake:$PATH ./lib/set-mode.sh ac --dry-run --backend=x11
PATH=/tmp/rrsfake:$PATH ./lib/set-mode.sh bat --dry-run --backend=wlr
```

Sample inputs worth keeping around: an `xrandr -q` dump, a `wlr-randr` dump,
and `hyprctl monitors all -j` / `swaymsg -t get_outputs` JSON -- including the
old (`modes`) and new (`availableModes` / `available_modes`) key spellings.

Full round trip on a live session (this really changes the panel):

```bash
~/refresh-rate-sync/lib/set-mode.sh bat          # expect a notification, rate drops
~/refresh-rate-sync/lib/set-mode.sh ac           # back to max
kscreen-doctor -o | sed 's/\x1b\[[0-9;]*m//g' | grep -A1 'eDP-1' | grep Modes
```

Simulating the udev event without touching the cable:

```bash
sudo udevadm trigger --action=change --subsystem-match=power_supply
journalctl -t refresh-rate-sync -n 20
```

## Style and constraints

* `bash` with `set -uo pipefail` (no `-e` on purpose: the scripts must keep
  going when one output fails to change) and `umask 077`.
* Keep external commands to what a base install has: `sed`, `awk`, `grep`,
  `cat`, `sleep`, `printf`, `logger`. `jq` only for the two JSON backends.
* GNU `awk` is assumed (`SUBSEP`, `tostring` style arrays, `gensub` free); the
  scripts are ASCII-only so they work in any locale, including `LC_ALL=C` —
  every numeric `awk` invocation pins `LC_ALL=C`.
* Comments in English. User-visible strings are bilingual through `t <es> <en>`
  and follow `NOTIFY_LANG` / `LANG`.
* No write access outside `$XDG_RUNTIME_DIR` (the temp screenshot) — the tool
  never touches dotfiles.
* Keep everything idempotent: running it twice in a row must not notify twice
  and must not modeset twice.
* A run must stay under ~1 s of CPU and ~10 MB, and must exit: nothing may
  fork and survive.

## Known limitations

* GNOME backends not implemented (see [compatibility.md](compatibility.md)).
* VRR / adaptive sync is not read or written; the rate is a fixed mode.
* Only the mains adapter (`type=Mains`) is used as the power signal — on docks
  that report USB-C power as `type=USB`, the rate does not follow the dock.
* Multi-seat systems work but only for seated local sessions.
* A custom mode created with `xrandr --newmode` at a rate that is not in the
  EDID list is only usable after the X server has it loaded; `xrandr` backends
  will see it, `kscreen-doctor` may not.
