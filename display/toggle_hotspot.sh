#!/bin/bash
# ==============================================================================
# Toggle Raspberry Pi Wi-Fi Host (Access Point / Router mode) for ESP32
# ------------------------------------------------------------------------------
# 1. On 'on' / 'start': Turns on Wi-Fi hotspot with set SSID and password
# 2. On 'off' / 'stop': Turns off hotspot and returns to normal client Wi-Fi
# 3. On 'status': Returns 'active' or 'inactive'
# 4. On 'toggle' (default): Switches between Host and Normal Wi-Fi
# ==============================================================================

set -e

# User credentials (matches auto_on_bluetooth.sh)
USER_NAME="${EBIKE_USER:-ebike}"
USER_PASS="${EBIKE_PASS:-123}"

# Ensure running with sudo / root privileges automatically using credentials
if [ "$EUID" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        echo "$USER_PASS" | sudo -S bash "$0" "$@"
        exit $?
    else
        echo "[ERROR] 'sudo' not found. Please run this script as root." >&2
        exit 1
    fi
fi

# Load config if exists
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/hotspot_config.env" ]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/hotspot_config.env"
fi

HOTSPOT_SSID="${HOTSPOT_SSID:-ebike}"
HOTSPOT_PASS="${HOTSPOT_PASS:-123}"
HOTSPOT_IFACE="${HOTSPOT_IFACE:-wlan0}"
CON_NAME="EBike-Hotspot"
STATE_FILE="/tmp/ebike_hotspot_active"

is_hotspot_active() {
    if command -v nmcli >/dev/null 2>&1; then
        if nmcli -t -f NAME,TYPE con show --active 2>/dev/null | grep -E -q "^(${CON_NAME}|Hotspot):"; then
            return 0
        fi
    fi
    if [ -f "$STATE_FILE" ]; then
        return 0
    fi
    return 1
}

start_hotspot() {
    echo "=== Turning ON Raspberry Pi Host Mode (SSID: $HOTSPOT_SSID) ==="
    rfkill unblock wifi 2>/dev/null || true
    rfkill unblock all 2>/dev/null || true

    if command -v nmcli >/dev/null 2>&1; then
        # Remove any previous hotspot profile to ensure updated credentials
        nmcli con down "$CON_NAME" 2>/dev/null || true
        nmcli con down Hotspot 2>/dev/null || true
        nmcli con delete "$CON_NAME" 2>/dev/null || true

        if [ -n "$HOTSPOT_PASS" ] && [ ${#HOTSPOT_PASS} -ge 8 ]; then
            echo "[*] Creating WPA2 protected hotspot..."
            nmcli con add type wifi ifname "$HOTSPOT_IFACE" con-name "$CON_NAME" autoconnect no ssid "$HOTSPOT_SSID"
            nmcli con modify "$CON_NAME" 802-11-wireless.mode ap 802-11-wireless.band bg ipv4.method shared
            nmcli con modify "$CON_NAME" wifi-sec.key-mgmt wpa-psk
            nmcli con modify "$CON_NAME" wifi-sec.psk "$HOTSPOT_PASS"
        else
            echo "[*] Creating open hotspot..."
            nmcli con add type wifi ifname "$HOTSPOT_IFACE" con-name "$CON_NAME" autoconnect no ssid "$HOTSPOT_SSID"
            nmcli con modify "$CON_NAME" 802-11-wireless.mode ap 802-11-wireless.band bg ipv4.method shared
        fi

        nmcli con up "$CON_NAME"
    elif command -v hostapd >/dev/null 2>&1; then
        echo "[*] Starting hostapd & dnsmasq services..."
        systemctl start hostapd || true
        systemctl start dnsmasq || true
    else
        echo "[WARN] Neither NetworkManager (nmcli) nor hostapd found."
    fi

    touch "$STATE_FILE"
    echo "[✓] Raspberry Pi Host mode is now ACTIVE!"
    echo "    SSID: $HOTSPOT_SSID"
    echo "    Default Gateway IP: 10.42.0.1"
}

stop_hotspot() {
    echo "=== Turning OFF Host Mode -> Returning to Normal Wi-Fi ==="
    if command -v nmcli >/dev/null 2>&1; then
        nmcli con down "$CON_NAME" 2>/dev/null || true
        nmcli con down Hotspot 2>/dev/null || true
        echo "[*] Reconnecting to normal Wi-Fi..."
        nmcli dev disconnect "$HOTSPOT_IFACE" 2>/dev/null || true
        nmcli dev connect "$HOTSPOT_IFACE" 2>/dev/null || true
    elif command -v hostapd >/dev/null 2>&1; then
        systemctl stop hostapd || true
        systemctl stop dnsmasq || true
    fi

    rm -f "$STATE_FILE"
    echo "[✓] Returned to Normal Wi-Fi mode"
}

ACTION="${1:-toggle}"

case "$ACTION" in
    on|start)
        start_hotspot
        ;;
    off|stop)
        stop_hotspot
        ;;
    status)
        if is_hotspot_active; then
            echo "active"
            exit 0
        else
            echo "inactive"
            exit 1
        fi
        ;;
    toggle)
        if is_hotspot_active; then
            stop_hotspot
        else
            start_hotspot
        fi
        ;;
    *)
        echo "Usage: $0 {on|off|toggle|status}"
        exit 1
        ;;
esac
