#!/system/bin/sh
# wa_sd_media — watchdog.sh
# Self-healing monitor for the sdcardfs media stack.
#
# WHY THIS EXISTS
# Samsung's "Device Care" (and some other OEM optimizers) periodically perform
# a *silent reset*: system_server and MediaProvider restart WITHOUT a kernel
# reboot (dropbox records it as "NPE by silent reset. It's normal operation
# caused by device care"). The storage mount tree is re-created, the stacked
# sdcardfs mount from service.sh vanishes, and since service.sh only runs at
# boot the app silently falls back to the internal stub folder — media appears
# "missing" while new downloads land only on the stub (split-brain).
#
# This watchdog polls /proc/1/mountinfo every INTERVAL seconds and, if the
# stack is gone:
#   1. re-mounts the ext4 partition if needed
#   2. merges any stub-only files back to the ext4 partition (cp -an —
#      additive, no-clobber; NOTHING is deleted or overwritten)
#   3. re-stacks the sdcardfs mount
#   4. logs every step to $LOGFILE
#
# Verified on Samsung Galaxy S10e, OmniROM Android 12, kernel 4.14: heal time
# after a simulated teardown was ~31s including merge-back of a probe file,
# with correct SELinux relabeling (media_rw_data_file).
#
# NOTE: must run in the GLOBAL mount namespace. service.sh (Magisk late_start)
# runs there natively. If you start it manually use `su -mm` — a plain `su`
# gets an isolated mount namespace and the heals will never reach apps.

LOGFILE=${LOGFILE:-/data/local/tmp/wa_sd_media.log}
EXT4_DEV=${EXT4_DEV:-/dev/block/mmcblk0p2}
EXT4_MOUNT=${EXT4_MOUNT:-/mnt/wa_media}
APP_PKG=${APP_PKG:-com.whatsapp}
INTERVAL=${WATCHDOG_INTERVAL:-30}

STUB=/data/media/0/Android/media/$APP_PKG
SD=$EXT4_MOUNT/$APP_PKG
TARGET=/mnt/pass_through/0/emulated/0/Android/media/$APP_PKG
STACK_NEEDLE="sdcardfs $SD"

log() { echo "$(date '+%H:%M:%S') [watchdog] $*" >> "$LOGFILE"; }

stack_present() { grep -q "$STACK_NEEDLE" /proc/1/mountinfo 2>/dev/null; }

heal() {
    log "STACK LOST — healing..."

    # 1. ensure the ext4 partition is mounted
    if ! grep -q " $EXT4_MOUNT " /proc/1/mountinfo 2>/dev/null; then
        if [ ! -b "$EXT4_DEV" ]; then
            log "cannot heal: $EXT4_DEV absent (SD card removed?)"
            return 1
        fi
        mkdir -p "$EXT4_MOUNT"
        mount -t ext4 "$EXT4_DEV" "$EXT4_MOUNT" 2>>"$LOGFILE" || {
            log "cannot heal: ext4 mount failed"; return 1; }
        log "re-mounted $EXT4_DEV at $EXT4_MOUNT"
    fi

    # 2. merge back any media that arrived on the stub while broken
    #    (additive only: cp -an never overwrites existing files)
    if [ -d "$STUB" ] && [ -d "$SD" ]; then
        T1=/data/local/tmp/.wa_wd_stub
        T2=/data/local/tmp/.wa_wd_sd
        (cd "$STUB" && find . -type f | LC_ALL=C sort) > "$T1"
        (cd "$SD" && find . -type f | LC_ALL=C sort) > "$T2"
        MISSING=$(comm -23 "$T1" "$T2" | wc -l)
        if [ "$MISSING" -gt 0 ]; then
            log "merge-back: $MISSING stub-only files -> SD"
            cp -an "$STUB/." "$SD/" 2>>"$LOGFILE"
            # cp does not carry SELinux xattrs to ext4 — relabel
            chcon -R u:object_r:media_rw_data_file:s0 "$SD" 2>>"$LOGFILE"
            log "merge-back done (no-clobber)"
        fi
        rm -f "$T1" "$T2"
    fi

    # 3. re-stack sdcardfs (propagates via the pass_through peer group)
    if stack_present; then
        log "stack reappeared externally — nothing to do"
        return 0
    fi
    mount -t sdcardfs -o nosuid,nodev,noexec,noatime,mask=7,gid=9997 \
        "$SD" "$TARGET" 2>>"$LOGFILE" || {
        log "cannot heal: sdcardfs stack mount failed"; return 1; }
    log "HEALED: sdcardfs stack $SD -> $TARGET"
    return 0
}

log "watchdog started (pid $$, interval ${INTERVAL}s)"

while true; do
    if ! stack_present; then
        sleep 3                      # debounce: don't heal on transient blips
        stack_present || heal
    fi
    sleep "$INTERVAL"
done