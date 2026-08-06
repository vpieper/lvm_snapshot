#!/bin/bash
set -euo pipefail

KEEP_DAYS=1
VG="debian"
LV="home_luks"
BACKUP_PREFIX="home_luks_snapshot-"
SIZE="40G"

# Basic logging function
log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $*"
}

TODAY="$(date +%F)"
NEW_VOLUME="${BACKUP_PREFIX}${TODAY}"

# 1. Create new snapshot
# Check directly if the exact volume exists rather than grepping all volumes
if /sbin/lvs "${VG}/${NEW_VOLUME}" >/dev/null 2>&1; then
    log "Backup already exists: ${NEW_VOLUME}"
else
    log "Creating new snapshot: ${NEW_VOLUME}"
    /sbin/lvcreate --size "${SIZE}" --permission r --snapshot "${VG}/${LV}" --name "${NEW_VOLUME}"
fi

# 2. Clean old snapshots
# Calculate the cutoff timestamp (at midnight) to avoid 86400-second DST bugs
CUTOFF_TS=$(date -d "${TODAY} - ${KEEP_DAYS} days" +%s)

# Use awk to grab just the volume name, ignoring other lvs output
/sbin/lvs -o lv_name --noheadings "${VG}" | awk '{print $1}' | grep "^${BACKUP_PREFIX}" | while read -r VOLNAME; do
    
    # Strip the prefix to isolate the date string
    DATE_STR="${VOLNAME#$BACKUP_PREFIX}"
    
    # Safely attempt to parse the date from the volume name
    if TS_DATE=$(date -d "${DATE_STR}" +%s 2>/dev/null); then
        
        # If the snapshot's date is older than or equal to the cutoff
        if [ "${TS_DATE}" -le "${CUTOFF_TS}" ]; then
            log "Removing old snapshot: ${VOLNAME}"
            # -y confirms the prompt silently
            /sbin/lvremove -y -f "${VG}/${VOLNAME}"
        fi
    else
        log "Warning: Could not parse a valid date from volume name ${VOLNAME}"
    fi
done
