#!/usr/bin/env bash
#
# refresh-rate-sync installer -- generic Linux with systemd + udev
# (Arch/CachyOS, Debian/Ubuntu, Fedora, openSUSE, Void, ...).
#
# It can be run from a clone of the repository, or standalone: it downloads
# whatever it needs from GitHub when the files are not next to the script.
#
#   sudo ./install.sh
#   curl -fsSL https://raw.githubusercontent.com/Je5us7/refresh-rate-sync/main/install.sh \
#       | sudo bash -s -- --repo=Je5us7/refresh-rate-sync
#   sudo ./install.sh --uninstall
#
# All comments in this project are in English; the desktop notifications are
# bilingual (Spanish/English) and follow NOTIFY_LANG / $LANG.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Change this to your GitHub repository (Je5us7/NAME) if you want the one-liner
# installer to work without passing --repo= every time.
# ---------------------------------------------------------------------------
GITHUB_REPO_DEFAULT="${GITHUB_REPO:-Je5us7/refresh-rate-sync}"
GITHUB_REF_DEFAULT="${GITHUB_REF:-main}"

# every file the project needs, relative to the repository root
FILES=(
    README.md
    LICENSE
    etc/refresh-rate-sync.conf
    lib/apply.sh
    lib/set-mode.sh
    udev/85-refresh-rate-sync.rules
    systemd/refresh-rate-sync.service
    systemd/user/refresh-rate-sync-user.service
    systemd/suspend.d/systemd-suspend.conf
    systemd/suspend.d/systemd-hibernate.conf
    systemd/suspend.d/systemd-hybrid-sleep.conf
    systemd/suspend.d/systemd-suspend-then-hibernate.conf
    icons/refresh-rate-ac.svg
    icons/refresh-rate-battery.svg
    docs/index.md
    docs/architecture.md
    docs/configuration.md
    docs/compatibility.md
    docs/installing.md
    docs/troubleshooting.md
    docs/development.md
)
# files that must be executable once installed
EXEC_FILES=(lib/apply.sh lib/set-mode.sh)

usage() {
    cat <<'EOF'
refresh-rate-sync installer

  --repo=Je5us7/NAME    GitHub repository used to download the files when they
                       are not next to this script
  --ref=BRANCH|TAG     git ref to download (default: main)
  --dest=PATH          install into an alternate root tree (same as DESTDIR)
  --libexec=PATH       where the shell scripts go
                       (default: <dest>/usr/local/lib/refresh-rate-sync)
  --force-config       overwrite an existing /etc/refresh-rate-sync.conf
  --no-apply           do not apply the current power state right after install
  --skip-user-unit     do not enable the per-session systemd user unit
  --uninstall          remove everything (same as uninstall.sh)
  --help               this help
EOF
}

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
REPO=$GITHUB_REPO_DEFAULT
REF=$GITHUB_REF_DEFAULT
ROOT=${DESTDIR:-}
LIBEXEC=${LIBEXEC:-}
FORCE_CONFIG=0
DO_APPLY=1
SKIP_USER_UNIT=0
UNINSTALL=0
NORM=()
for a in "$@"; do
    case "$a" in
        --repo=*)          REPO=${a#--repo=}; NORM+=("$a") ;;
        --ref=*)           REF=${a#--ref=};   NORM+=("$a") ;;
        --dest=*)          ROOT=${a#--dest=}; NORM+=("$a") ;;
        --libexec=*)       LIBEXEC=${a#--libexec=}; NORM+=("$a") ;;
        --force-config)    FORCE_CONFIG=1; NORM+=("$a") ;;
        --no-apply)        DO_APPLY=0 ;;
        --skip-user-unit)  SKIP_USER_UNIT=1 ;;
        --uninstall|-u)    UNINSTALL=1; NORM+=("$a") ;;
        --help|-h)         usage; exit 0 ;;
        *) echo "refresh-rate-sync: unknown option: $a" >&2; usage; exit 2 ;;
    esac
done

have() { command -v "$1" >/dev/null 2>&1; }
say()  { printf '%s\n' "$*"; }
die()  { printf 'refresh-rate-sync: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Re-run as root (sudo if available, otherwise a polkit dialog through pkexec)
# ---------------------------------------------------------------------------
if [ "$(id -u)" != 0 ] && [ "${RRS_ROOTED:-}" != 1 ] && [ -z "$ROOT" ]; then
    if have sudo; then
        say "refresh-rate-sync: re-running as root with sudo"
        exec sudo env RRS_ROOTED=1 bash "$(readlink -f -- "$0")" ${NORM[@]+"${NORM[@]}"}
    elif have pkexec; then
        say "refresh-rate-sync: asking for root through polkit (dialog on screen)"
        exec pkexec env RRS_ROOTED=1 DISPLAY="${DISPLAY:-}" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
            XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" bash "$(readlink -f -- "$0")" ${NORM[@]+"${NORM[@]}"}
    else
        die "please run as root (no sudo and no pkexec found)"
    fi
fi
[ "$(id -u)" = 0 ] || [ -n "$ROOT" ] || die "must be run as root"

# ---------------------------------------------------------------------------
# Where are the project files?  Use the tree next to this script, otherwise
# download the tree from GitHub (curl|bash style installation).
# ---------------------------------------------------------------------------
SRC=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]:-$0}")")" && pwd)
CLEANUP=""
if [ ! -f "$SRC/lib/set-mode.sh" ]; then
    have curl || have wget || die "need curl or wget to fetch the project files"
    SRC=$(mktemp -d /tmp/refresh-rate-sync.XXXXXX)
    CLEANUP=$SRC
    trap '[ -n "$CLEANUP" ] && rm -rf "$CLEANUP"' EXIT
    RAW_BASE="https://raw.githubusercontent.com/$REPO/$REF"
    say "refresh-rate-sync: files not found next to the script, downloading"
    say "                   $RAW_BASE"
    fetch() {   # fetch <url> <dest>
        if have curl; then curl -fsSL --retry 3 -o "$2" "$1"
        else wget -q -O "$2" "$1"; fi
    }
    for f in uninstall.sh "${FILES[@]}"; do
        install -d -m0755 "$(dirname "$SRC/$f")"
        fetch "$RAW_BASE/$f" "$SRC/$f" || die "could not download $f from $REPO ($REF)"
    done
    chmod +x "$SRC/install.sh" 2>/dev/null || true
fi
[ -f "$SRC/lib/set-mode.sh" ] || die "incomplete source tree in $SRC"

# ---------------------------------------------------------------------------
# Uninstall path
# ---------------------------------------------------------------------------
if [ "$UNINSTALL" = 1 ]; then
    [ -f "$SRC/uninstall.sh" ] || die "uninstall.sh not found in $SRC"
    exec bash "$SRC/uninstall.sh" ${ROOT:+--dest="$ROOT"}
fi

# ---------------------------------------------------------------------------
# Install destinations (systemd/udev paths are the same on every distro)
# ---------------------------------------------------------------------------
: "${LIBEXEC:=$ROOT/usr/local/lib/refresh-rate-sync}"
SYSD=$ROOT/etc/systemd/system
USERUNITD=$ROOT/usr/local/lib/systemd/user
UDEVD=$ROOT/etc/udev/rules.d
CONFD=$ROOT/etc
DOCD=$ROOT/usr/local/share/doc/refresh-rate-sync
ICOND=$ROOT/usr/share/icons/hicolor
# apply.sh must know the very same LIBEXEC we pick here
APPLY_SH="$LIBEXEC/apply.sh"

say "== refresh-rate-sync: installing from $SRC"
say "   scripts  -> $LIBEXEC"
say "   config   -> $CONFD/refresh-rate-sync.conf"

# --- 1. scripts -------------------------------------------------------------
install -d -m0755 "$LIBEXEC"
install -m0755 "$SRC/lib/apply.sh"    "$LIBEXEC/apply.sh"
install -m0755 "$SRC/lib/set-mode.sh" "$LIBEXEC/set-mode.sh"
# keep a copy of the icons next to the scripts: set-mode.sh looks there too
install -d -m0755 "$LIBEXEC/icons"
install -m0644 "$SRC/icons/refresh-rate-ac.svg"      "$LIBEXEC/icons/refresh-rate-ac.svg"
install -m0644 "$SRC/icons/refresh-rate-battery.svg" "$LIBEXEC/icons/refresh-rate-battery.svg"

# --- 2. configuration (never clobber an edited file) ------------------------
if [ -f "$CONFD/refresh-rate-sync.conf" ] && [ "$FORCE_CONFIG" != 1 ]; then
    install -m0644 "$SRC/etc/refresh-rate-sync.conf" "$CONFD/refresh-rate-sync.conf.dpkg-new"
    say "   existing configuration kept; new default saved as .dpkg-new"
else
    install -m0644 "$SRC/etc/refresh-rate-sync.conf" "$CONFD/refresh-rate-sync.conf"
fi
# the root side needs to know a custom LIBEXEC (if --libexec was used)
if [ "$LIBEXEC" != /usr/local/lib/refresh-rate-sync ]; then
    if ! grep -q '^LIBEXEC=' "$CONFD/refresh-rate-sync.conf" 2>/dev/null; then
        printf '\n# used by apply.sh to find set-mode.sh\nLIBEXEC=%s\n' "$LIBEXEC" \
            >> "$CONFD/refresh-rate-sync.conf"
    fi
fi

# --- 3. systemd -------------------------------------------------------------
install -d -m0755 "$SYSD" \
    "$SYSD/systemd-suspend.service.d" \
    "$SYSD/systemd-hibernate.service.d" \
    "$SYSD/systemd-hybrid-sleep.service.d" \
    "$SYSD/systemd-suspend-then-hibernate.service.d" \
    "$USERUNITD" "$DOCD" "$DOCD/docs"
install -m0644 "$SRC/systemd/refresh-rate-sync.service"            "$SYSD/refresh-rate-sync.service"
install -m0644 "$SRC/systemd/user/refresh-rate-sync-user.service"  "$USERUNITD/refresh-rate-sync-user.service"
for u in systemd-suspend systemd-hibernate systemd-hybrid-sleep systemd-suspend-then-hibernate; do
    install -m0644 "$SRC/systemd/suspend.d/$u.conf" \
        "$SYSD/$u.service.d/10-refresh-rate-sync.conf"
done
install -m0644 "$SRC/README.md"  "$DOCD/README.md"
install -m0644 "$SRC/LICENSE"    "$DOCD/LICENSE" 2>/dev/null || true
for d in index architecture configuration compatibility installing troubleshooting development; do
    install -m0644 "$SRC/docs/$d.md" "$DOCD/docs/$d.md" 2>/dev/null || true
done

# --- 4. udev ----------------------------------------------------------------
install -d -m0755 "$UDEVD"
install -m0644 "$SRC/udev/85-refresh-rate-sync.rules" "$UDEVD/85-refresh-rate-sync.rules"

# --- 5. notification icons --------------------------------------------------
install -d -m0755 "$ICOND/scalable/apps"
install -m0644 "$SRC/icons/refresh-rate-ac.svg"      "$ICOND/scalable/apps/refresh-rate-ac.svg"
install -m0644 "$SRC/icons/refresh-rate-battery.svg" "$ICOND/scalable/apps/refresh-rate-battery.svg"
if [ -z "$ROOT" ] && have gtk-update-icon-cache; then
    gtk-update-icon-cache -q -t -f "$ICOND" 2>/dev/null || true
fi

if [ -n "$ROOT" ]; then
    say "   (installing into \$DESTDIR=$ROOT : units are not enabled here)"
    exit 0
fi

# --- 6. enable everything ---------------------------------------------------
systemctl daemon-reload
systemctl enable refresh-rate-sync.service >/dev/null 2>&1 || true
udevadm control --reload-rules

# The per-session unit is enabled "globally": the symlink lands in
# /etc/systemd/user/graphical-session.target.wants and applies to every user.
TARGET_USER=${SUDO_USER:-}
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = root ]; then
    # under pkexec there is no SUDO_USER: take the owner of the local session
    TARGET_USER=$(loginctl list-sessions --no-legend 2>/dev/null | awk '$6=="user" && $4!="-" {print $3; exit}')
fi
if [ "$SKIP_USER_UNIT" != 1 ]; then
    if systemctl --user --global enable refresh-rate-sync-user.service 2>/dev/null; then
        say "   user unit enabled (globally, for every graphical session)"
    else
        uid=$(id -u "$TARGET_USER" 2>/dev/null || true)
        if [ -n "${uid:-}" ] && [ "$uid" != 0 ] && [ -d "/run/user/$uid" ]; then
            runuser -u "$TARGET_USER" -- env \
                XDG_RUNTIME_DIR=/run/user/$uid \
                DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus \
                systemctl --user enable refresh-rate-sync-user.service 2>/dev/null || \
                say "   WARNING: enable it yourself: systemctl --user enable --now refresh-rate-sync-user.service"
        else
            say "   WARNING: enable it yourself: systemctl --user enable --now refresh-rate-sync-user.service"
        fi
    fi
fi

# --- 7. apply the current state --------------------------------------------
if [ "$DO_APPLY" = 1 ]; then
    systemctl restart refresh-rate-sync.service || true
    sleep 2
    say ""
    say "== last run =="
    systemctl --no-pager --lines=6 status refresh-rate-sync.service 2>/dev/null | sed 's/^/   /' || true
fi

say ""
say "Done."
say "  config : $CONFD/refresh-rate-sync.conf   (applies on the next event, no restart needed)"
say "  test   : sudo $APPLY_SH --status"
say "           sudo $APPLY_SH bat --dry-run"
say "  logs   : journalctl -t refresh-rate-sync -f"
say "  docs   : $DOCD/README.md  and  $DOCD/docs/"
