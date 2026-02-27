#!/usr/bin/env bash

RED="\e[31m"
RESET="\e[0m"

for cmd in nmap curl gawk sed grep ifconfig; do
    command -v $cmd >/dev/null 2>&1 || { echo -e "${RED}Please install $cmd${RESET}"; exit 1; }
done

clear

ROKU_PORT=8060
TIMEOUT=1.8

if ping -c 3 -W 1 "$ROKU" >/dev/null 2>&1; then
    AVG_PING=$(ping -c 3 -q "$ROKU" | awk -F'/' '/rtt/ {print $5}')
    REACHABLE_TIMEOUT_CONNECT=$(awk "BEGIN {print $AVG_PING/1000 * 2}")
    REACHABLE_TIMEOUT_TOTAL=$(awk "BEGIN {print $AVG_PING/1000 * 4}")
else
    REACHABLE_TIMEOUT_CONNECT=0.255
    REACHABLE_TIMEOUT_TOTAL=0.415
fi

declare -a ROKU_IPS
declare -a ROKU_NAMES

valid_ip() {
    local ip=$1
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    for o in "$o1" "$o2" "$o3" "$o4"; do
        (( o >= 0 && o <= 255 )) || return 1
    done
    return 0
}

is_tv_reachable() {
    curl -s --connect-timeout "$REACHABLE_TIMEOUT_CONNECT" --max-time "$REACHABLE_TIMEOUT_TOTAL" \
         "http://$ROKU:$ROKU_PORT/query/device-info" >/dev/null 2>&1
}

print_help() {
    echo
    echo "Connected to ${ROKU_NAME} (${ROKU})"
    echo
    echo "Commands:"
    echo "  launch <app_id>     → open app (example: launch 12)"
    echo "  apps                → list installed apps"
    echo "  active-app          → show current app"
    echo "  tv-info             → full device information"
    echo "  power               → toggle power (on/off)"
    echo "  clear               → clear screen"
    echo "  help                → this message"
    echo "  exit()              → quit"
    echo "  Any other word → sent as keypress (Home, Up, Down, Rev, Play, etc.)"
    echo
    echo "Command Syntax:"
    echo "  cmd\\cmd             → multiple commands"
    echo "  *delay*\\cmd\\*delay*\\cmd     → command delay"
    echo
}

print_is_not_reachable() {
    echo
    echo -e "${RED}TV appears to be unreachable.${RESET}"
    echo "Only 'exit()', 'help' and 'clear' are available right now."
    echo
}

print_invalid_selection() {
    echo
    echo -e "${RED}Invalid selection.${RESET}"
    echo
}

echo "Select connection method:"
echo "[1] Scan for Roku devices"
echo "[2] Enter Roku IP manually"
echo

while true; do
    if ! read -e -r -p "Enter number: " MODE; then
        exit
    fi
    [[ "$MODE" == "1" || "$MODE" == "2" ]] && break
    print_invalid_selection
done

echo

if [[ "$MODE" == "2" ]]; then
    while true; do
        if ! read -e -r -p "Enter Roku IP: " MANUAL_IP; then
            exit
        fi
        valid_ip "$MANUAL_IP" && break
        echo
        echo -e "${RED}Invalid IP format.${RESET}"
        echo
    done

    resp=$(curl -s --max-time "$TIMEOUT" "http://$MANUAL_IP:$ROKU_PORT/query/device-info" 2>/dev/null)
    if [[ $resp =~ friendly-device-name ]]; then
        NAME=$(echo "$resp" | sed -n 's/.*<friendly-device-name>\(.*\)<\/friendly-device-name>.*/\1/p' | tr -d '\r')
        [[ -z "$NAME" ]] && NAME="Unnamed Roku"
        ROKU_IPS+=("$MANUAL_IP")
        ROKU_NAMES+=("$NAME")
        INDEX=0
    else
        echo
        echo -e "${RED}No valid Roku response from that IP.${RESET}"
        echo
        exit 1
    fi
else
    read IP MASK <<< $(ifconfig 2>/dev/null \
    | awk '/inet / && !/127.0.0.1/ && !/tun/ && !/rmnet/ {print $2, $4; exit}')

    mask2cidr () {
        local x n=0
        IFS=. read -r i1 i2 i3 i4 <<< "$1"
        for x in $i1 $i2 $i3 $i4; do
            while [ $x -gt 0 ]; do
                ((n+=x&1))
                ((x>>=1))
            done
        done
        echo $n
    }

    CIDR=$(mask2cidr "$MASK")

    IFS=. read -r i1 i2 i3 i4 <<< "$IP"
    IFS=. read -r m1 m2 m3 m4 <<< "$MASK"

    NETWORK="$((i1&m1)).$((i2&m2)).$((i3&m3)).$((i4&m4))"

    valid_ip "$IP" || { echo -e "${RED}Could not determine local network IP${RESET}"; echo; exit 1; }

    echo "Local IP: $IP"
    echo "Scanning subnet ${NETWORK}/${CIDR} (may take 5-15 seconds)..."
    echo

    ACTIVE_IPS=$(nmap -sn -T4 "${NETWORK}/${CIDR}" 2>/dev/null | \
    awk '/Nmap scan report for/{print $NF}' | \
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    [[ -z "$ACTIVE_IPS" ]] && { echo -e "${RED}No active hosts found.${RESET}"; exit 1; }

    for HOST in $ACTIVE_IPS; do
        resp=$(curl -s --max-time "$TIMEOUT" "http://$HOST:$ROKU_PORT/query/device-info" 2>/dev/null)
        if [[ $resp =~ friendly-device-name ]]; then
            NAME=$(echo "$resp" | sed -n 's/.*<friendly-device-name>\(.*\)<\/friendly-device-name>.*/\1/p' | tr -d '\r')
            [[ -z "$NAME" ]] && NAME="Roku-$HOST"
            ROKU_IPS+=("$HOST")
            ROKU_NAMES+=("$NAME")
            echo "Found: $NAME ($HOST)"
        fi
        sleep 0.05
    done

    [[ ${#ROKU_IPS[@]} -eq 0 ]] && { echo -e "${RED}No Roku devices found.${RESET}"; echo; exit 1; }

    echo
    echo "Select a Roku device:"
    for i in "${!ROKU_IPS[@]}"; do
        echo "[$((i+1))] ${ROKU_NAMES[i]} (${ROKU_IPS[i]})"
    done

    while true; do
        if ! read -e -r -p "Enter number: " selection; then
            exit
        fi
        [[ "$selection" =~ ^[0-9]+$ ]] || { print_invalid_selection; continue; }
        INDEX=$((selection-1))
        (( INDEX >= 0 && INDEX < ${#ROKU_IPS[@]} )) && break
        print_invalid_selection
    done
fi

ROKU="${ROKU_IPS[INDEX]}"
ROKU_NAME="${ROKU_NAMES[INDEX]}"

print_help

process_command() {
    local CMD="$1"
    [[ "$CMD" == "exit()" ]] && { echo; exit; }
    [[ "$CMD" == "clear" ]] && { clear; return; }
    [[ "$CMD" == "help" ]] && { print_help; return; }

    if ! is_tv_reachable; then
        print_is_not_reachable
        return
    fi

    case "$CMD" in
        apps)
            echo
            curl -s --max-time 0.56 "http://$ROKU:$ROKU_PORT/query/apps" | \
            grep -o '<app .*</app>' | \
            while IFS= read -r line; do
                id=$(echo "$line" | sed -n 's/.*id="\([^"]*\)".*/\1/p')
                name=$(echo "$line" | sed -n 's/.*>\(.*\)<\/app>/\1/p')
                [[ -n "$name" ]] && echo "$id → $name"
            done | nl -w2 -s': '
            echo
            ;;
        tv-info)
            echo
            curl -s --max-time 0.55 "http://$ROKU:$ROKU_PORT/query/device-info" | \
            sed -n 's/<\([^>]*\)>\(.*\)<\/\1>/\1: \2/p' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
            echo
            ;;
        active-app)
            echo
            resp=$(curl -s --max-time 0.5 "http://$ROKU:$ROKU_PORT/query/active-app")
            id=$(echo "$resp" | sed -n 's/.*id="\([^"]*\)".*/\1/p')
            name=$(echo "$resp" | sed -n 's/.*>\(.*\)<\/app>.*/\1/p')
            [[ -n "$name" ]] && echo "Active: $id → $name" || echo "No active app detected"
            echo
            ;;
        launch*)
            echo
            APP_ID=$(echo "$CMD" | awk '{print $2}')
            if [[ -z "$APP_ID" ]]; then
                echo -e "${RED}Usage: launch <app_id>${RESET}"
                return
            fi
            curl -s --max-time 0.6 -o /dev/null -X POST "http://$ROKU:$ROKU_PORT/launch/$APP_ID"
            echo "Launch request sent for app $APP_ID"
            echo
            ;;
        power)
            curl -s --max-time 0.6 -o /dev/null -X POST "http://$ROKU:$ROKU_PORT/keypress/Power"
            echo
            echo "Power key sent"
            echo
            ;;
        *)
            curl -s --max-time 0.6 -o /dev/null -X POST "http://$ROKU:$ROKU_PORT/keypress/$CMD"
            ;;
    esac
}

while true; do
    if ! read -e -r -p "[${ROKU_NAME}] ECP </> " input; then
        exit
    fi
    CMD="${input,,}"
    CMD="${CMD#"${CMD%%[![:space:]]*}"}"
    CMD="${CMD%"${CMD##*[![:space:]]}"}" 
    [[ -z "$CMD" ]] && continue

    if [[ "$CMD" != *"\\"* ]]; then
        process_command "$CMD"
        continue
    fi

    IFS='\\' read -ra PARTS <<< "$CMD"
    
    empty=false
    for part in "${PARTS[@]}"; do
        [[ -z "${part//[[:space:]]/}" ]] && empty=true && break
    done
    if $empty || [[ ${#PARTS[@]} -lt 2 ]]; then
        echo
        echo -e "${RED}Syntax error: invalid multi command usage${RESET}"
        echo
        continue
    fi

    last_was_command=false
    for i in "${!PARTS[@]}"; do
        part="${PARTS[i]}"
        p="${part#"${part%%[![:space:]]*}"}"
        p="${p%"${p##*[![:space:]]}"}"  
        if [[ "$p" =~ ^\*([0-9]+(\.[0-9]+)?)\*$ ]]; then
            if [[ ! $last_was_command && $i -ne 0 ]]; then
                echo
                echo -e "${RED}Syntax error: invalid delay usage${RESET}"
                echo
                break
            fi
            sleep "${BASH_REMATCH[1]}"
            last_was_command=false
        else
            process_command "$p"
            last_was_command=true
        fi
    done
done
