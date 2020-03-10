#!/bin/bash

KEEP_DAYS=1
VG="debian" # LVM volume group we are snapshoting
LV="home_luks" # Name of LVM-volume to take a snapshot of
BACKUP_PREFIX="home_luks_snapshot-" # Prefix of snapshot volume name.
SIZE=25G # Amount of disk space to allocate for the snapshot


# Create new snapshot
TODAY="$(date +%F)"
NEW_VOLUME="$BACKUP_PREFIX$TODAY"
if ! lvs | grep -q -F "$NEW_VOLUME"; then
    /sbin/lvcreate --size $SIZE --permission r --snapshot "$VG/$LV" --name "$NEW_VOLUME" /dev/disk/by-id/lvm-pv-uuid-qSoZUN-KWIi-ncSJ-5Gva-6GYd-zNmV-qnQ8ub
else
    echo "Backup already exists: $NEW_VOLUME"
fi

# Clean old snapshots.

# We need to work around debian bug #659762
# See: http://bugs.debian.org/cgi-bin/bugreport.cgi?bug=659762
# We do that by disabling udev while removing snapshots
if service udev status >/dev/null 2>&1; then
    UDEV_RUNNING=1
    service udev stop >/dev/null 2>&1
else
    UDEV_RUNNING=0
fi

lvs -o lv_name --noheadings | sed -n "s@$BACKUP_PREFIX@@p" | while read DATE; do
    TS_DATE=$(date -d "$DATE" +%s)
    TS_NOW=$(date +%s)
    AGE=$(( (TS_NOW - TS_DATE) / 86400))
    if [ "$AGE" -ge "$KEEP_DAYS" ]; then
        VOLNAME="$BACKUP_PREFIX$DATE"
        /sbin/lvremove -f "$VG/$VOLNAME"
    fi
done

if [ "$UDEV_RUNNING" = "1" ]; then
    service udev start >/dev/null 2>&1
fi
