#!/system/bin/sh
# uninstall.sh — runs when the module is removed. Undo the bind in MediaProvider's namespace and
# release the ext4 mount. The SD card data is left exactly as it is.

LOGFILE=/data/local/tmp/wa_sd_media.log
EXT4_MOUNT=/mnt/wa_media
APP_PKG=com.whatsapp
FUSE_TARGET=/storage/emulated/0/Android/media/$APP_PKG
MP_PROCS="com.google.android.providers.media.module com.android.providers.media.module"

log() { echo "$(date '+%H:%M:%S') $*" >> "$LOGFILE"; }
log "=== wa_sd_media uninstall ==="

for p in $MP_PROCS; do
    pid=$(pgrep -f "$p" 2>/dev/null | head -1)
    [ -n "$pid" ] || continue
    nsenter -t "$pid" -m -- sh -c "umount '$FUSE_TARGET' 2>/dev/null" >>"$LOGFILE" 2>&1
    log "unmounted $FUSE_TARGET in ns of pid $pid"
done

umount "$EXT4_MOUNT" 2>/dev/null && log "unmounted $EXT4_MOUNT"
log "=== done (SD data untouched) ==="
