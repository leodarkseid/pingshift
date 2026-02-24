#!/bin/bash
# uninstall.sh - Automated removal for the PingShift Network Monitor

set -e # Exit immediately if a command fails

# ==========================================
# 0. ROOT EXECUTION CHECK
# ==========================================
if [ "$EUID" -eq 0 ]; then
    echo "❌ ERROR: Do not run this script as root or with sudo."
    echo "PingShift is a user-level daemon. It must be uninstalled as your normal user."
    exit 1
fi

echo "Removing PingShift Network Monitor..."

# ==========================================
# 1. STOP & DISABLE DAEMON
# ==========================================
# We use || true so the script doesn't crash if the service is already stopped/disabled
echo "Stopping background service..."
command -v systemctl >/dev/null 2>&1 && systemctl --user stop pingshift.service 2>/dev/null || true

echo "Disabling autostart..."
command -v systemctl >/dev/null 2>&1 && systemctl --user disable pingshift.service 2>/dev/null || true

# ==========================================
# 2. REMOVE FILES
# ==========================================
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE_FILE="$SYSTEMD_USER_DIR/pingshift.service"

if [ -f "$SERVICE_FILE" ]; then
    rm -f "$SERVICE_FILE"
    echo "✔ Removed systemd service file: $SERVICE_FILE"
else
    echo "⚠ Service file not found. It may have already been removed."
fi

# ==========================================
# 3. RELOAD SYSTEMD
# ==========================================
# Tell systemd to flush the deleted service from its memory
# Tell systemd to flush the deleted service from its memory
command -v systemctl >/dev/null 2>&1 && systemctl --user daemon-reload || true
echo "✔ Systemd daemon reloaded."

# Clear the systemd failure state just in case
command -v systemctl >/dev/null 2>&1 && systemctl --user reset-failed 2>/dev/null || true


echo ""
echo "=================================================="
echo "🗑️ UNINSTALLATION COMPLETE"
echo "=================================================="
echo "PingShift has been cleanly removed from your system."
echo "You can now safely delete this project folder."