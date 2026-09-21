#!/bin/bash
# ==============================================================================
# Install Bluetooth Autostart Systemd Service on Raspberry Pi 4B
# ------------------------------------------------------------------------------
# Installs a systemd unit that runs auto_on_bluetooth.sh on every system boot
# so Bluetooth is always powered on, discoverable, and pairing is ready.
# ==============================================================================

set -e

if [ "$EUID" -ne 0 ]; then
    echo "Escalating to sudo..."
    exec sudo bash "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ON_SCRIPT="$SCRIPT_DIR/auto_on_bluetooth.sh"

chmod +x "$AUTO_ON_SCRIPT"

SERVICE_FILE="/etc/systemd/system/ebike-bluetooth.service"

echo "Creating systemd service at $SERVICE_FILE..."

cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Volt E-Bike Bluetooth Auto Power and Host Service
After=bluetooth.target network.target
Wants=bluetooth.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash $AUTO_ON_SCRIPT --daemon
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo "Reloading systemd daemon..."
systemctl daemon-reload

echo "Enabling ebike-bluetooth.service on boot..."
systemctl enable ebike-bluetooth.service

echo "Starting ebike-bluetooth.service now..."
systemctl start ebike-bluetooth.service || true

echo "======================================================================"
echo " Autostart successfully configured!"
echo " Bluetooth will automatically turn ON on every Raspberry Pi boot."
echo " Status check: sudo systemctl status ebike-bluetooth.service"
echo "======================================================================"
