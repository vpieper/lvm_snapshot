#!/bin/bash
set -euo pipefail

# Silence LVM warnings about the flock file descriptor
export LVM_SUPPRESS_FD_WARNINGS=1

KEEP_DAYS=1
VG="debian"
LV="home_luks"
BACKUP_PREFIX="home_luks_snapshot-"
SIZE="40G"
ADMIN_EMAIL=".........." # Change this to your actual email/alias

# 1. Operational Safety Nets: Root Check & Singleton Lock
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

# Prevent concurrent runs using flock (File descriptor 200)
exec 200>"/var/lock/lvm_snap_${LV}.lock"
if ! flock -n 200; then
    echo "ERROR: Script is already running." >&2
    exit 1
fi

# 2. Logging and Alerting
log() {
    # Logs to standard output AND to the systemd journal/syslog
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $*"
    logger -t lvm-snapshot-script "$*"
}

# If any command fails (triggering set -e), this trap catches it and sends an email
error_handler() {
    local line=$1
    log "CRITICAL ERROR: Script failed at line ${line}."
    echo "LVM Snapshot script failed on $(hostname) for volume ${VG}/${LV} at line ${line}." | mail -s "URGENT: LVM Snapshot Failed" "${ADMIN_EMAIL}"
}
trap 'error_handler $LINENO' ERR


# 3. Snapshot Health Check (Claude's excellent suggestion)
# Check if any existing snapshots are marked 'Invalid' (usually meaning they ran out of space)
# The 5th character of lv_attr is 'I' or 'i' if the snapshot is invalid.
log "Performing health check on existing snapshots..."
/sbin/lvs -o lv_name,lv_attr --noheadings "${VG}" | awk -v pref="${BACKUP_PREFIX}" '$1 ~ "^"pref {print $1, $2}' | while read -r SNAP_NAME SNAP_ATTR; do
    # Check if the 5th character of the attribute string is 'I' or 'i'
    if [[ "${SNAP_ATTR:4:1}" =~ [Ii] ]]; then
        log "WARNING: Snapshot ${SNAP_NAME} is INVALID (likely out of space). It is no longer protecting data."
        echo "Snapshot ${SNAP_NAME} on $(hostname) has been dropped by LVM and is invalid. Consider increasing snapshot SIZE." | mail -s "WARNING: Invalid LVM Snapshot" "${ADMIN_EMAIL}"
    fi
done


# 4. Create new snapshot
TODAY="$(date +%F)"
NEW_VOLUME="${BACKUP_PREFIX}${TODAY}"

if /sbin/lvs "${VG}/${NEW_VOLUME}" >/dev/null 2>&1; then
    log "Backup already exists for today: ${NEW_VOLUME}"
else
    log "Creating new snapshot: ${NEW_VOLUME}"
    /sbin/lvcreate --size "${SIZE}" --permission r --snapshot "${VG}/${LV}" --name "${NEW_VOLUME}"
fi


# 5. Clean old snapshots
CUTOFF_TS=$(date -d "${TODAY} - ${KEEP_DAYS} days" +%s)

# FIX: Replaced grep with awk's internal regex matching to bypass the pipefail landmine.
# If no matching volumes exist, awk safely exits 0.
/sbin/lvs -o lv_name --noheadings "${VG}" | awk -v pref="${BACKUP_PREFIX}" '$1 ~ "^"pref {print $1}' | while read -r VOLNAME; do

    DATE_STR="${VOLNAME#$BACKUP_PREFIX}"

    if TS_DATE=$(date -d "${DATE_STR}" +%s 2>/dev/null); then
        if [ "${TS_DATE}" -le "${CUTOFF_TS}" ]; then
            log "Removing old snapshot: ${VOLNAME}"
            /sbin/lvremove -y -f "${VG}/${VOLNAME}"
        fi
    else
        log "Warning: Could not parse a valid date from volume name ${VOLNAME}"
    fi
done

log "Snapshot rotation completed successfully."
