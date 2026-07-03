#!/system/bin/sh
# fix_gpt.sh — repair GPT signatures zeroed by Android vold on SD card insert.
#
# When a GPT-partitioned SD card is inserted, Android's vold zeros the 8-byte
# "EFI PART" signature at LBA 1 (and the backup GPT) to invalidate the
# partition table and prompt "Format SD card?". This script patches them back
# so the partition nodes (mmcblk0p1, mmcblk0p2, ...) reappear.
#
# Usage (run as root on the Android device):
#   sh fix_gpt.sh
#
# The backup GPT LBA is the last sector of the disk.
# Calculated dynamically so this script works on any card size.

DEV=/dev/block/mmcblk0
TMPF=/data/local/tmp/gpt_bak.bin
SIG='\x45\x46\x49\x20\x50\x41\x52\x54'   # "EFI PART"

echo "=== GPT signature repair for $DEV ==="

# 1. MBR boot signature (55 AA at byte 510)
printf '\x55\xAA' | dd of=$DEV bs=1 seek=510 count=2 conv=notrunc 2>/dev/null \
    && echo "1/4 MBR 55AA: OK"

# 2. Primary GPT header signature (LBA1, disk byte 512)
printf $SIG | dd of=$DEV bs=1 seek=512 count=8 conv=notrunc 2>/dev/null \
    && echo "2/4 Primary GPT sig: OK"

# 3. Backup GPT header signature (last LBA, computed dynamically)
BACKUP_LBA=$(( $(blockdev --getsize $DEV) - 1 ))
dd if=$DEV of=$TMPF bs=512 skip=$BACKUP_LBA count=1 2>/dev/null
printf $SIG | dd of=$TMPF bs=1 seek=0 count=8 conv=notrunc 2>/dev/null
dd if=$TMPF of=$DEV bs=512 seek=$BACKUP_LBA count=1 conv=notrunc 2>/dev/null \
    && echo "3/4 Backup GPT sig: OK"
rm -f $TMPF

# 4. Tell kernel to re-read partition table
blockdev --rereadpt $DEV 2>&1 && echo "4/4 rereadpt: OK"

echo "=== Result ==="
ls /dev/block/mmcblk0*
blkid /dev/block/mmcblk0p1 /dev/block/mmcblk0p2 2>/dev/null \
    || echo "(blkid returned nothing — wait a moment and retry)"
