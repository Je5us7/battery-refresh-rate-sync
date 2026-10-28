#!/usr/bin/env bash
#
# tests/run-tests.sh -- offline checks for the mode selection logic.
#
# Nothing is applied to the real screen: every case runs set-mode.sh with
# --dry-run against a fixture, through stub commands injected in PATH. That
# means the suite runs headless, without root, in CI, and on a machine that has
# no desktop session at all.
#
# The guarantee under test: the refresh rate changes, the resolution never does.
#
set -uo pipefail

TESTS=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd)
SRC=$TESTS/../lib/set-mode.sh
FIX=$TESTS/fixtures
[ -x "$SRC" ] || { echo "set-mode.sh not found/executable: $SRC" >&2; exit 1; }

TMP=$(mktemp -d /tmp/battery-refresh-rate-sync-tests.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/xdg"

PASS=0 FAIL=0

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
# Hermetic config: always pins both targets so an installed
# /etc/battery-refresh-rate-sync.conf cannot influence a test.
mkconf() {   # mkconf [KEY=value ...]
    {
        echo 'NOTIFY=0'
        echo 'RATE_TOLERANCE=1.0'
        echo 'AC_HZ=max'
        echo 'BATTERY_HZ=60'
        printf '%s\n' "$@"
    } > "$TMP/xdg/battery-refresh-rate-sync.conf"
}

# stub <command> <fixture-file> : make <command> print the fixture
stub() {
    printf '#!/bin/sh\ncat "%s"\n' "$2" > "$TMP/bin/$1"
    chmod +x "$TMP/bin/$1"
}

# run <backend> <ac|bat> : set-mode.sh --dry-run, session env emptied.
# stdout carries only the plan lines; the whole trace is kept for error reports.
run() {
    env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$HOME" XDG_CONFIG_HOME="$TMP/xdg" \
        XDG_RUNTIME_DIR="$TMP" DISPLAY= WAYLAND_DISPLAY= SWAYSOCK=/tmp/stub.sock \
        HYPRLAND_INSTANCE_SIGNATURE=stub \
        bash "$SRC" "$2" --dry-run --backend="$1" > "$TMP/last-trace.log" 2>&1
    grep '^dry-run:' "$TMP/last-trace.log" || true
}

ok()   { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"
         printf '        expected to %s %s\n' "$2" "$3"
         printf '        plan: %s\n' "$(printf '%s' "$4" | tr '\n' '|')"
         printf '        trace: %s\n' "$(tr '\n' '|' < "$TMP/last-trace.log")" ; }

has()     { # has <case name> <output> <needle>
    if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1" "contain" "'$3'" "$2"; fi
}
has_re()    { # has_re <case name> <output> <regex>
    if printf '%s' "$2" | grep -qE -- "$3"; then ok "$1"; else bad "$1" "match" "/$3/" "$2"; fi
}
hasnt() { # hasnt <case name> <output> <needle>
    if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1" "NOT contain" "'$3'" "$2"; else ok "$1"; fi
}
hasnt_re() { # hasnt_re <case name> <output> <regex>
    if printf '%s' "$2" | grep -qE -- "$3"; then bad "$1" "NOT match" "/$3/" "$2"; else ok "$1"; fi
}
silent() { # silent <case name> <output>   -> no dry-run line at all
    if printf '%s' "$2" | grep -q 'dry-run:'; then bad "$1" "produce no change" "dry-run lines" "$2"
    else ok "$1"; fi
}

# --------------------------------------------------------------------------
# X11 backend (xrandr)
# --------------------------------------------------------------------------
echo "x11 / xrandr"

stub xrandr "$FIX/xrandr-1080p144.txt"
mkconf
out=$(run x11 ac)
# 144 Hz is the max at the current 1920x1080; 144 at other resolutions must not
# drag the panel into a different resolution
has    "ac raises 1080p60 to 1080p144"        "$out" "eDP-1 60Hz -> 144Hz"
has    "ac keeps the resolution 1920x1080"    "$out" ", 1920x1080)"
hasnt  "ac never changes resolution"          "$out" "1280x720"
hasnt_re "ac leaves an already-max output alone" "$out" '^dry-run: DP-1 '

out=$(run x11 bat)
silent "bat stays at 60 Hz (already there)"   "$out"

stub xrandr "$FIX/xrandr-nonative.txt"
mkconf
out=$(run x11 bat)
has    "bat on a non-native resolution lowers 1680x1050@120 to @60" "$out" "eDP-1 120Hz -> 60Hz"
has    "bat keeps the non-native resolution"  "$out" ", 1680x1050)"
hasnt  "bat does not jump to the native mode" "$out" "1920x1080"
out=$(run x11 ac)
silent "ac keeps a non-native resolution at its own max" "$out"

stub xrandr "$FIX/xrandr-nobelow60.txt"
mkconf
out=$(run x11 bat)
has    "bat with no mode <= 60 picks the lowest at the same res" "$out" "eDP-1 144Hz -> 75Hz"
has    "bat stays on 1920x1080 in that case"  "$out" ", 1920x1080)"
out=$(run x11 ac)
silent "ac does nothing when already at max"  "$out"

stub xrandr "$FIX/xrandr-ntsc.txt"
mkconf
out=$(run x11 bat)
silent "59.94 counts as 60 (RATE_TOLERANCE)"  "$out"
mkconf 'RATE_TOLERANCE=0.01'
out=$(run x11 bat)
has    "with no tolerance, 59.94 -> 60.00 is a real change" "$out" "eDP-1 59.94Hz -> 60Hz"

mkconf 'BATTERY_HZ=min'
stub xrandr "$FIX/xrandr-1080p144.txt"
out=$(run x11 bat)
has    "BATTERY_HZ=min picks the lowest rate of the current res" "$out" "eDP-1 60Hz -> 50Hz"

mkconf 'BATTERY_HZ=90'
stub xrandr "$FIX/xrandr-1080p144.txt"
out=$(run x11 bat)
has    "a numeric target moves the rate to the best mode at or below it" "$out" "eDP-1 60Hz -> 75Hz"

# --------------------------------------------------------------------------
# wlroots backend (wlr-randr)
# --------------------------------------------------------------------------
echo "wlroots / wlr-randr"
stub wlr-randr "$FIX/wlr-1080p144.txt"
mkconf
out=$(run wlr ac)
has    "ac raises 1080p60 to 1080p144"        "$out" "eDP-1 60Hz -> 144Hz"
has    "ac keeps the resolution"              "$out" ", 1920x1080)"
silent "ac leaves the 165 Hz monitor alone"   "$(printf '%s' "$out" | grep -E '^dry-run: DP-1 ' || true)"

# --------------------------------------------------------------------------
# Hyprland backend (hyprctl + jq)
# --------------------------------------------------------------------------
echo "hyprland / hyprctl"
stub hyprctl "$FIX/hypr-1080p144.json"
mkconf
out=$(run hyprland ac)
has    "ac raises 1080p60 to 1080p144"        "$out" "eDP-1 60Hz -> 144Hz"
has    "ac keeps the resolution"              "$out" ", 1920x1080)"
out=$(run hyprland bat)
silent "bat already at 60 does nothing"       "$out"

# --------------------------------------------------------------------------
# Sway backend (swaymsg + jq)
# --------------------------------------------------------------------------
echo "sway / swaymsg"
stub swaymsg "$FIX/sway-1080p144.json"
mkconf
out=$(run sway ac)
has    "ac raises 1080p60 to 1080p144"        "$out" "eDP-1 60Hz -> 144Hz"
has    "ac keeps the resolution"              "$out" ", 1920x1080)"

# --------------------------------------------------------------------------
# Filters and session-less runs
# --------------------------------------------------------------------------
echo "filters"
stub xrandr "$FIX/xrandr-1080p144.txt"
mkconf 'ONLY_INTERNAL=1'
out=$(run x11 ac)
hasnt_re "ONLY_INTERNAL=1 ignores DP-1"       "$out" '^dry-run: DP-1 '
mkconf 'SKIP_OUTPUTS=eDP-1'
out=$(run x11 ac)
hasnt  "SKIP_OUTPUTS removes eDP-1 from the plan" "$out" "eDP-1"
mkconf 'TARGET_OUTPUTS=DP-1'
out=$(run x11 ac)
hasnt  "TARGET_OUTPUTS keeps only DP-1"       "$out" "eDP-1"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
