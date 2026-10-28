#!/usr/bin/env bash
#
# apply.sh -- runs as ROOT. It is started by udev at the exact instant the
#             power supply changes (plug / unplug) and by systemd at boot and
#             after resume; it is not a daemon and it stays stopped otherwise.
#
#             Finds every local graphical session and runs set-mode.sh inside
#             it, with the right environment (Wayland / X11 / D-Bus).
#
#   apply.sh [auto|ac|bat] [--force] [--status] [extra flags for set-mode.sh]
#
set -uo pipefail

LIBEXEC=${LIBEXEC:-/usr/local/lib/battery-refresh-rate-sync}
SET_MODE="$LIBEXEC/set-mode.sh"
PATH_FIXED=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

CONF_SYSTEM=/etc/battery-refresh-rate-sync.conf
USERS_WANTED=""      # empty = every local graphical session
MIN_WAIT=1           # seconds to let the kernel/hardware settle before acting

# shellcheck disable=SC1090
[ -r "$CONF_SYSTEM" ] && . "$CONF_SYSTEM"

have() { command -v "$1" >/dev/null 2>&1; }
log()  { logger -t battery-refresh-rate-sync -- "$*" 2>/dev/null || printf '%s\n' "$*" >&2; }
die()  { log "apply: $*"; exit 1; }

STATE_ARG=auto FORCE=0 STATUS=0; EXTRA=()
for a in "$@"; do
    case "$a" in
        ac|bat|auto)  STATE_ARG=$a ;;
        --force)      FORCE=1 ;;
        --status)     STATUS=1 ;;
        *)            EXTRA+=("$a") ;;
    esac
done

# --------------------------------------------------------------------------
# Power state (computed here as well, so we can decide and log it)
# --------------------------------------------------------------------------
power_state() {
    local found=0 online=0 d ty
    for d in /sys/class/power_supply/*/; do
        [ -r "${d}type" ] || continue
        ty=$(cat "${d}type" 2>/dev/null) || continue
        [ "$ty" = "Mains" ] || continue
        found=1
        if [ "$(cat "${d}online" 2>/dev/null)" = "1" ]; then online=1; break; fi
    done
    if   [ "$found" = 0 ];  then echo "${NO_BATTERY_STATE:-ac}"
    elif [ "$online" = 1 ]; then echo ac
    else                         echo bat
    fi
}

STATE=$STATE_ARG
[ "$STATE" = auto ] && STATE=$(power_state)

# --------------------------------------------------------------------------
# Local graphical sessions -> UID<TAB>USER<TAB>SESSION<TAB>TYPE
# --------------------------------------------------------------------------
graphical_sessions() {
    local sid uid user seat leader class rest t r c
    loginctl list-sessions --no-legend 2>/dev/null | while read -r sid uid user seat leader class rest; do
        [ -n "$sid" ] || continue
        [ "$class" = user ] || continue            # skip manager / remote sessions
        [ "$seat" != "-" ]  || continue            # no seat  = not a local session
        if [ -n "$USERS_WANTED" ]; then
            case " $USERS_WANTED " in *" $user "*) ;; *) continue ;; esac
        fi
        t=$(loginctl show-session --no-pager -p Type   "$sid" 2>/dev/null | sed -n 's/^Type=//p')
        r=$(loginctl show-session --no-pager -p Remote "$sid" 2>/dev/null | sed -n 's/^Remote=//p')
        c=$(loginctl show-session --no-pager -p Class  "$sid" 2>/dev/null | sed -n 's/^Class=//p')
        [ "$c" = user ] || continue
        [ "$r" = no ]   || continue
        case "$t" in wayland|x11) ;; *) continue ;; esac
        printf '%s\t%s\t%s\t%s\n' "$uid" "$user" "$sid" "$t"
    done
}

# --------------------------------------------------------------------------
# Session environment, harvested from the user's own processes -> KEY=VALUE
#
# loginctl gives us the session, but not the compositor socket names, so we
# read /proc/<pid>/environ (we are root, so we can) looking at the compositor
# first and falling back to discovering the sockets in $XDG_RUNTIME_DIR.
# --------------------------------------------------------------------------
session_env() {
    local uid=$1 p key val home
    local runtime=/run/user/$uid
    declare -A E=()
    local keys=(WAYLAND_DISPLAY DISPLAY DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP
                XDG_SESSION_TYPE XAUTHORITY HYPRLAND_INSTANCE_SIGNATURE SWAYSOCK
                LANG LC_ALL LC_MESSAGES)

    # 1) compositor / desktop shell first, then the rest of the user's processes
    local prio other
    prio=$(pgrep -U "$uid" -x 'kwin_wayland|kwin_x11|kwin|Hyprland|sway|wayfire|weston|cage|labwc|river|gnome-shell|Xwayland|plasmashell|kded6|kded5|xfce4-session|enlightenment|rootston|wayland-session|startplasma-w' 2>/dev/null | head -20)
    other=$(pgrep -U "$uid" 2>/dev/null | grep -vxF -e "$prio" 2>/dev/null | head -150)

    for p in $prio $other; do
        [ -r "/proc/$p/environ" ] || continue
        while IFS= read -r -d '' kv; do
            key=${kv%%=*}; val=${kv#*=}
            [ -n "$val" ] || continue
            case " ${keys[*]} " in *" $key "*) ;; *) continue ;; esac
            E[$key]=${E[$key]:-$val}               # first value wins
        done < "/proc/$p/environ"
        # Wayland socket + D-Bus is all we really need: stop digging
        [ -n "${E[WAYLAND_DISPLAY]:-}" ] && [ -n "${E[DBUS_SESSION_BUS_ADDRESS]:-}" ] && break
    done

    # 2) discover the sockets inside the runtime directory
    if [ -z "${E[WAYLAND_DISPLAY]:-}" ]; then
        for p in "$runtime"/wayland-*; do
            [ -S "$p" ] || continue
            E[WAYLAND_DISPLAY]=${p##*/}; break
        done
    fi
    if [ -z "${E[DISPLAY]:-}" ]; then
        for p in "$runtime"/.X11-unix/X* /tmp/.X11-unix/X*; do
            [ -S "$p" ] || continue
            E[DISPLAY]=:${p##*/X}; break
        done
    fi

    # 3) baseline values
    E[XDG_RUNTIME_DIR]=$runtime
    E[DBUS_SESSION_BUS_ADDRESS]=${E[DBUS_SESSION_BUS_ADDRESS]:-unix:path=$runtime/bus}
    if [ -z "${E[XDG_SESSION_TYPE]:-}" ]; then
        if   [ -n "${E[WAYLAND_DISPLAY]:-}" ]; then E[XDG_SESSION_TYPE]=wayland
        else                                        E[XDG_SESSION_TYPE]=x11
        fi
    fi
    home=$(getent passwd "$uid" 2>/dev/null | cut -d: -f6)
    [ -n "$home" ] && E[HOME]=$home
    E[USER]=$(id -un "$uid" 2>/dev/null)
    E[LOGNAME]=${E[USER]}
    E[PATH]=$PATH_FIXED
    E[LANG]=${E[LANG]:-${E[LC_MESSAGES]:-C.UTF-8}}   # keeps the notification language right

    for key in "${!E[@]}"; do
        [ -n "${E[$key]}" ] && printf '%s=%s\n' "$key" "${E[$key]}"
    done
}

# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------
[ -x "$SET_MODE" ] || die "executable $SET_MODE not found"

if [ "$STATUS" = 1 ]; then
    echo "power state          : $STATE  (raw online flags: $(cat /sys/class/power_supply/*/online 2>/dev/null | tr '\n' ' '))"
    echo "local graphical sessions:"
    lst=$(graphical_sessions)
    if [ -z "$lst" ]; then
        echo "  (none)"
    else
        while IFS=$'\t' read -r u un s tp; do
            echo "  uid=$u user=$un session=$s type=$tp"
            session_env "$u" | sed 's/^/      /'
        done <<<"$lst"
    fi
    exit 0
fi

# desktop without a battery and NO_BATTERY_STATE=ignore -> stay out of the way
[ "$STATE" = ignore ] && exit 0

# The kernel/UEFI can emit the uevent slightly before the hardware is ready.
if [ "$MIN_WAIT" != 0 ]; then sleep "$MIN_WAIT"; fi

found=0
while IFS=$'\t' read -r uid user sid stype; do
    [ -n "$uid" ] || continue
    found=1
    envkv=$(session_env "$uid")
    if ! printf '%s\n' "$envkv" | grep -qE '^(WAYLAND_DISPLAY|DISPLAY)='; then
        log "apply: $user (session $sid): no WAYLAND_DISPLAY and no DISPLAY, skipping"
        continue
    fi

    envargs=()
    while IFS= read -r kv; do [ -n "$kv" ] && envargs+=("$kv"); done <<<"$envkv"

    # drop into the session user; keep `env` as the last word of drop=(...)
    if   [ "$(id -u)" != 0 ]; then  drop=(env)                        # plain user: manual test
    elif have runuser; then  drop=(runuser -u "$user" -- env)
    elif have setpriv; then  drop=(setpriv --reuid "$uid" --regid "$(id -rg "$user")" --init-groups --inh-caps=-all --clear-groups -- env)
    elif have sudo;    then  drop=(sudo -n -u "$user" -- env)
    else die "none of runuser, setpriv or sudo is available"; fi

    args=("$STATE")
    [ "$FORCE" = 1 ] && args+=(--force)
    [ ${#EXTRA[@]} -gt 0 ] && args+=("${EXTRA[@]}")

    log "apply: state=$STATE user=$user session=$sid($stype) $(printf '%s\n' "$envkv" | grep -E '^(WAYLAND_DISPLAY|DISPLAY|XDG_SESSION_TYPE)=' | tr '\n' ' ')"
    "${drop[@]}" -i "${envargs[@]}" bash "$SET_MODE" "${args[@]}" 2>&1 |
        while IFS= read -r l; do log "  $l"; done
done < <(graphical_sessions)

[ "$found" = 1 ] || log "apply: no active local graphical session (state=$STATE)"
exit 0
