#!/system/bin/sh
# post-fs-data runs too early (before sdcardfs/runtime mounts exist).
# All mount work is in service.sh (Magisk late_start, after boot_completed).
