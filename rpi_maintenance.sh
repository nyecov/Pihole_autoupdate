#!/bin/bash

# RPi 2 Maintenance Script (Headless)
# Targets: Raspbian, Pi-hole, Unbound, RPi-Monitor
# Actions: Update, Upgrade, Cleanup, Report, Reboot

# ==============================================================================
# Configuration
# ==============================================================================
LOG_FILE="/var/log/rpi_maintenance.log"
EMAIL_TO="nyecov@gmail.com"
UNBOUND_ROOT_HINTS="/var/lib/unbound/root.hints"
SESSION_LOG=$(mktemp)
LOCK_FILE="/var/run/rpi_maintenance.lock"
# REPLACE THIS WITH YOUR RAW GITHUB URL
UPDATE_URL="https://raw.githubusercontent.com/nyecov/Pihole_autoupdate/main/rpi_maintenance.sh"
SCRIPT_VERSION="2025112504"
BACKUP_DIR="/home/pihole/backups"

# ==============================================================================
# Global Status Variables
# ==============================================================================
STATUS_OS="Skipped"
STATUS_PIHOLE="Skipped"
STATUS_UNBOUND="Skipped"
STATUS_RPIMONITOR="Skipped"
STATUS_CLEANUP="Skipped"
STATUS_SELF_UPDATE="Skipped"
STATUS_HEALTH_SERVICES="Skipped"
STATUS_HEALTH_DNS="Skipped"
STATUS_BACKUP="Skipped"

# Flags
SKIP_REBOOT=false
VERBOSE=false

# ==============================================================================
# Helper Functions
# ==============================================================================

log_info() {
    echo "[INFO] $1"
}

log_warn() {
    echo "[WARN] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
}

log_section() {
    echo ""
    echo "==================================================="
    echo " $1"
    echo "==================================================="
}

run_quietly() {
    if [ "$VERBOSE" = true ]; then
        "$@"
    else
        "$@" &> /dev/null
    fi
}

show_help() {
    echo "Usage: sudo $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -u, --update-only   Check for script updates and exit."
    echo "  -v, --version       Show script version and exit."
    echo "  --no-reboot         Skip the final system reboot."
    echo "  --verbose           Enable detailed output."
    echo "  -h, --help          Show this help message and exit."
    echo ""
    echo "Description:"
    echo "  Automated maintenance script for Raspberry Pi."
    echo "  Updates OS, Pi-hole, Unbound, RPi-Monitor, cleans up system,"
    echo "  performs health checks, and emails a report."
}

check_root() {
    if [ "$EUID" -ne 0 ]; then 
        log_error "Please run as root (sudo)"
        exit 1
    fi
}

check_dependencies() {
    # Set PATH to ensure we find all commands
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    
    if ! command -v mail &> /dev/null; then
        log_error "'mail' command not found. Please install mailutils or bsd-mailx."
        exit 1
    fi
}

cleanup() {
    rm -f "$SESSION_LOG"
    # Only remove lockfile if we own it
    if [ -f "$LOCK_FILE" ]; then
        if [ "$(cat "$LOCK_FILE")" == "$$" ]; then
            rm -f "$LOCK_FILE"
        fi
    fi
}

manage_lockfile() {
    if [ -f "$LOCK_FILE" ]; then
        PID=$(cat "$LOCK_FILE")
        if ps -p "$PID" > /dev/null 2>&1; then
            log_error "Script is already running (PID: $PID). Exiting."
            exit 1
        else
            log_warn "Found stale lockfile. Removing..."
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

rotate_logs() {
    MAX_SIZE=1048576 # 1MB
    if [ -f "$LOG_FILE" ]; then
        FILE_SIZE=$(stat -c%s "$LOG_FILE")
        if [ "$FILE_SIZE" -ge "$MAX_SIZE" ]; then
            log_info "Log file too large ($FILE_SIZE bytes). Rotating..."
            mv "$LOG_FILE" "${LOG_FILE}.old"
            touch "$LOG_FILE"
            chmod 644 "$LOG_FILE"
        fi
    fi
}

# ==============================================================================
# Feature Functions
# ==============================================================================

check_connectivity() {
    log_info "Checking internet connectivity..."
    if ! run_quietly ping -c 1 8.8.8.8; then
        log_error "No internet connection. Exiting."
        exit 1
    fi
}

check_disk_space() {
    log_info "Checking disk space..."
    AVAILABLE_KB=$(df / | tail -1 | awk '{print $4}')
    MIN_KB=512000 # 500MB
    
    if [ "$AVAILABLE_KB" -lt "$MIN_KB" ]; then
        log_error "Insufficient disk space. Available: $((AVAILABLE_KB/1024))MB, Required: 500MB."
        exit 1
    fi
}

self_update() {
    # Only run if UPDATE_URL is configured
    if [[ "$UPDATE_URL" == *"USERNAME/REPO"* ]]; then return; fi

    log_info "Checking for script updates..."
    NEW_SCRIPT=$(mktemp)
    
    WGET_ARGS="-q"
    if [ "$VERBOSE" = true ]; then WGET_ARGS=""; fi

    if wget $WGET_ARGS -O "$NEW_SCRIPT" "$UPDATE_URL"; then
        if [ -s "$NEW_SCRIPT" ]; then
            REMOTE_VERSION=$(grep "^SCRIPT_VERSION=" "$NEW_SCRIPT" | cut -d'"' -f2)
            
            if [ -z "$REMOTE_VERSION" ]; then
                log_warn "No version found in remote script. Skipping update."
                STATUS_SELF_UPDATE="Failed (No Version Tag)"
                rm "$NEW_SCRIPT"
                return
            fi
            
            log_info "Local Version:  $SCRIPT_VERSION"
            log_info "Remote Version: $REMOTE_VERSION"
            
            if [ "$REMOTE_VERSION" -gt "$SCRIPT_VERSION" ]; then
                log_info "New version found! Installing..."
                chmod --reference="$0" "$NEW_SCRIPT"
                mv "$NEW_SCRIPT" "$0"
                log_info "Restarting script..."
                STATUS_SELF_UPDATE="Updated ($SCRIPT_VERSION -> $REMOTE_VERSION) & Restarted"
                exec "$0" "$@"
            else
                log_info "Script is up to date."
                STATUS_SELF_UPDATE="Up to Date ($SCRIPT_VERSION)"
                rm "$NEW_SCRIPT"
            fi
        else
            log_warn "Downloaded update file is empty."
            STATUS_SELF_UPDATE="Failed (Empty Download)"
            rm "$NEW_SCRIPT"
        fi
    else
        log_warn "Failed to check for updates (wget failed)."
        STATUS_SELF_UPDATE="Failed (Connection Error)"
        rm -f "$NEW_SCRIPT"
    fi
}

update_os() {
    log_section "1. Updating OS Packages"
    if apt-get update; then
        OS_CHANGES=$(apt-get dist-upgrade -s | grep -P "^\d+ upgraded, \d+ newly installed")
        if apt-get dist-upgrade -y; then
            STATUS_OS="Success"
        else
            STATUS_OS="Failed (Upgrade)"
        fi
    else
        STATUS_OS="Failed (Update)"
    fi
}

update_pihole() {
    log_section "2. Updating Pi-hole"
    if command -v pihole &> /dev/null; then
        # Backup
        log_info "Creating Teleporter Backup..."
        mkdir -p "$BACKUP_DIR"
        if pihole -a -t "$BACKUP_DIR/pihole-backup-$(date +%Y%m%d).tar.gz"; then
            STATUS_BACKUP="Success"
            ls -t "$BACKUP_DIR"/pihole-backup-*.tar.gz | tail -n +6 | xargs -r rm --
        else
            STATUS_BACKUP="Failed"
            log_warn "Pi-hole backup failed."
        fi

        # Update
        if pihole -up; then
            log_info "Updating Gravity (Blocklists)..."
            if pihole -g; then
                STATUS_PIHOLE="Success (Core & Gravity)"
            else
                STATUS_PIHOLE="Success (Core) / Failed (Gravity)"
            fi
        else
            STATUS_PIHOLE="Failed"
        fi
    else
        STATUS_PIHOLE="Not Installed"
    fi
}

update_unbound() {
    log_section "3. Updating Unbound Root Hints"
    if [ -d "$(dirname "$UNBOUND_ROOT_HINTS")" ]; then
        WGET_ARGS="-q"
        if [ "$VERBOSE" = true ]; then WGET_ARGS=""; fi
        
        wget $WGET_ARGS -O "$UNBOUND_ROOT_HINTS.new" https://www.internic.net/domain/named.root
        if [ -s "$UNBOUND_ROOT_HINTS.new" ]; then
            if ! cmp -s "$UNBOUND_ROOT_HINTS" "$UNBOUND_ROOT_HINTS.new"; then
                mv "$UNBOUND_ROOT_HINTS.new" "$UNBOUND_ROOT_HINTS"
                log_info "Root hints updated."
                if systemctl restart unbound; then
                    STATUS_UNBOUND="Updated & Restarted"
                else
                    STATUS_UNBOUND="Updated but Restart Failed"
                fi
            else
                rm "$UNBOUND_ROOT_HINTS.new"
                log_info "Root hints already up to date."
                STATUS_UNBOUND="Up to Date"
            fi
        else
            log_error "Downloaded root hints empty."
            rm "$UNBOUND_ROOT_HINTS.new"
            STATUS_UNBOUND="Failed (Empty Download)"
        fi
    else
        log_warn "Unbound directory not found, skipping."
        STATUS_UNBOUND="Not Installed"
    fi
}

update_rpimonitor() {
    log_section "4. Updating RPi-Monitor"
    if dpkg -s rpimonitor &> /dev/null; then
        if command -v rpimonitor &> /dev/null; then
            if rpimonitor -u; then
                STATUS_RPIMONITOR="Success (Command)"
            else
                STATUS_RPIMONITOR="Failed (Command)"
            fi
        elif [ -x "/usr/share/rpimonitor/scripts/update_packages_status.pl" ]; then
            if /usr/share/rpimonitor/scripts/update_packages_status.pl; then
                STATUS_RPIMONITOR="Success (Script)"
            else
                STATUS_RPIMONITOR="Failed (Script)"
            fi
        else
            STATUS_RPIMONITOR="Installed (Update Cmd Missing)"
            log_warn "RPi-Monitor installed but update command not found."
        fi
    else
        STATUS_RPIMONITOR="Not Installed"
    fi
}

system_cleanup() {
    log_section "5. Cleaning up"
    CLEANUP_SUCCESS=true
    
    CLEANUP_OUTPUT=$(apt-get autoremove --purge -y 2>&1)
    if [ $? -ne 0 ]; then CLEANUP_SUCCESS=false; fi
    
    apt-get clean
    
    log_info "Vacuuming systemd journal (keeping 7 days)..."
    journalctl --vacuum-time=7d
    if [ $? -ne 0 ]; then CLEANUP_SUCCESS=false; fi

    if [ "$CLEANUP_SUCCESS" = true ]; then
        STATUS_CLEANUP="Success"
        REMOVED_COUNT=$(echo "$CLEANUP_OUTPUT" | grep -c "Removing")
        CLEANUP_CHANGES="$REMOVED_COUNT packages removed"
    else
        STATUS_CLEANUP="Failed"
    fi
}

health_checks() {
    log_section "6. Post-Update Health Checks"
    
    # Service Checks
    FAILED_SERVICES=""
    for SERVICE in pihole-FTL unbound rpimonitor; do
        if systemctl is-active --quiet "$SERVICE"; then
            log_info "Service '$SERVICE': OK"
        else
            log_error "Service '$SERVICE': FAILED"
            FAILED_SERVICES="$FAILED_SERVICES $SERVICE"
        fi
    done

    if [ -z "$FAILED_SERVICES" ]; then
        STATUS_HEALTH_SERVICES="All OK"
    else
        STATUS_HEALTH_SERVICES="Failed: $FAILED_SERVICES"
    fi

    # DNS Check
    if command -v dig &> /dev/null; then
        if dig @127.0.0.1 google.com +short +time=2 > /dev/null; then
            STATUS_HEALTH_DNS="OK (Resolved via Localhost)"
        else
            STATUS_HEALTH_DNS="Failed (Dig Resolution Error)"
        fi
    elif command -v nslookup &> /dev/null; then
        if nslookup google.com 127.0.0.1 > /dev/null; then
            STATUS_HEALTH_DNS="OK (Resolved via Localhost)"
        else
            STATUS_HEALTH_DNS="Failed (Nslookup Resolution Error)"
        fi
    else
        STATUS_HEALTH_DNS="Skipped (No DNS tools found)"
    fi
    log_info "DNS Check: $STATUS_HEALTH_DNS"
}

send_report() {
    log_section "Generating Report"
    
    # Generate Summary
    {
        echo ""
        echo "###################################################"
        echo "                  SESSION SUMMARY                  "
        echo "###################################################"
        echo "OS Update:      $STATUS_OS"
        echo "  Details:      ${OS_CHANGES:-No changes detected}"
        echo "Pi-hole:        $STATUS_PIHOLE"
        echo "  Backup:       $STATUS_BACKUP"
        echo "Unbound:        $STATUS_UNBOUND"
        echo "RPi-Monitor:    $STATUS_RPIMONITOR"
        echo "Cleanup:        $STATUS_CLEANUP"
        echo "  Details:      ${CLEANUP_CHANGES:-No cleanup needed}"
        echo "---------------------------------------------------"
        echo "Health Checks:"
        echo "  Services:     $STATUS_HEALTH_SERVICES"
        echo "  DNS:          $STATUS_HEALTH_DNS"
        echo "###################################################"
    } | tee -a "$SESSION_LOG"

    # Send Email
    SUBJECT="RPi Maintenance Report - $(date '+%Y-%m-%d') - $STATUS_OS"
    cat "$SESSION_LOG" | mail -s "$SUBJECT" "$EMAIL_TO"
    log_info "Email report sent to $EMAIL_TO"
}

perform_reboot() {
    if [ "$SKIP_REBOOT" = true ]; then
        log_info "Skipping reboot as requested."
        return
    fi

    if [ -t 0 ]; then
        echo ""
        log_warn "!!! INTERACTIVE SESSION DETECTED !!!"
        read -t 10 -n 1 -s -r -p "System will reboot in 10 seconds. Press ANY KEY to CANCEL reboot..."
        if [ $? -eq 0 ]; then
            echo -e "\n\nReboot canceled by user."
            log_info "Exiting."
            exit 0
        fi
        echo -e "\n\nTimeout reached. Rebooting..."
    else
        log_info "Running non-interactively. Auto-rebooting in 5 seconds..."
        sleep 5
    fi

    sync
    shutdown -r now
}

parse_arguments() {
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            -u|--update-only)
                UPDATE_ONLY=true
                ;;
            -v|--version)
                echo "RPi Maintenance Script v$SCRIPT_VERSION"
                exit 0
                ;;
            --no-reboot)
                SKIP_REBOOT=true
                ;;
            --verbose)
                VERBOSE=true
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                echo "Unknown parameter passed: $1"
                show_help
                exit 1
                ;;
        esac
        shift
    done
}

# ==============================================================================
# Main Execution
# ==============================================================================

# 1. Initialization
parse_arguments "$@"

check_root
check_dependencies
trap cleanup EXIT
check_connectivity
self_update

if [ "$UPDATE_ONLY" = true ]; then
    log_info "Update-only mode requested. Script is up to date. Exiting."
    exit 0
fi

manage_lockfile
export DEBIAN_FRONTEND=noninteractive

# 2. Start Logging
rotate_logs
exec > >(tee -a "$LOG_FILE" "$SESSION_LOG") 2>&1

log_section "RPi Maintenance Started: $(date)"

# 3. Pre-flight
check_disk_space

# 4. Updates
update_os
update_pihole
update_unbound
update_rpimonitor

# 5. Cleanup
system_cleanup

# 6. Verification
health_checks

# 7. Reporting & Exit
send_report
perform_reboot
