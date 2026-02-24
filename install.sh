#!/bin/bash
# install.sh - Automated deployment for the PingShift Network Monitor

set -e # Exit immediately if a command fails

# ==========================================
# 0. ROOT EXECUTION CHECK
# ==========================================
if [ "$EUID" -eq 0 ]; then
    echo "❌ ERROR: Do not run this script as root or with sudo."
    echo "PingShift is a user-level daemon. It must be installed as your normal user so it can access your desktop notifications and local network manager."
    exit 1
fi

echo "Provisioning Network Monitor..."


# ==========================================
# 1. DEPENDENCY CHECK
# ==========================================
echo "Checking system dependencies..."
MISSING_DEPS=0

# Array of commands the script absolutely requires to function
REQUIRED_CMDS=("ping" "curl" "nmcli" "ip" "awk" "notify-send" "systemctl")

for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "❌ Missing critical dependency: $cmd"
        MISSING_DEPS=1
    else
        echo "✔ Found: $cmd"
    fi
done

# Optional dependency check for audio alarms
if ! command -v "paplay" >/dev/null 2>&1; then
    echo "⚠ Warning: 'paplay' not found. Critical alarms will fallback to a terminal beep."
fi

# Halt installation if any critical dependency is missing
if [ "$MISSING_DEPS" -eq 1 ]; then
    echo ""
    echo "=================================================="
    echo "❌ INSTALLATION ABORTED"
    echo "=================================================="
    echo "Please install the missing packages using your system's package manager (e.g., apt, dnf, pacman) and run ./install.sh again."
    exit 1
fi

echo "All dependencies satisfied. Proceeding with installation..."
echo ""

# ==========================================
# 2. PATH RESOLUTION & PERMISSIONS
# ==========================================
# Get the absolute path of where this repository was cloned
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SCRIPT="$SCRIPT_DIR/run.sh"

if [ -f "$RUN_SCRIPT" ]; then
    chmod +x "$RUN_SCRIPT"
    echo "✔ Set execution permissions for run.sh"
else
    echo "❌ Error: run.sh not found in $SCRIPT_DIR!"
    exit 1
fi

# ==========================================
# 3. SYSTEMD SERVICE CREATION
# ==========================================
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$SYSTEMD_USER_DIR"

SERVICE_FILE="$SYSTEMD_USER_DIR/pingshift.service"

cat << EOF > "$SERVICE_FILE"
[Unit]
Description=PingShift Network Monitor and Failover

[Service]
Type=simple
ExecStart=$RUN_SCRIPT
Restart=always
RestartSec=10
Environment="LC_ALL=C"

[Install]
WantedBy=default.target
EOF

echo "✔ Generated systemd service file at $SERVICE_FILE"

# ==========================================
# 4. DAEMON ACTIVATION
# ==========================================
systemctl --user daemon-reload
systemctl --user enable pingshift.service
systemctl --user restart pingshift.service

echo ""
echo "=================================================="
echo "🚀 INSTALLATION COMPLETE!"
echo "=================================================="
echo "The monitor is now running silently in the background."
echo "To view live logs, run:"
echo "  journalctl --user -u pingshift.service -f"
echo ""
echo "To stop the monitor, run:"
echo "  systemctl --user stop pingshift.service"