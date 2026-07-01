#!/system/bin/sh
# wa_sd_media — service.sh
# Runs after boot (Magisk late_start service), after sdcardfs and vold are up.
#
# Technique: stacks a fresh sdcardfs instance whose lower is an ext4 partition
# on the SD card directly onto /mnt/pass_through/0/emulated/0/Android/media/com.whatsapp.
# Because pass_through is in shared peer-group-44, the new mount propagates
# automatically to all runtime/* views and the FUSE /storage/emulated path
# that WhatsApp actually reads/writes.
#
# Why not a plain bind mount into /data/media?
# sdcardfs uses lookup_one_len on its lower filesystem, which does not cross
# mountpoints into other devices. Any bind mount of an ext4 partition inside
# /data/media causes EXDEV (Cross-device link) at every sdcardfs and FUSE layer.
# Stacking a fresh sdcardfs instance on the upper path bypasses this entirely.
#
# Tested on: Samsung Galaxy S10e, OmniROM Android 12, kernel 4.14 (AmbasadiiCruel),
#            Magisk root, persist.sys.fuse=true (Android 12 FUSE mode).

LOGFILE=/data/local/tmp/wa_sd_media.log
EXT4_DEV=/dev/block/mmcblk0p2   # mmcblk0 = SD card on S10e (internal UFS = sda)
EXT4_LABEL=WA_TEST               # partition label; change to match yours
EXT4_MOUNT=/mnt/wa_ext4
APP_PKG=com.whatsapp             # change for a different app
LOWER=$EXT4_MOUNT/$APP_PKG
TARGET=/mnt/pass_through/0/emulated/0/Android/media/$APP_PKG
TIMEOUT=45

log() { echo "$(date '+%H:%M:%S') $*" >> "$LOGFILE"; }

echo "" >> "$LOGFILE"
log "=== wa_sd_media service.sh start ==="

# --- 0. Wait for boot to settle ---
# Magisk fires service.sh at sys.boot_completed=1. At that exact instant the
# shell context can be unstable (process gets killed before blkid runs).
# 15 seconds is enough for sdcardfs and vold to finish initialising.
log "Sleeping 15s for boot settle..."
sleep 15
log "Awake."

# --- 1. Wait for SD block device ---
log "Waiting for $EXT4_DEV..."
I=0
while [ $I -lt $TIMEOUT ]; do
    [ -b "$EXT4_DEV" ] && break
    sleep 1; I=$((I+1))
done
if [ ! -b "$EXT4_DEV" ]; then
    log "WARN: $EXT4_DEV not found after ${TIMEOUT}s (no SD card?) — exiting cleanly"
    exit 0
fi

# --- 2. Verify partition label ---
FOUND=$(blkid "$EXT4_DEV" 2>/dev/null | grep "LABEL=\"$EXT4_LABEL\"")
if [ -z "$FOUND" ]; then
    log "WARN: $EXT4_DEV label is not $EXT4_LABEL ($(blkid $EXT4_DEV 2>/dev/null | grep LABEL)) — exiting"
    exit 0
fi
log "Confirmed $EXT4_DEV LABEL=$EXT4_LABEL"

# --- 3. Mount ext4 (idempotent) ---
mkdir -p "$EXT4_MOUNT"
if grep -qF "$EXT4_MOUNT" /proc/self/mountinfo 2>/dev/null; then
    log "$EXT4_MOUNT already mounted"
else
    mount -t ext4 "$EXT4_DEV" "$EXT4_MOUNT" 2>>"$LOGFILE"
    if [ $? -ne 0 ]; then log "ERROR: mount $EXT4_DEV failed"; exit 1; fi
    log "Mounted $EXT4_DEV at $EXT4_MOUNT"
fi

if [ ! -d "$LOWER" ]; then
    log "ERROR: $LOWER not found on ext4 — did you copy the media? See README."; exit 1
fi

# --- 4. Wait for sdcardfs pass_through to be ready ---
log "Waiting for $TARGET..."
I=0
while [ $I -lt $TIMEOUT ]; do
    grep -qF "/mnt/pass_through/0/emulated " /proc/self/mountinfo 2>/dev/null && \
        [ -d "$TARGET" ] && break
    sleep 1; I=$((I+1))
done
if [ ! -d "$TARGET" ]; then
    log "ERROR: $TARGET not available after ${TIMEOUT}s — sdcardfs not up?"; exit 1
fi

# --- 5. Stack sdcardfs (idempotent) ---
if grep -qF "$EXT4_MOUNT/$APP_PKG" /proc/self/mountinfo 2>/dev/null; then
    log "sdcardfs stack already present — skipping"
    exit 0
fi

mount -t sdcardfs -o nosuid,nodev,noexec,noatime,mask=7,gid=9997 \
    "$LOWER" "$TARGET" 2>>"$LOGFILE"
RC=$?
if [ $RC -ne 0 ]; then
    log "ERROR: sdcardfs stack mount failed (rc=$RC)"; exit 1
fi
log "OK: sdcardfs stack $LOWER -> $TARGET (propagates to all peer-group-44 mounts)"
log "=== wa_sd_media done ==="
