#!/bin/bash
# ==============================================================================
# Raspberry Pi 4B Bluetooth BLE Host Setup Script
# Configures BlueZ, installs required D-Bus packages, and enables BLE services.
# ==============================================================================

set -e

echo "=== [1/4] Installing BlueZ, Python D-Bus & GObject libraries ==="
sudo apt-get update
sudo apt-get install -y bluez bluez-tools python3-dbus python3-gi python3-pip
pip3 install websockets --break-system-packages || pip3 install websockets || true

echo "=== [2/4] Configuring BlueZ experimental mode for BLE Peripheral support ==="
# Enable experimental flag in bluetooth.service if not already enabled
if ! grep -q -- "--experimental" /lib/systemd/system/bluetooth.service; then
    echo "Adding --experimental flag to bluetooth.service..."
    sudo sed -i 's|ExecStart=/usr/lib/bluetooth/bluetoothd|ExecStart=/usr/lib/bluetooth/bluetoothd --experimental|g' /lib/systemd/system/bluetooth.service
    sudo systemctl daemon-reload
fi

echo "=== [3/4] Restarting Bluetooth service and powering adapter ==="
sudo systemctl restart bluetooth
sudo rfkill unblock bluetooth || true
sudo hciconfig hci0 up || true
sudo bluetoothctl power on
sudo bluetoothctl discoverable on
sudo bluetoothctl pairable on

echo "=== [4/4] Setting permissions for Bluetooth socket ==="
sudo usermod -a -G bluetooth "$USER"

echo ""
echo "======================================================================"
echo " Bluetooth Host Setup Complete on Raspberry Pi 4B!"
echo " To start the BLE Host daemon alongside the display app, run:"
echo "   python3 display/ebike_bluetooth_host.py"
echo "======================================================================"
