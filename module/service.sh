#!/system/bin/sh
# wa_sd_media — service.sh
# Offload an app's Android/media folder to an ext4 partition on the SD card.
#
# Two techniques, auto-selected by whether the kernel has sdcardfs:
#
#   * sdcardfs devices (Android 10-12): stack a fresh sdcardfs instance whose lower is the SD
#     ext4 partition onto /mnt/pass_through/0/emulated/0/Android/media/<pkg>. pass_through is in
#     a shared mount peer group, so the mount propagates to all runtime views and to the FUSE
#     /storage/emulated path apps read. The stack is global and persistent, so no repair is needed.
#     (A plain bind into /data/media cannot work: sdcardfs's lookup_one_len does not cross mounts
#     into another device, so it returns EXDEV at every layer.)
#
#   * pure-FUSE devices (Android 13+): no sdcardfs. MediaProvider serves /storage/emulated from
#     its own mount namespace, where /storage/emulated is the raw backing fs. We bind the SD tree
#     INSIDE that namespace with nsenter.
#
# Verified: Samsung Galaxy S10e / Ambasadii ROM (Android 12, OneUI 4.1) / kernel 4.14 (sdcardfs path);
#           Sony Xperia 10 VII (pdx257) / stock Android 16 / kernel 6.6 (pure-FUSE path).

MODDIR=/data/adb/modules/wa_sd_media
[ -d "$MODDIR" ] || MODDIR=${0%/*}

LOGFILE=/data/local/tmp/wa_sd_media.log
EXT4_LABEL=WA_MEDIA                       # must match, else we abort (wrong/no card)
EXT4_MOUNT=/mnt/wa_media
# partition candidates searched in order (pdx257 SD = mmcblk1, S10e SD = mmcblk0)
EXT4_DEV_CANDIDATES="/dev/block/mmcblk1p2 /dev/block/mmcblk0p2"
APP_PKG=com.whatsapp
LOWER=$EXT4_MOUNT/$APP_PKG
SDCARD_TARGET=/mnt/pass_through/0/emulated/0/Android/media/$APP_PKG
FUSE_DIR=/storage/emulated/0/Android/media/$APP_PKG
FUSE_PROBE=/storage/emulated/0/Android
SELINUX_CTX=u:object_r:media_rw_data_file:s0
CANARY=$EXT4_MOUNT/$APP_PKG/.wa_sd_marker   # written once, then used to prove the bind end-to-end
MP_PROCS="com.google.android.providers.media.module com.android.providers.media.module"
FUSE_WAIT_MAX=90     # seconds to keep waiting for the provider's FUSE to serve (pure-FUSE)
BIND_RETRY=4         # bind attempts per event before logging an error (pure-FUSE)
CARD_RETRY=60        # seconds between card checks WHILE THE CARD IS ABSENT (not in steady state)
PASS_TIMEOUT=45      # seconds to wait for pass_through to appear (sdcardfs)

log() { echo "$(date '+%H:%M:%S') $*" >> "$LOGFILE"; }

have_sdcardfs() { grep -qw sdcardfs /proc/filesystems 2>/dev/null; }

# find the ext4 partition carrying EXT4_LABEL among the candidates.
find_ext4_dev() {
    for d in $EXT4_DEV_CANDIDATES; do
        [ -b "$d" ] || continue
        blkid "$d" 2>/dev/null | grep -q "LABEL=\"$EXT4_LABEL\"" && { echo "$d"; return 0; }
    done
    return 1
}

sd_base_of() { echo "${1%p*}"; }   # /dev/block/mmcblk1p2 -> /dev/block/mmcblk1

# run the bundled GPT repair if vold wiped the partition table on insert.
gpt_repair() {
    base=$1
    [ -n "$base" ] && [ -f "$MODDIR/fix_gpt.sh" ] || return 1
    log "GPT repair: running $MODDIR/fix_gpt.sh $base"
    sh "$MODDIR/fix_gpt.sh" "$base" >>"$LOGFILE" 2>&1
    sleep 2
}

# resolve + mount the ext4 partition (idempotent). sets EXT4_DEV on success.
#   0 = ready   1 = no candidate device present   2 = device present, wrong label   3 = mount failed
ensure_ext4() {
    EXT4_DEV=$(find_ext4_dev)
    if [ -z "$EXT4_DEV" ]; then
        # node missing entirely? try GPT repair on each candidate's base, then re-search.
        for d in $EXT4_DEV_CANDIDATES; do
            b=$(sd_base_of "$d")
            [ -b "$b" ] && gpt_repair "$b"
        done
        EXT4_DEV=$(find_ext4_dev)
        if [ -z "$EXT4_DEV" ]; then
            # is any candidate block device present at all?
            for d in $EXT4_DEV_CANDIDATES; do
                [ -b "$d" ] && return 2
            done
            return 1
        fi
    fi

    mkdir -p "$EXT4_MOUNT"
    if ! grep -qF "$EXT4_MOUNT" /proc/self/mountinfo; then
        mount -t ext4 -o rw "$EXT4_DEV" "$EXT4_MOUNT" 2>>"$LOGFILE" || return 3
    fi
    curgrp=$(stat -c %G "$LOWER" 2>/dev/null)
    [ "$curgrp" = "media_rw" ] || chgrp -R media_rw "$LOWER" 2>>"$LOGFILE"

    [ -f "$CANARY" ] || echo "wa_sd_media $(date +%s)" > "$CANARY" 2>/dev/null
    return 0
}

mp_pid() {
    for p in $MP_PROCS; do
        pid=$(pgrep -f "$p" 2>/dev/null | head -1)
        [ -n "$pid" ] && { echo "$pid"; return 0; }
    done
    return 1
}

# wait until MediaProvider's FUSE tree is actually serving (avoid "Transport endpoint ...")
wait_fuse() {
    i=0
    while [ $i -lt "$FUSE_WAIT_MAX" ]; do
        [ -d "$FUSE_PROBE" ] || { sleep 1; i=$((i+1)); continue; }
        n=$(ls /storage/emulated/0/ 2>/dev/null | wc -l)
        [ "${n:-0}" -gt 3 ] && return 0
        sleep 1; i=$((i+1))
    done
    return 1
}

# ---- pure-FUSE path -------------------------------------------------------------

bind_once() {
    pid=$1
    nsenter -t "$pid" -m -- sh -c "
        [ -d '$FUSE_DIR' ] || mkdir -p '$FUSE_DIR' 2>/dev/null
        if ! grep -qF '$FUSE_DIR' /proc/self/mountinfo; then
            mount --bind '$LOWER' '$FUSE_DIR' || exit 1
        fi
        chcon $SELINUX_CTX '$FUSE_DIR' 2>/dev/null
    " >>"$LOGFILE" 2>&1
}

canary_ok() {
    want=$(cat "$CANARY" 2>/dev/null)
    [ -n "$want" ] || return 1
    got=$(cat "$FUSE_DIR/.wa_sd_marker" 2>/dev/null)
    [ "$got" = "$want" ]
}

# bind, then retry until the canary is visible through the app path.
bind_until_ok() {
    attempt=1
    while [ $attempt -le $BIND_RETRY ]; do
        pid=$(mp_pid) || { sleep 2; attempt=$((attempt+1)); continue; }
        wait_fuse || { log "FUSE not serving yet (pid=$pid), attempt $attempt"; sleep 2; attempt=$((attempt+1)); continue; }
        bind_once "$pid"
        if canary_ok; then
            log "OK: bound + canary verified (pid=$pid)"
            return 0
        fi
        log "WARN: bound but canary not visible (pid=$pid), attempt $attempt"
        sleep 2; attempt=$((attempt+1))
    done
    log "ERROR: could not bind after $BIND_RETRY attempts"
    return 1
}

# ---- sdcardfs path --------------------------------------------------------------

run_sdcardfs() {
    I=0
    while [ $I -lt "$PASS_TIMEOUT" ]; do
        grep -qF "/mnt/pass_through/0/emulated " /proc/self/mountinfo 2>/dev/null && \
            [ -d "$SDCARD_TARGET" ] && break
        sleep 1; I=$((I+1))
    done
    [ -d "$SDCARD_TARGET" ] || { log "ERROR: $SDCARD_TARGET not available after ${PASS_TIMEOUT}s"; return 1; }

    if grep -qF "$LOWER" /proc/self/mountinfo 2>/dev/null; then
        log "sdcardfs stack already present — done"
        return 0
    fi
    mount -t sdcardfs -o nosuid,nodev,noexec,noatime,mask=7,gid=9997 "$LOWER" "$SDCARD_TARGET" 2>>"$LOGFILE"
    if [ $? -ne 0 ]; then log "ERROR: sdcardfs stack mount failed"; return 1; fi
    log "OK: sdcardfs stack $LOWER -> $SDCARD_TARGET"
    return 0
}

# ---------------------------------------------------------------- start

[ -f "$LOGFILE" ] && [ "$(wc -c < "$LOGFILE" 2>/dev/null)" -gt 102400 ] && \
    tail -n 400 "$LOGFILE" > "$LOGFILE.tmp" 2>/dev/null && mv "$LOGFILE.tmp" "$LOGFILE"
echo "" >> "$LOGFILE"
log "=== wa_sd_media service.sh start ==="
sleep 15   # let boot settle

# --- ext4 must be present. wrong label aborts; absent card is retried (insert-friendly). ---
while true; do
    ensure_ext4; rc=$?
    case $rc in
        0) log "ext4 ok: LABEL=$EXT4_LABEL ($EXT4_DEV) at $EXT4_MOUNT"; break;;
        2) log "WARN: $EXT4_LABEL partition not found / wrong label — exiting (no listener)"; exit 0;;
        *) log "card/ext4 not ready (rc=$rc) — retry in ${CARD_RETRY}s"; sleep $CARD_RETRY;;
    esac
done

[ -d "$LOWER" ] || { log "WARN: $LOWER missing on ext4 — exiting"; exit 0; }

# --- sdcardfs devices: one global stack, persistent. done. ---
if have_sdcardfs; then
    log "mode: sdcardfs ($EXT4_DEV)"
    run_sdcardfs
    log "=== done ==="
    exit 0
fi

# --- pure-FUSE devices: in-ns bind + event-driven repair. ---
log "mode: pure-FUSE"
bind_until_ok

log "listening for MediaProvider process events (am_proc_start)"
while true; do
    # -b events carries am_proc_start; -T 1 skips history; the read blocks until an event.
    logcat -b events -T 1 2>/dev/null | while read -r line; do
        case "$line" in
            *am_proc_start*media.module*)
                ensure_ext4 >/dev/null 2>&1 && bind_until_ok
                ;;
        esac
    done
    # logcat died (rare): we may have missed an event in the gap, so health-check once and
    # rebind only if actually broken. NOT a heartbeat — steady state stays zero-CPU.
    log "logcat stream ended — health check + restart"
    ensure_ext4 >/dev/null 2>&1 && { canary_ok || bind_until_ok; }
    sleep 1
done
