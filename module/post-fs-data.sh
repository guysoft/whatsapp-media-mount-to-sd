#!/system/bin/sh
# post-fs-data.sh — runs early (before /data is fully mounted and before MediaProvider exists).
# All mount work happens in service.sh (Magisk late_start), after boot_completed. Nothing to do
# here on Android 13+ / pure-FUSE devices.
