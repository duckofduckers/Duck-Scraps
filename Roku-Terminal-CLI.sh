#!/bin/bash

RED="\e[31m"
RESET="\e[0m"

if ! command -v nmap >/dev/null 2>&1; then
    { apt install nmap || { echo -e "${RED}Install nmap package${RESET}"; exit 1; }; }
fi
if ! command -v curl >/dev/null 2>&1; then
    { apt install curl || { echo -e "${RED}Install curl package${RESET}"; exit 1; }; }
fi

clear

ROKU_PORT=8060
TIMEOUT=1.55

declare -a ROKU_IPS
declare -a ROKU_NAMES

valid_ip() {
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r o1 o2 o3 o4 <<< "$1"
    for o in $o1 $o2 $o3 $o4; do
        ((o >= 0 && o <= 255)) || return 1
    done
    return 0
}

get_power_state() {
    RESPONSE=$(curl -s --max-time $TIMEOUT "http://$ROKU:$ROKU_PORT/query/device-info")
    echo "$RESPONSE" | sed -n 's:.*<power-mode>\(.*\)</power-mode>.*:\1:p'
}

echo "Select connection method:"
echo "[1] Scan for Roku devices"
echo "[2] Enter Roku IP manually"
echo

while true; do
    read -p "Enter number: " MODE
    [[ "$MODE" =~ ^[12]$ ]] && break
    echo -e "${RED}Invalid selection.${RESET}"
done

echo

if [ "$MODE" = "2" ]; then
    while true; do
        read -p "Enter Roku IP: " MANUAL_IP
        valid_ip "$MANUAL_IP" && break
        echo -e "${RED}Invalid IP.${RESET}"
    done

    RESPONSE=$(curl -s --max-time $TIMEOUT "http://$MANUAL_IP:$ROKU_PORT/query/device-info")
    if echo "$RESPONSE" | grep -qi "<friendly-device-name>"; then
        NAME=$(echo "$RESPONSE" | grep -oP '(?<=<friendly-device-name>).*?(?=</friendly-device-name>)')
        ROKU_IPS+=("$MANUAL_IP")
        ROKU_NAMES+=("$NAME")
    else
        echo -e "${RED}Device did not respond as Roku.${RESET}"
        exit 1
    fi
else
    LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [ -z "$LOCAL_IP" ]; then
        LOCAL_IP=$(ifconfig 2>/dev/null | awk '/inet / && !/127.0.0.1/ {print $2; exit}')
    fi

    valid_ip "$LOCAL_IP" || { echo -e "${RED}Could not determine valid local IP${RESET}"; exit 1; }

    PREFIX=$(echo "$LOCAL_IP" | awk -F. '{print $1"."$2"."$3"."}')
    echo "Local IP: $LOCAL_IP"
    echo "Scanning subnet ${PREFIX}0/24..."
    echo

    ACTIVE_IPS=$(nmap -sn "${PREFIX}0/24" | awk '/Nmap scan report/{print $NF}')

    for IP in $ACTIVE_IPS; do
        valid_ip "$IP" || continue
        RESPONSE=$(curl -s --max-time $TIMEOUT "http://$IP:$ROKU_PORT/query/device-info")
        if echo "$RESPONSE" | grep -qi "<friendly-device-name>"; then
            NAME=$(echo "$RESPONSE" | grep -oP '(?<=<friendly-device-name>).*?(?=</friendly-device-name>)')
            ROKU_IPS+=("$IP")
            ROKU_NAMES+=("$NAME")
            echo "Found Roku: $NAME ($IP)"
        fi
    done

    echo
    [ ${#ROKU_IPS[@]} -eq 0 ] && { echo -e "${RED}No Roku devices found.${RESET}"; exit 1; }

    echo "Select a Roku device:"
    for i in "${!ROKU_IPS[@]}"; do
        echo "[$((i+1))] ${ROKU_NAMES[$i]} (${ROKU_IPS[$i]})"
    done

    while true; do
        read -p "Enter number: " selection
        [[ "$selection" =~ ^[0-9]+$ ]] || { echo -e "${RED}Invalid selection.${RESET}"; continue; }
        INDEX=$((selection-1))
        [ "$INDEX" -ge 0 ] && [ "$INDEX" -lt "${#ROKU_IPS[@]}" ] && break
        echo -e "${RED}Invalid selection.${RESET}"
    done
fi

[ "$MODE" = "2" ] && INDEX=0

ROKU="${ROKU_IPS[$INDEX]}"

echo
echo "Connected to ${ROKU_NAMES[$INDEX]} ($ROKU)"
echo "Type 'exit()' to quit."
echo "Use: launch <app_id> to open an app."
echo "Use: apps to list installed apps."
echo "Use: tv-info to show full device info."
echo "Use: active-app to show currently running app."
echo "Use: clear to clear the terminal"
echo "Use: help to get help on how to use the CLI again."
echo

while true; do
    read -p "[${ROKU_NAMES[$INDEX]}] CMD ~: " CMD
    CMD=$(echo "$CMD" | tr '[:upper:]' '[:lower:]' | xargs)

    [ -z "$CMD" ] && continue

    if [ "$CMD" = "exit()" ]; then
        echo "Exiting..."
        break
    fi

    POWER_STATE=$(get_power_state)

    if { [ -z "$POWER_STATE" ] || [ "$POWER_STATE" != "PowerOn" ]; } && \
         [ "$CMD" != "power" ] && \
         [ "$CMD" != "help" ] && \
         [ "$CMD" != "clear" ]; then
         echo -e "${RED}TV is off or unreachable. Only 'power' if TV is reachable, 'help', and 'clear' commands are working.${RESET}"
         continue
    fi

    if [ "$CMD" = "apps" ]; then
        echo
        i=1
        curl -s "http://$ROKU:$ROKU_PORT/query/apps" | \
        grep "<app " | \
        while read line; do
            APP_ID=$(echo "$line" | sed -n 's/.*id="\([^"]*\)".*/\1/p')
            APP_NAME=$(echo "$line" | sed -n 's/.*>\(.*\)<\/app>.*/\1/p')
            echo "$i: $APP_ID ~> $APP_NAME"
            ((i++))
        done
        echo
        continue
    fi

    if [ "$CMD" = "tv-info" ]; then
        echo
        RESPONSE=$(curl -s "http://$ROKU:$ROKU_PORT/query/device-info")
        echo "Device Info:"
        echo "$RESPONSE" | sed -n 's/.*<\([^>]*\)>\(.*\)<\/[^>]*>/\1: \2/p'
        echo
        continue
    fi

    if [ "$CMD" = "active-app" ]; then
        RESPONSE=$(curl -s "http://$ROKU:$ROKU_PORT/query/active-app")
        APP_ID=$(echo "$RESPONSE" | sed -n 's/.*<app id="\([^"]*\)".*/\1/p')
        APP_NAME=$(echo "$RESPONSE" | sed -n 's/.*<app id="[^"]*".*>\(.*\)<\/app>.*/\1/p')
        echo
        echo "Active App: $APP_ID ~> $APP_NAME"
        echo
        continue
    fi
    
    if [ "$CMD" = "clear" ]; then
        clear
        continue
    fi

    if [ "$CMD" = "help" ]; then
        echo
        echo "Connected to ${ROKU_NAMES[$INDEX]} ($ROKU)"
        echo "Type 'exit()' to quit."
        echo "Use: launch <app_id> to open an app."
        echo "Use: apps to list installed apps."
        echo "Use: tv-info to show full device info."
        echo "Use: active-app to show currently running app."
        echo "Use: clear to clear the terminal"
        echo "Use: help to get help on how to use the CLI again."
        echo
        continue
    fi
    
    if [[ "$CMD" == launch* ]]; then
        APP_ID=$(echo "$CMD" | awk '{print $2}')
        curl -s -d "" "http://$ROKU:$ROKU_PORT/launch/$APP_ID" >/dev/null
        continue
    fi

    curl -s -d "" "http://$ROKU:$ROKU_PORT/keypress/$CMD" >/dev/null
done
