#!/bin/bash

# RPi 2 Maintenance Script (Headless)
# Targets: Raspbian, Pi-hole, Unbound, RPi-Monitor
# Actions: Update, Upgrade, Cleanup, Report, Reboot

# Configuration
LOG_FILE="/var/log/rpi_maintenance.log"
EMAIL_TO="nyecov@gmail.com"
UNBOUND_ROOT_HINTS="/var/lib/unbound/root.hints"
SESSION_LOG=$(mktemp)
LOCK_FILE="/var/run/rpi_maintenance.lock"
# REPLACE THIS WITH YOUR RAW GITHUB URL
UPDATE_URL="https://raw.githubusercontent.com/nyecov/Pihole_autoupdate/main/rpi_maintenance.sh"

# Status Variables
STATUS_OS="Skipped"
STATUS_PIHOLE="Skipped"
STATUS_UNBOUND="Skipped"
STATUS_RPIMONITOR="Skipped"
STATUS_CLEANUP="Skipped"
STATUS_SELF_UPDATE="Skipped"

# Ensure root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (sudo)"
    exit 1
fi

# Set PATH to ensure we find all commands
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Check dependencies
if ! command -v mail &> /dev/null; then
    echo "ERROR: 'mail' command not found. Please install mailutils or bsd-mailx."
    exit 1
fi

# Self-Update Function
self_update() {
    echo "Checking for script updates..."
    # Create a temp file for the new script
    NEW_SCRIPT=$(mktemp)
    
    # Download the script
    if wget -q -O "$NEW_SCRIPT" "$UPDATE_URL"; then
        # Check if download is valid (not empty)
        if [ -s "$NEW_SCRIPT" ]; then
            # Compare with current script
            # We filter out the UPDATE_URL line to avoid loops if you change the URL in the repo
            CURRENT_HASH=$(grep -v "UPDATE_URL=" "$0" | md5sum | awk '{print $1}')
            NEW_HASH=$(grep -v "UPDATE_URL=" "$NEW_SCRIPT" | md5sum | awk '{print $1}')
            
            if [ "$CURRENT_HASH" != "$NEW_HASH" ]; then
                echo "Update found! Installing..."
                # Preserve permissions
                chmod --reference="$0" "$NEW_SCRIPT"
                mv "$NEW_SCRIPT" "$0"
                
                echo "Restarting script..."
                STATUS_SELF_UPDATE="Updated & Restarted"
                # Exec the new script with the same arguments
                exec "$0" "$@"
            else
                echo "Script is up to date."
                STATUS_SELF_UPDATE="Up to Date"
                rm "$NEW_SCRIPT"
            fi
        else
            echo "Warning: Downloaded update file is empty."
            STATUS_SELF_UPDATE="Failed (Empty Download)"
            rm "$NEW_SCRIPT"
        fi
    else
        echo "Warning: Failed to check for updates (wget failed)."
        STATUS_SELF_UPDATE="Failed (Connection Error)"
        rm -f "$NEW_SCRIPT"
    fi
}

# Run self-update before locking
# We run this first so we don't lock the old version while trying to update
# Only run if UPDATE_URL is not the default placeholder
if [[ "$UPDATE_URL" != *"USERNAME/REPO"* ]]; then
    self_update
fi

# Lockfile mechanism
if [ -f "$LOCK_FILE" ]; then
    # Check if process is actually running
    PID=$(cat "$LOCK_FILE")
    if ps -p "$PID" > /dev/null 2>&1; then
        echo "Script is already running (PID: $PID). Exiting."
        exit 1
    else
        echo "Found stale lockfile. Removing..."
        rm -f "$LOCK_FILE"
    fi
fi

# Create lockfile
echo $$ > "$LOCK_FILE"

# Cleanup Trap
# Ensures lockfile and session log are removed on exit or interruption
cleanup() {
    rm -f "$SESSION_LOG"
    rm -f "$LOCK_FILE"
}
trap cleanup EXIT

# Set non-interactive frontend for apt
export DEBIAN_FRONTEND=noninteractive

# Start Logging
# Redirect stdout and stderr to both the main log, the session log, and the terminal
exec > >(tee -a "$LOG_FILE" "$SESSION_LOG") 2>&1

echo "==================================================="
echo " RPi Maintenance Started: $(date)"
echo "==================================================="

# 1. Update OS (Raspbian)
echo ""
echo "[1/5] Updating OS Packages..."
echo "-----------------------------"
if apt-get update; then
    # Capture the upgrade summary line (e.g., "0 upgraded, 0 newly installed...")
    # We run a dry-run first to get the stats cleanly, then the actual upgrade
    OS_CHANGES=$(apt-get dist-upgrade -s | grep -P "^\d+ upgraded, \d+ newly installed")
    
    if apt-get dist-upgrade -y; then
        STATUS_OS="Success"
    else
        STATUS_OS="Failed (Upgrade)"
    fi
else
    STATUS_OS="Failed (Update)"
fi

# 2. Update Pi-hole
echo ""
echo "[2/5] Updating Pi-hole..."
echo "-------------------------"
if command -v pihole &> /dev/null; then
    if pihole -up; then
        STATUS_PIHOLE="Success"
    else
        STATUS_PIHOLE="Failed"
    fi
else
    STATUS_PIHOLE="Not Installed"
fi

# 3. Update Unbound Root Hints
echo ""
echo "[3/5] Updating Unbound Root Hints..."
echo "------------------------------------"
if [ -d "$(dirname "$UNBOUND_ROOT_HINTS")" ]; then
    wget -q -O "$UNBOUND_ROOT_HINTS.new" https://www.internic.net/domain/named.root
    if [ -s "$UNBOUND_ROOT_HINTS.new" ]; then
        if ! cmp -s "$UNBOUND_ROOT_HINTS" "$UNBOUND_ROOT_HINTS.new"; then
            mv "$UNBOUND_ROOT_HINTS.new" "$UNBOUND_ROOT_HINTS"
            echo "Root hints updated."
            if systemctl restart unbound; then
                STATUS_UNBOUND="Updated & Restarted"
            else
                STATUS_UNBOUND="Updated but Restart Failed"
            fi
        else
            rm "$UNBOUND_ROOT_HINTS.new"
            echo "Root hints already up to date."
            STATUS_UNBOUND="Up to Date"
        fi
    else
        echo "Error: Downloaded root hints empty."
        rm "$UNBOUND_ROOT_HINTS.new"
        STATUS_UNBOUND="Failed (Empty Download)"
    fi
else
    echo "Unbound directory not found, skipping."
    STATUS_UNBOUND="Not Installed"
fi

# 4. Update RPi-Monitor
echo ""
echo "[4/5] Updating RPi-Monitor..."
echo "-----------------------------"
# Check if installed via dpkg
if dpkg -s rpimonitor &> /dev/null; then
    # Try standard command
    if command -v rpimonitor &> /dev/null; then
        if rpimonitor -u; then
            STATUS_RPIMONITOR="Success (Command)"
        else
            STATUS_RPIMONITOR="Failed (Command)"
        fi
    # Try direct script path (common in some installs)
    elif [ -x "/usr/share/rpimonitor/scripts/update_packages_status.pl" ]; then
        if /usr/share/rpimonitor/scripts/update_packages_status.pl; then
            STATUS_RPIMONITOR="Success (Script)"
        else
            STATUS_RPIMONITOR="Failed (Script)"
        fi
    else
        STATUS_RPIMONITOR="Installed (Update Cmd Missing)"
        echo "WARNING: RPi-Monitor installed but update command not found."
    fi
else
    STATUS_RPIMONITOR="Not Installed"
fi

# 5. Cleanup
echo ""
echo "[5/5] Cleaning up..."
echo "--------------------"
# Capture autoremove stats
CLEANUP_CHANGES=$(apt-get autoremove --purge -s | grep -P "^\d+ upgraded, \d+ newly installed")

if apt-get autoremove --purge -y && apt-get clean; then
    STATUS_CLEANUP="Success"
else
    STATUS_CLEANUP="Failed"
fi

echo ""
echo "==================================================="
echo " Maintenance Complete: $(date)"
echo "==================================================="

# Generate Summary Report
echo ""
echo "###################################################"
echo "                  SESSION SUMMARY                  "
echo "###################################################"
echo "OS Update:      $STATUS_OS"
echo "  Details:      ${OS_CHANGES:-No changes detected}"
echo "Pi-hole:        $STATUS_PIHOLE"
echo "Unbound:        $STATUS_UNBOUND"
echo "RPi-Monitor:    $STATUS_RPIMONITOR"
echo "Cleanup:        $STATUS_CLEANUP"
echo "  Details:      ${CLEANUP_CHANGES:-No cleanup needed}"
echo "###################################################"

# Send Email Report (Session Log Only)
SUBJECT="RPi Maintenance Report - $(date '+%Y-%m-%d') - $STATUS_OS"
cat "$SESSION_LOG" | mail -s "$SUBJECT" "$EMAIL_TO"

echo "Email report sent to $EMAIL_TO"

# Interactive Reboot Check
if [ -t 0 ]; then
    echo ""
    echo "!!! INTERACTIVE SESSION DETECTED !!!"
    read -t 10 -n 1 -s -r -p "System will reboot in 10 seconds. Press ANY KEY to CANCEL reboot..."
    if [ $? -eq 0 ]; then
        echo -e "\n\nReboot canceled by user."
        echo "Exiting."
        exit 0
    fi
    echo -e "\n\nTimeout reached. Rebooting..."
else
    echo "Running non-interactively. Auto-rebooting in 5 seconds..."
    sleep 5
fi

# Safe Reboot
sync
shutdown -r now
