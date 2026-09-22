#!/bin/bash
# ==============================================================================
# Automatically Turn ON Bluetooth on Raspberry Pi 4B
# ------------------------------------------------------------------------------
# 1. Sets AutoEnable=true in /etc/bluetooth/main.conf (permanent hardware boot)
# 2. Unblocks rfkill
# 3. Enables and starts bluetooth.service
# 4. Powers on adapter and sets discoverable & pairable
# ==============================================================================

set -e

# User credentials
USER_NAME="${EBIKE_USER:-ebike}"
USER_PASS="${EBIKE_PASS:-123}"

# Ensure running with sudo / root privileges automatically using credentials
if [ "$EUID" -ne 0 ]; then
    echo "[!] Requesting root privileges for user '$USER_NAME'..."
    if command -v sudo >/dev/null 2>&1; then
        echo "$USER_PASS" | sudo -S bash "$0" "$@"
        exit $?
    else
        echo "[ERROR] 'sudo' not found. Please run this script as root." >&2
        exit 1
    fi
fi

echo "=== [1/4] Configuring BlueZ to automatically power ON at boot ==="
MAIN_CONF="/etc/bluetooth/main.conf"
if [ -f "$MAIN_CONF" ]; then
    # Ensure [Policy] section exists and AutoEnable=true is enabled
    if grep -q "^\[Policy\]" "$MAIN_CONF"; then
        if grep -q "^AutoEnable" "$MAIN_CONF"; then
            sed -i 's/^AutoEnable.*/AutoEnable=true/' "$MAIN_CONF"
        else
            sed -i '/^\[Policy\]/a AutoEnable=true' "$MAIN_CONF"
        fi
    else
        echo -e "\n[Policy]\nAutoEnable=true" >> "$MAIN_CONF"
    fi
    echo "[✓] AutoEnable=true set in $MAIN_CONF"
fi

echo "=== [2/4] Unblocking rfkill and restarting Bluetooth service ==="
rfkill unblock bluetooth || true
rfkill unblock all || true

# Ensure user is in bluetooth group for non-root access
if id "$USER_NAME" >/dev/null 2>&1; then
    usermod -a -G bluetooth "$USER_NAME" || true
    echo "[✓] User '$USER_NAME' added to 'bluetooth' group"
fi

systemctl daemon-reload || true
systemctl enable bluetooth.service
systemctl restart bluetooth.service

sleep 1

echo "=== [3/4] Bringing up adapter and setting discoverable/pairable ==="
if command -v hciconfig >/dev/null 2>&1; then
    hciconfig hci0 up || true
fi

if command -v btmgmt >/dev/null 2>&1; then
    btmgmt --index 0 power on || true
    btmgmt --index 0 le on || true
    btmgmt --index 0 connectable on || true
    btmgmt --index 0 advertising on || true
fi

bluetoothctl power on || true
# 300s (5 min) pairing window on boot avoids the BlueZ "discoverable-timeout 0 not recommended" warning.
# Note: Paired phones reconnect anytime even when discoverable mode times out.
bluetoothctl discoverable-timeout 300 || true
bluetoothctl discoverable on || true
bluetoothctl pairable on || true
bluetoothctl system-alias "Volt-EBike-RPI4" || true

echo "=== [4/4] Starting E-Bike BLE GATT Host Daemon ==="
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Verify Python requirements
if ! python3 -c "import dbus, gi" >/dev/null 2>&1; then
    echo "[!] Installing missing Python D-Bus & GObject libraries..."
    apt-get update && apt-get install -y python3-dbus python3-gi || true
fi

if ! python3 -c "import websockets" >/dev/null 2>&1; then
    echo "[!] Installing python websockets library..."
    pip3 install websockets 2>/dev/null || apt-get install -y python3-websockets 2>/dev/null || true
fi

if ! pgrep -f "ebike_bluetooth_host.py" >/dev/null 2>&1; then
    echo "[*] Launching E-Bike BLE GATT Host Daemon in background..."
    nohup python3 "$SCRIPT_DIR/ebike_bluetooth_host.py" > /tmp/ebike_ble.log 2>&1 &
    sleep 2
    if pgrep -f "ebike_bluetooth_host.py" >/dev/null 2>&1; then
        echo "[✓] BLE GATT Host Daemon active"
    else
        echo "[ERROR] BLE Host Daemon failed to start. Log output:"
        cat /tmp/ebike_ble.log 2>/dev/null || true
    fi
else
    echo "[✓] BLE GATT Host Daemon is already running."
fi

echo "=== Current Bluetooth Status ==="
bluetoothctl show | grep -E "Controller|Name|Alias|Powered|Discoverable|Pairable" || true

echo ""
echo "======================================================================"
echo " [✓] Bluetooth is now ON and BLE Host is advertising Volt-EBike-RPI4!"
echo "======================================================================"
