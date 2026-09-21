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

# Ensure running with sudo
if [ "$EUID" -ne 0 ]; then
    echo "[!] Requesting root privileges..."
    exec sudo bash "$0" "$@"
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

systemctl daemon-reload || true
systemctl enable bluetooth.service
systemctl restart bluetooth.service

sleep 1

echo "=== [3/4] Bringing up adapter and setting discoverable/pairable ==="
if command -v hciconfig >/dev/null 2>&1; then
    hciconfig hci0 up || true
fi

bluetoothctl power on || true
bluetoothctl discoverable-timeout 0 || true
bluetoothctl discoverable on || true
bluetoothctl pairable on || true
bluetoothctl system-alias "Volt-EBike-RPI4" || true

echo "=== [4/4] Current Bluetooth Status ==="
bluetoothctl show | grep -E "Controller|Name|Alias|Powered|Discoverable|Pairable" || true

echo ""
echo "======================================================================"
echo " [✓] Bluetooth is now ON and will automatically turn ON on every boot!"
echo "======================================================================"
