#!/usr/bin/env bash
#
# refresh-rate-sync remover.
#
#   sudo ./uninstall.sh            # removes units, scripts, udev rule, icons
#   sudo ./uninstall.sh --keep-config
#   sudo ./uninstall.sh --dest=/mnt            # alternate root tree
#
set -euo pipefail

GITHUB_REPO_DEFAULT="${GITHUB_REPO:-Je5us7/refresh-rate-sync}"
GITHUB_REF_DEFAULT="${GITHUB_REF:-main}"

ROOT=${DESTDIR:-}
KEEP_CONFIG=0
NORM=()
for a in "$@"; do
    case "$a" in
        --dest=*)       ROOT=${a#--dest=}; NORM+=("$a") ;;
        --keep-config)  KEEP_CONFIG=1; NORM+=("$a") ;;
        --repo=*)       NORM+=("$a") ;;
        --ref=*)        NORM+=("$a") ;;
        --help|-h)      echo "usage: uninstall.sh [--dest=PATH] [--keep-config]"; exit 0 ;;
        *) printf 'refresh-rate-sync: unknown option: %s\n' "$a" >&2; exit 2 ;;
    esac
done

have() { command -v "$1" >/dev/null 2>&1; }
say()  { printf '%s\n' "$*"; }

# re-run as root when installing to the live system
if [ "$(id -u)" != 0 ] && [ "${RRS_ROOTED:-}" != 1 ] && [ -z "$ROOT" ]; then
    if have sudo; then
        say "refresh-rate-sync: re-running as root with sudo"
        exec sudo env RRS_ROOTED=1 bash "$(readlink -f -- "$0")" ${NORM[@]+"${NORM[@]}"}
    elif have pkexec; then
        say "refresh-rate-sync: asking for root through polkit (dialog on screen)"
        exec pkexec env RRS_ROOTED=1 DISPLAY="${DISPLAY:-}" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
            XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" bash "$(readlink -f -- "$0")" ${NORM[@]+"${NORM[@]}"}
    else
        say "refresh-rate-sync: please run as root"
        exit 1
    fi
fi

LIBEXEC=${LIBEXEC:-$ROOT/usr/local/lib/refresh-rate-sync}
SYSD=$ROOT/etc/systemd/system
USERUNITD=$ROOT/usr/local/lib/systemd/user

say "== refresh-rate-sync: removing"

if [ -z "$ROOT" ]; then
    # disable the per-session unit: globally (the symlink in /etc/systemd/user)
    systemctl --user --global disable refresh-rate-sync-user.service 2>/dev/null || true
    # ... and for the user that ran sudo/pkexec, in case it was enabled per-user
    TARGET_USER=${SUDO_USER:-}
    if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = root ]; then
        TARGET_USER=$(loginctl list-sessions --no-legend 2>/dev/null | awk '$6=="user" && $4!="-" {print $3; exit}')
    fi
    uid=$(id -u "$TARGET_USER" 2>/dev/null || echo 0)
    if [ "$uid" != 0 ] && [ -d "/run/user/$uid" ]; then
        runuser -u "$TARGET_USER" -- env XDG_RUNTIME_DIR=/run/user/$uid \
            DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus \
            systemctl --user disable refresh-rate-sync-user.service 2>/dev/null || true
    fi
    systemctl disable --now refresh-rate-sync.service 2>/dev/null || true
    rm -f /etc/systemd/user/graphical-session.target.wants/refresh-rate-sync-user.service
fi

rm -f  "$LIBEXEC/apply.sh" "$LIBEXEC/set-mode.sh" \
       "$LIBEXEC/icons/refresh-rate-ac.svg" "$LIBEXEC/icons/refresh-rate-battery.svg"
rmdir  "$LIBEXEC/icons" "$LIBEXEC" 2>/dev/null || true

rm -f  "$SYSD/refresh-rate-sync.service"
rm -f  "$USERUNITD/refresh-rate-sync-user.service"
rmdir  "$USERUNITD" 2>/dev/null || true
for u in systemd-suspend systemd-hibernate systemd-hybrid-sleep systemd-suspend-then-hibernate; do
    rm -f "$SYSD/$u.service.d/10-refresh-rate-sync.conf"
    rmdir "$SYSD/$u.service.d" 2>/dev/null || true
done

rm -f  "$ROOT/etc/udev/rules.d/85-refresh-rate-sync.rules"
rm -f  "$ROOT/usr/share/icons/hicolor/scalable/apps/refresh-rate-ac.svg" \
       "$ROOT/usr/share/icons/hicolor/scalable/apps/refresh-rate-battery.svg"
rm -rf "$ROOT/usr/local/share/doc/refresh-rate-sync"

if [ -z "$ROOT" ]; then
    if have gtk-update-icon-cache; then
        gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor 2>/dev/null || true
    fi
    systemctl daemon-reload
    udevadm control --reload-rules
    if [ "$KEEP_CONFIG" = 1 ]; then
        say "   /etc/refresh-rate-sync.conf kept on purpose"
    else
        rm -f /etc/refresh-rate-sync.conf /etc/refresh-rate-sync.conf.dpkg-new
    fi
fi
say "   Done. The screen mode itself was left as it was."
