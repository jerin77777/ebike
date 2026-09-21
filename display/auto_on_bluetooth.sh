#!/bin/bash
# ==============================================================================
# Automatically Turn ON and Configure Bluetooth on Raspberry Pi 4B
# ------------------------------------------------------------------------------
# This script:
# 1. Unblocks rfkill soft/hard blocks on Bluetooth
# 2. Ensures systemd bluetooth.service is active & enabled
# 3. Brings up the hci0 Bluetooth adapter
# 4. Configures power on, discoverable on (no timeout), and pairable on via bluetoothctl
# 5. Optionally starts the E-Bike BLE Host Daemon in the background
# ==============================================================================

set -e

GREEN="\033[1;32m"
BLUE="\033[1;34m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
RESET="\033[0m"

echo -e "${BLUE}======================================================${RESET}"
echo -e "${BLUE}   Raspberry Pi 4B - Bluetooth Auto Power & Pairing   ${RESET}"
echo -e "${BLUE}======================================================${RESET}"

# 1. Check root / sudo
if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}[!] Escalating to sudo privileges...${RESET}"
    exec sudo bash "$0" "$@"
fi

# 2. Unblock rfkill
echo -e "${GREEN}[1/5] Unblocking Bluetooth via rfkill...${RESET}"
rfkill unblock bluetooth || true
rfkill unblock all || true

# 3. Ensure bluetooth.service is running and enabled on boot
echo -e "${GREEN}[2/5] Ensuring bluetooth systemd service is active...${RESET}"
systemctl enable bluetooth.service >/dev/null 2>&1 || true
systemctl start bluetooth.service

# Short pause for BlueZ daemon initialization
sleep 1

# 4. Bring up hci0 controller interface
echo -e "${GREEN}[3/5] Bringing up hci0 adapter...${RESET}"
if command -v hciconfig >/dev/null 2>&1; then
    hciconfig hci0 up || true
fi

# 5. Configure bluetoothctl (Power ON, Discoverable, Pairable)
echo -e "${GREEN}[4/5] Enabling Power, Discoverability & Pairing...${RESET}"
bluetoothctl -- power on
bluetoothctl -- discoverable-timeout 0
bluetoothctl -- discoverable on
bluetoothctl -- pairable on

# Optional: Set friendly adapter alias if not already set
bluetoothctl -- system-alias "Volt-EBike-RPI4" || true

# 6. Verify and display status
echo -e "${GREEN}[5/5] Bluetooth Status Verification:${RESET}"
echo "------------------------------------------------------"
if command -v bluetoothctl >/dev/null 2>&1; then
    bluetoothctl show | grep -E "Controller|Name|Alias|Powered|Discoverable|Pairable" || true
fi
echo "------------------------------------------------------"

echo -e "${GREEN}[✓] Bluetooth is now ON, Discoverable, and Ready to Pair!${RESET}"

# If --daemon flag is passed, also launch ebike_bluetooth_host.py
if [ "$1" = "--daemon" ] || [ "$1" = "-d" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    HOST_SCRIPT="$SCRIPT_DIR/ebike_bluetooth_host.py"
    if [ -f "$HOST_SCRIPT" ]; then
        echo -e "${BLUE}[*] Starting E-Bike BLE Host Daemon in background...${RESET}"
        nohup python3 "$HOST_SCRIPT" > "$SCRIPT_DIR/bluetooth_host.log" 2>&1 &
        echo -e "${GREEN}[✓] Daemon started with PID $! (logs: $SCRIPT_DIR/bluetooth_host.log)${RESET}"
    fi
fi
