#!/usr/bin/env bash
#
# set-mode.sh -- change the refresh rate of the connected video outputs
#                according to the power state (AC adapter / battery).
#
# Always runs as the user who owns the graphical session (apply.sh is the one
# that drops privileges and injects the session environment).
#
#   set-mode.sh [ac|bat|auto] [--force] [--quiet] [--dry-run] [--backend=B]
#
# Supported backends (auto-detected, in this order):
#   kde       -> kscreen-doctor   (KDE Plasma, on Wayland and on X11)
#   hyprland  -> hyprctl          (needs jq)
#   sway      -> swaymsg          (needs jq; also i3-wayland / Cosmic)
#   wlr       -> wlr-randr        (generic wlroots compositors)
#   x11       -> xrandr           (X11 sessions)
#
# stdout: one line per output that actually changed ->  "NAME OLD_HZ NEW_HZ"
# stderr: trace messages (they end up in the journal when apply.sh calls us)
#
set -uo pipefail
umask 077

SELF_DIR=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]:-$0}")")" && pwd)

# ---------------------------------------------------------------------------
# Configuration ( /etc/refresh-rate-sync.conf and ~/.config/refresh-rate-sync.conf )
# ---------------------------------------------------------------------------
BATTERY_HZ=60        # on battery: number of Hz, "max" or "min"
AC_HZ=max            # on AC power: number of Hz, or "max"
RRS_BACKEND=auto     # kde|hyprland|sway|wlr|x11|auto
ONLY_INTERNAL=0      # 1 = only the built-in panel (eDP/LVDS/DSI/DSL)
TARGET_OUTPUTS=""    # if not empty, handle only these outputs
SKIP_OUTPUTS=""      # outputs to ignore
RATE_TOLERANCE=1.0   # Hz tolerance for "already at the target"
RETRIES=2            # retries when the mode did not stick
RETRY_DELAY=2        # seconds between retries
SETTLE_DELAY=1       # seconds to wait before verifying
NOTIFY=1             # show a desktop notification on change
NOTIFY_ICON=1        # use the installed "little monitor" icon
NOTIFY_SNAPSHOT=0    # 1 = attach a screenshot thumbnail to the notification
NOTIFY_TIMEOUT=5000  # notification lifetime (ms)
NOTIFY_FAIL=1        # also notify when the change failed
NOTIFY_LANG=auto     # notification language: auto|es|en
NO_BATTERY_STATE=ac  # desktops without a battery: ac|bat|ignore
BACKEND_RETRIES=3     # backend detection retries (session still starting up)
BACKEND_RETRY_DELAY=2 # seconds between those retries

for f in /etc/refresh-rate-sync.conf \
         "${XDG_CONFIG_HOME:-$HOME/.config}/refresh-rate-sync.conf"; do
    # shellcheck disable=SC1090
    [ -r "$f" ] && . "$f"
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }
log()  { printf '%s\n' "$*" >&2; }
die()  { log "set-mode: $*"; exit 1; }

uncolor() { LC_ALL=C sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g'; }

# 165.00 -> 165   |   59.94 -> 59.94
fmt_hz() { LC_ALL=C awk -v v="$1" 'BEGIN{ r=v+0; if (r==int(r)) printf "%d",r; else printf "%.2f",r }'; }

# fcmp a op b  (op: lt le gt ge eq ne) -- floating point without bc
fcmp() { LC_ALL=C awk -v a="$1" -v b="$2" -v op="$3" 'BEGIN{
    exit !((op=="lt")?(a+0<b+0):(op=="le")?(a+0<=b+0):(op=="gt")?(a+0>b+0):
           (op=="ge")?(a+0>=b+0):(op=="eq")?(a+0==b+0):(a+0!=b+0)) }'; }

# Notification strings are bilingual; pick the language now, then t <es> <en>.
case "${NOTIFY_LANG:-auto}" in
    es|es_ES|es_ES.UTF-8) T_ES=1 ;;
    en*)                  T_ES=0 ;;
    *) case "${LANG:-}${LC_MESSAGES:-}" in
           es*) T_ES=1 ;;
           *)   T_ES=0 ;;
       esac ;;
esac
t() { if [ "$T_ES" = 1 ]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }

# ---------------------------------------------------------------------------
# Power state
# ---------------------------------------------------------------------------
power_state() {
    local found=0 online=0 d ty
    for d in /sys/class/power_supply/*/; do
        [ -r "${d}type" ] || continue
        ty=$(cat "${d}type" 2>/dev/null) || continue
        [ "$ty" = "Mains" ] || continue          # only the AC/mains power supply
        found=1
        if [ "$(cat "${d}online" 2>/dev/null)" = "1" ]; then online=1; break; fi
    done
    if   [ "$found" = 0 ];  then echo "$NO_BATTERY_STATE"   # no battery at all
    elif [ "$online" = 1 ]; then echo ac
    else                         echo bat
    fi
}

# ---------------------------------------------------------------------------
# Backend detection
# ---------------------------------------------------------------------------
RTDIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}

backend_candidates() {
    case "$RRS_BACKEND" in
        kde|hyprland|sway|wlr|x11) echo "$RRS_BACKEND"; return ;;
    esac
    # Plasma first: kscreen-doctor is the only way in on KDE's Wayland session
    if have kscreen-doctor && [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]; then echo kde; fi
    # Hyprland
    if have hyprctl && have jq && { [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || \
       ls -d "$RTDIR"/hyprland/*/ >/dev/null 2>&1; }; then echo hyprland; fi
    # Sway / i3-wayland / Cosmic
    if have swaymsg && have jq && { [ -n "${SWAYSOCK:-}" ] || \
       ls "$RTDIR"/sway-ipc.* >/dev/null 2>&1; }; then echo sway; fi
    # generic wlroots
    if have wlr-randr && [ -n "${WAYLAND_DISPLAY:-}" ]; then echo wlr; fi
    # X11
    if have xrandr && [ -n "${DISPLAY:-}" ]; then echo x11; fi
    # last blind attempts (no session env in the environment)
    if have kscreen-doctor; then echo kde; fi
    if have xrandr; then echo x11; fi
}

# Normalized mode list, one mode per line:
#   NAME WIDTH HEIGHT Hz MODE_ID IS_CURRENT(0|1)
list_kde() {
    kscreen-doctor -o 2>/dev/null | uncolor | awk '
        /^Output:[ \t]+/   { name=$3; en=0; cn=0; next }
        /^[ \t]*enabled/   { en=1; next }
        /^[ \t]*connected/ { cn=1; next }
        /Modes:[ \t]/ {
            if (!en || !cn || name=="") next
            sub(/.*Modes:[ \t]*/, "")
            n = split($0, tok, /[ \t]+/)
            for (i = 1; i <= n; i++) {
                s = tok[i]; if (s == "") continue
                isc = (s ~ /\*/) ? 1 : 0            # '*' marks the current mode
                sub(/[*!].*$/, "", s)               # '*' current, '!' preferred
                if (split(s, p, ":") != 2) continue
                if (split(p[2], wr, "@") != 2) continue
                if (split(wr[1], hw, "x") != 2) continue
                print name, hw[1], hw[2], wr[2], p[1], isc
            }
        }'
}

list_x11() {
    xrandr -q 2>/dev/null | awk '
        /^[^ \t]/ { name=$1; conn=($0 ~ / connected/); next }
        {
            if (!conn || name=="" || $1 !~ /^[0-9]+x[0-9]+$/) next
            split($1, hw, "x")
            for (i = 2; i <= NF; i++) {
                r = $i
                if (r !~ /^[0-9]/) continue
                isc = (r ~ /\*/) ? 1 : 0
                gsub(/[^0-9.]/, "", r)              # strip '*', '+', 'b', 'r'
                if (r == "") continue
                print name, hw[1], hw[2], r, hw[1] "x" hw[2] "@" r, isc
            }
        }'
}

list_wlr() {
    wlr-randr 2>/dev/null | awk '
        /^[^ \t]/ { name=$1; en=0; next }
        /^[ \t]+enable([ \t]|$)/ { en=1; next }
        /^[ \t]+mode[ \t]/ {
            if (!en || name=="" || $2 !~ /^[0-9]+x[0-9]+$/) next
            split($2, hw, "x")
            r = $3; gsub(/[^0-9.]/, "", r)          # "164.98Hz" -> "164.98"
            if (r == "") next
            isc = ($0 ~ /[ \t]current/) ? 1 : 0
            print name, hw[1], hw[2], r, hw[1] "x" hw[2] "@" r, isc
        }'
}

list_hypr() {
    # hyprctl needs HYPRLAND_INSTANCE_SIGNATURE: discover it when missing
    [ "${HYPRLAND_INSTANCE_SIGNATURE:-}" = "" ] && {
        local s
        for s in "$RTDIR"/hyprland/*/; do
            [ -d "$s" ] || continue
            s=${s%/}; s=${s##*/}
            [ -n "$s" ] && HYPRLAND_INSTANCE_SIGNATURE=$s
        done
        export HYPRLAND_INSTANCE_SIGNATURE
    }
    # "modes" (older releases) / "availableModes" (Hyprland >= 0.50)
    hyprctl monitors all -j 2>/dev/null | jq -r '
        .[] | select((.disabled // false) | not) | . as $o |
        (($o.modes // $o.availableModes // [])[]) as $m |
        [ $o.name, $m.width, $m.height, ($m.refreshRate|tostring),
          "\($m.width)x\($m.height)@\($m.refreshRate)",
          (if ($m.width == $o.width and $m.height == $o.height
               and (($m.refreshRate - $o.refreshRate)|fabs) < 1) then 1 else 0 end)
        ] | map(tostring) | join(" ")' 2>/dev/null
}

list_sway() {
    # swaymsg needs SWAYSOCK: discover it when missing
    [ "${SWAYSOCK:-}" = "" ] && {
        local s
        s=$(ls "$RTDIR"/sway-ipc.*/*.sock 2>/dev/null | head -1)
        [ -n "$s" ] && SWAYSOCK=$s && export SWAYSOCK
    }
    # "modes" (sway < 3) / "available_modes" (sway >= 3); MODE_ID is the index
    swaymsg -t get_outputs 2>/dev/null | jq -r '
        .[] | select(((.type // "output") == "output") and ((.disabled // false) | not)) | . as $o |
        ($o.current_mode // -1) as $cm |
        (($o.modes // $o.available_modes // []) | to_entries[]) as $e |
        ($e.value) as $m |
        [ $o.name, $m.width, $m.height, ($m.refresh|tostring),
          ($e.key|tostring),
          (if ($e.key == $cm) or ($m.width == $o.width and $m.height == $o.height
               and (($m.refresh - $o.refresh)|fabs) < 1) then 1 else 0 end) ]
        | map(tostring) | join(" ")' 2>/dev/null
}

list_modes() {
    case "$1" in
        kde)      list_kde  ;;
        x11)      list_x11  ;;
        wlr)      list_wlr  ;;
        hyprland) list_hypr ;;
        sway)     list_sway ;;
    esac
}

# ---------------------------------------------------------------------------
# Output filtering
# ---------------------------------------------------------------------------
keep_output() {
    local n=$1 pat
    for pat in $SKIP_OUTPUTS; do [ "$n" = "$pat" ] && return 1; done
    if [ -n "$TARGET_OUTPUTS" ]; then
        for pat in $TARGET_OUTPUTS; do [ "$n" = "$pat" ] && return 0; done
        return 1
    fi
    if [ "$ONLY_INTERNAL" = 1 ]; then
        case "$n" in
            eDP*|edp*|LVDS*|lvds*|DSI*|DSL*) return 0 ;;
            *) return 1 ;;
        esac
    fi
    return 0
}

# ---------------------------------------------------------------------------
# pick_modes <mode-list> <target>
#   target: max | min | a number of Hz
#   stdout: NAME CURRENT_HZ TARGET_HZ MODE_ID WIDTHxHEIGHT
# ---------------------------------------------------------------------------
pick_modes() {
    printf '%s\n' "$1" | LC_ALL=C awk -v want="$2" -v tol="$RATE_TOLERANCE" '
        # should "cand" replace the current best candidate "cur"?
        function better(cand, cur) {
            if (want == "max") return cand > cur
            if (want == "min") return cand < cur
            if (cand <= want + tol) { if (cur > want + tol) return 1; return cand > cur }
            if (cur > want + tol) return cand < cur   # none below target: take the lowest
            return 0
        }
        {
            if ($1 == "" || $2+0 <= 0 || $3+0 <= 0 || $4+0 <= 0) next
            N++; nm[N]=$1; rs[N]=$2 "x" $3; rt[N]=$4+0; rw[N]=$4; id[N]=$5; cu[N]=$6+0
        }
        END {
            # pass 1: current resolution and rate of every output
            for (i = 1; i <= N; i++) {
                if (!(nm[i] in seen)) { seen[nm[i]]=1; order[++nn]=nm[i] }
                if (cu[i] == 1) { cres[nm[i]]=rs[i]; crate[nm[i]]=rw[i] }
            }
            # pass 2: best mode with the SAME resolution (we never change resolution)
            for (i = 1; i <= N; i++) {
                if (!(nm[i] in cres) || rs[i] != cres[nm[i]]) continue
                k = nm[i] SUBSEP rs[i]
                if (!(k in have)) { have[k]=1; best[k]=rt[i]; bid[k]=id[i]; braw[k]=rw[i] }
                else if (better(rt[i], best[k])) { best[k]=rt[i]; bid[k]=id[i]; braw[k]=rw[i] }
            }
            for (i = 1; i <= nn; i++) {
                name = order[i]
                if (!(name in cres)) continue
                k = name SUBSEP cres[name]
                if (!(k in have) || bid[k] == "") continue
                d = best[k] - crate[name]; if (d < 0) d = -d
                if (d <= tol) continue                 # already where we want to be
                print name, crate[name], braw[k], bid[k], cres[name]
            }
        }'
}

# ---------------------------------------------------------------------------
# Applying one mode
# ---------------------------------------------------------------------------
apply_one() {
    local be=$1 name=$2 w=$3 h=$4 rate=$5 id=$6
    case "$be" in
        kde)      kscreen-doctor "output.${name}.mode.${id}" ;;
        x11)      xrandr --output "$name" --mode "${w}x${h}" --rate "$rate" ;;
        wlr)      wlr-randr --output "$name" --mode "${w}x${h}@${rate}" ;;
        sway)     swaymsg output "$name" mode "$id" ;;
        hyprland) hyprctl output mode "${w}x${h}@${rate}" "$name" ;;
        *)        return 1 ;;
    esac
}

# diff of two normalized mode lists -> "NAME OLD_HZ NEW_HZ"
diff_modes() {
    LC_ALL=C awk -v tol="$RATE_TOLERANCE" '
        function fmt(v){ r=v+0; return (r==int(r)) ? sprintf("%d",r) : sprintf("%.2f",r) }
        NR==FNR { if ($6==1) old[$1]=$4; next }
        { if ($6==1) { new[$1]=$4; if (!($1 in ord)) ord[++n]=$1 } }
        END {
            for (i = 1; i <= n; i++) {
                nm = ord[i]
                if (!(nm in old)) continue
                d = new[nm]+0 - old[nm]+0; if (d < 0) d = -d
                if (d <= tol) continue
                print nm, fmt(old[nm]), fmt(new[nm])
            }
        }' <(printf '%s\n' "$1") <(printf '%s\n' "$2")
}

# ---------------------------------------------------------------------------
# Notifications
# ---------------------------------------------------------------------------
find_icon() {
    local state=$1 p f
    [ "$NOTIFY_ICON" = 1 ] || return 1
    for p in /usr/share/icons/hicolor/scalable/apps \
             /usr/local/share/icons/hicolor/scalable/apps \
             "$SELF_DIR/icons" "$SELF_DIR/../icons"; do
        f="$p/refresh-rate-$state.svg"
        if [ -r "$f" ]; then readlink -f -- "$f"; return 0; fi
    done
    return 1
}

notify_change() {
    local state=$1 summary=$2 icon title body img hints=()
    [ "$NOTIFY" = 1 ] || return 0
    have notify-send || return 0

    if [ "$state" = ac ]; then
        title=$(t "Tasa de refresco al maximo" "Maximum refresh rate set")
        body=$(t "Conectado a la corriente electrica" "Plugged into the mains")
    else
        title=$(t "Tasa de refresco reducida" "Refresh rate reduced")
        body=$(t "Funcionando con la bateria" "Running on battery")
    fi
    body="$body"$'\n'$(printf '%s\n' "$summary" |
        awk 'NF{printf "%s: %s Hz \xe2\x86\x92 %s Hz\n", $1, $2, $3}')

    # absolute path: works regardless of the installed icon theme
    icon=$(find_icon "$state") || icon="video-display-symbolic"

    if [ "$NOTIFY_SNAPSHOT" = 1 ]; then
        img="${TMPDIR:-/tmp}/refresh-rate-sync.$(date +%s).png"
        local ok=0
        if   have grimshot;         then grimshot  save -- "$img" >/dev/null 2>&1 && ok=1
        elif have grim;             then grim "$img" >/dev/null 2>&1 && ok=1
        elif have spectacle;        then spectacle --platform wayland --noninteractive --png --filename "$img" >/dev/null 2>&1 && ok=1
        elif have gnome-screenshot; then gnome-screenshot -f "$img" >/dev/null 2>&1 && ok=1
        elif have scrot;            then scrot -o "$img" >/dev/null 2>&1 && ok=1
        elif have import;           then import -window root "$img" >/dev/null 2>&1 && ok=1
        else img=""; fi
        if [ "$ok" = 1 ] && [ -s "$img" ]; then
            have convert && convert "$img" -resize 240x135\> "$img" 2>/dev/null
            hints=(--hint "string:image-path:$img")
        else
            img=""
        fi
    fi

    notify-send -a "refresh-rate-sync" -i "$icon" -t "$NOTIFY_TIMEOUT" \
        "${hints[@]}" -- "$title" "$body" >/dev/null 2>&1 || true

    [ -n "${img:-}" ] && rm -f -- "$img"
    return 0
}

notify_error() {
    [ "$NOTIFY" = 1 ] || return 0
    [ "$NOTIFY_FAIL" = 1 ] || return 0
    have notify-send || return 0
    notify-send -a "refresh-rate-sync" -i "$(find_icon ac || echo video-display-symbolic)" \
        -u critical -t 8000 -- \
        "$(t "Tasa de refresco" "Refresh rate")" \
        "$(t "No hay soporte para este escritorio: no se pudo cambiar la tasa de refresco." \
             "This desktop is not supported: could not change the refresh rate.")" \
        >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
STATE_ARG=auto FORCE=0 QUIET=0 DRY=0
for a in "$@"; do
    case "$a" in
        ac)            STATE_ARG=ac ;;
        bat|batt)      STATE_ARG=bat ;;
        auto|ignore)   STATE_ARG=$a ;;
        --force)       FORCE=1 ;;
        --quiet|-q)    QUIET=1 ;;
        --dry-run|-n)  DRY=1 ;;
        --backend=*)   RRS_BACKEND=${a#--backend=} ;;
        --help|-h)     sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)             die "$(t 'argumento desconocido' 'unknown argument'): $a" ;;
    esac
done

STATE=$STATE_ARG
[ "$STATE" = auto ] && STATE=$(power_state)
[ "$STATE" = ignore ] && { log "set-mode: no battery and NO_BATTERY_STATE=ignore, nothing to do"; exit 0; }

want=$AC_HZ
[ "$STATE" = bat ] && want=$BATTERY_HZ

log "set-mode: state=$STATE target=${want}Hz user=$(id -un) session=${XDG_SESSION_TYPE:-?} display=${WAYLAND_DISPLAY:-${DISPLAY:-none}}"

# ---------------------------------------------------------------------------
# Backend + mode listing (retry while the session is still starting)
# ---------------------------------------------------------------------------
BACKEND="" MODES="" m="" try=0
while : ; do
    try=$((try + 1))
    for cand in $(backend_candidates); do
        m=$(list_modes "$cand" 2>/dev/null)
        if [ -n "$m" ]; then BACKEND=$cand; MODES=$m; break; fi
    done
    [ -n "$BACKEND" ] && break
    [ "$try" -gt "$BACKEND_RETRIES" ] && break
    log "set-mode: desktop not ready yet (attempt $try/$BACKEND_RETRIES), waiting ${BACKEND_RETRY_DELAY}s"
    sleep "$BACKEND_RETRY_DELAY"
done
if [ -z "$BACKEND" ]; then
    log "set-mode: no backend available (RRS_BACKEND=$RRS_BACKEND)"
    notify_error
    exit 2
fi
log "set-mode: backend=$BACKEND outputs: $(printf '%s\n' "$MODES" | awk '{print $1}' | sort -u | tr '\n' ' ')"

# output filters
MODES=$(printf '%s\n' "$MODES" | while read -r n rest; do
    keep_output "$n" && printf '%s %s\n' "$n" "$rest"
done)
[ -n "$MODES" ] || { log "set-mode: no output left to handle (filters)"; exit 0; }

# ---------------------------------------------------------------------------
# Plan + apply + verify
# ---------------------------------------------------------------------------
plan=$(pick_modes "$MODES" "$want")
if [ -z "$plan" ]; then
    log "set-mode: already at the target ($want)"
    [ "$FORCE" = 1 ] || exit 0
    # --force: re-assert the current mode (session start / after suspend)
    plan=$(printf '%s\n' "$MODES" | awk '$6==1 {print $1, $4, $4, $5, $2"x"$3}')
fi
[ -n "$plan" ] || { log "set-mode: nothing pending"; exit 0; }

if [ "$DRY" = 1 ]; then
    printf '%s\n' "$plan" | while read -r n o ne id res; do
        log "dry-run: $n $(fmt_hz "$o")Hz -> $(fmt_hz "$ne")Hz  (mode $id, $res)"
    done
    exit 0
fi

pending=$plan
after=$MODES
attempt=0
while : ; do
    attempt=$((attempt + 1))
    while read -r name old new id res; do
        [ -n "$name" ] || continue
        log "set-mode: $name $(fmt_hz "$old")Hz -> $(fmt_hz "$new")Hz  [$BACKEND]"
        apply_one "$BACKEND" "$name" "${res%x*}" "${res#*x}" "$new" "$id" \
            || log "set-mode: '$BACKEND' failed while applying $name"
    done <<<"$pending"

    sleep "$SETTLE_DELAY"
    after=$(list_modes "$BACKEND" 2>/dev/null)
    [ -n "$after" ] || after=$MODES
    pending=$(pick_modes "$after" "$want")
    [ -z "$pending" ] && break
    [ "$attempt" -gt "$RETRIES" ] && break
    log "set-mode: not confirmed on: $(printf '%s\n' "$pending" | awk '{print $1}' | tr '\n' ' ') -- retry $attempt in ${RETRY_DELAY}s"
    sleep "$RETRY_DELAY"
done

summary=$(diff_modes "$MODES" "$after")
if [ -n "$summary" ]; then
    printf '%s\n' "$summary"
    log "set-mode: applied: $(printf '%s\n' "$summary" | tr '\n' ' ')"
    [ "$QUIET" = 1 ] || notify_change "$STATE" "$summary"
else
    if [ -n "$pending" ]; then
        log "set-mode: the change did NOT take effect"
        notify_error
    else
        log "set-mode: mode already correct, no visible change"
    fi
fi
exit 0
