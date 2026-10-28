# Installing

## From a clone

```bash
git clone https://github.com/Je5us7/battery-refresh-rate-sync
cd refresh-rate-sync
./install.sh
```

`install.sh` re-executes itself as root when it is started as a normal user:
it uses `sudo` if present, otherwise `pkexec` (a polkit password dialog appears
on screen). Everything after that is non-interactive.

## One-liner (nothing to clone)

```bash
curl -fsSL https://raw.githubusercontent.com/Je5us7/battery-refresh-rate-sync/main/install.sh \
  | sudo bash -s -- --repo=Je5us7/battery-refresh-rate-sync --ref=main
```

When the script cannot find `lib/set-mode.sh` next to itself it downloads the
whole file list into a temporary directory, installs it and deletes the
directory. `wget` works too, so no `curl` dependency on a machine that lacks it.

If you fork/publish the project, edit `GITHUB_REPO_DEFAULT` at the top of
`install.sh` and the `--repo=` flag becomes unnecessary:

```bash
GITHUB_REPO_DEFAULT="${GITHUB_REPO:-yourgithubuser/refresh-rate-sync}"
```

## Options

| Option | Effect |
| ------ | ------ |
| `--repo=OWNER/NAME` | repository to download from when the tree is not next to the script |
| `--ref=BRANCH\|TAG` | git ref to download (default `main`) |
| `--dest=PATH` | install into an alternate root (equivalent to `DESTDIR=`), units are not enabled there |
| `--libexec=PATH` | where the scripts go (default `<dest>/usr/local/lib/refresh-rate-sync`); a `LIBEXEC=` line is added to the config so `apply.sh` finds `set-mode.sh` |
| `--force-config` | overwrite `/etc/refresh-rate-sync.conf` instead of writing `.dpkg-new` |
| `--no-apply` | do not apply the current power state at the end of the install |
| `--skip-user-unit` | do not enable the per-session user unit |
| `--uninstall` | same as running `uninstall.sh` |
| `--help` | usage |

Environment equivalents: `DESTDIR`, `LIBEXEC`, `GITHUB_REPO`, `GITHUB_REF`.

Examples:

```bash
sudo DESTDIR=/mnt ./install.sh                     # install into a chroot/image
sudo ./install.sh --force-config                   # take the new default config
sudo ./install.sh --no-apply --skip-user-unit      # package-friendly install
sudo ./uninstall.sh --keep-config                  # remove, keep the config
```

## What enabling means

* `refresh-rate-sync.service` is `systemctl enable`d (wants `multi-user.target`
  so the correct rate is applied once at boot).
* The user unit is enabled with `systemctl --user --global enable`, which
  creates `/etc/systemd/user/graphical-session.target.wants/…` and therefore
  covers **every** user of the machine without touching their home directory.
  If the global mode is unavailable, `install.sh` falls back to enabling it for
  the user that owns the current graphical session.
* `udevadm control --reload-rules` and `systemctl daemon-reload` are run for you.

## Packaging notes

Nothing is distribution specific:

* scripts and docs go to `/usr/local`, so they never collide with distro
  packages;
* units live in `/etc/systemd/system` (admin space) rather than `/usr/lib/systemd/system`;
* the user unit goes to `/usr/local/lib/systemd/user`, which is in systemd's
  default user unit search path on every release since v230;
* the udev rule has priority `85`, after the standard `80-*` hardware rules.

To build a package, install with `--dest` and ship those paths:

```bash
makepkg / dpkg-buildpackage / rpmbuild:
    ./install.sh --dest="$pkgdir" --no-apply --skip-user-unit
```

and enable `refresh-rate-sync.service` (plus
`systemctl --user --global enable refresh-rate-sync-user.service`) in the
package's install scriptlet.

## Verification after install

```bash
systemctl status refresh-rate-sync.service      # enabled, inactive (dead)
systemctl cat systemd-suspend.service | tail    # the resume drop-in is there
udevadm verify /etc/udev/rules.d/85-refresh-rate-sync.rules
sudo /usr/local/lib/refresh-rate-sync/apply.sh --status
journalctl -b -t refresh-rate-sync | tail -20
```
