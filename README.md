# whatsapp-media-mount-to-sd

A Magisk module that offloads WhatsApp (or any app's) `Android/media` folder from full internal storage to a dedicated **ext4 partition on an SD card**, with full read/write support on Android 12.

Works on Android 10–12 with sdcardfs + FUSE. Tested on Samsung Galaxy S10e, OmniROM Android 12, kernel 4.14.

## Does this work for my device?

**Quick check — run this:**
```bash
adb shell grep sdcardfs /proc/filesystems
```

| Result | What it means | This module |
|---|---|---|
| `nodev  sdcardfs` | Your kernel has sdcardfs (Samsung, Sony, most OEM devices on Android ≤12) | **Works** |
| _(no output)_ | Pure FUSE device — sdcardfs removed (Pixel, stock Android 13+) | **Does not work** — see below |

### Pure FUSE devices (Pixel / stock Android 13+)

On these devices, Android's MediaProvider runs its FUSE daemon in a **private mount namespace**, so mounts made in the global namespace never reach it. A different approach is needed: enter MediaProvider's namespace directly with `nsenter` and mount there. See [JanKanis's answer on Android SE](https://android.stackexchange.com/a/257404) for details.

---

## The problem

Android's scoped storage forces WhatsApp media into `Android/media/com.whatsapp` on the primary storage volume. You cannot move it to an SD card via symlinks, bind mounts into `/data/media`, or tools like FolderMount — they all fail with a **Cross-device link (EXDEV)** error on devices running sdcardfs.

The root cause: sdcardfs uses `lookup_one_len` internally, which does **not** cross device boundaries in its lower filesystem. Any bind mount of an SD-card partition inside `/data/media` is invisible to sdcardfs — it returns EXDEV at every layer (sdcardfs, FUSE, `/storage/emulated`).

## The solution

Instead of binding inside `/data/media`, this module mounts a **fresh sdcardfs instance** — with the SD ext4 partition as its lower filesystem — directly on top of the sdcardfs `pass_through` path for the app's media directory:

```
mount -t sdcardfs -o nosuid,nodev,noexec,noatime,mask=7,gid=9997 \
    /mnt/wa_media/com.whatsapp \
    /mnt/pass_through/0/emulated/0/Android/media/com.whatsapp
```

Because `pass_through` is in a **shared mount peer group** (group 44), this single mount propagates automatically to:
- `/mnt/runtime/{default,read,write,full}/emulated/0/Android/media/com.whatsapp`
- `/mnt/user/0/emulated/0/Android/media/com.whatsapp`
- `/storage/emulated/0/Android/media/com.whatsapp` (via FUSE — what apps see)

WhatsApp reads and writes through FUSE → MediaProvider → sdcardfs (`pass_through`) → **your ext4 partition on SD**. No EXDEV. Full read/write confirmed.

### Storage topology (Android 12 FUSE mode)

```
WhatsApp
  └─ /storage/emulated/0/Android/media/com.whatsapp  (FUSE, /dev/fuse)
       └─ MediaProvider reads via:
            /mnt/pass_through/0/emulated/0/Android/media/com.whatsapp
              └─ [this module stacks here]
                    sdcardfs lower = /mnt/wa_media/com.whatsapp
                     └─ ext4 on mmcblk0p2 (SD card)
```

---

## Requirements

- Android 10–12 with **sdcardfs** (Samsung, Sony, and most non-Pixel devices)
- **Magisk** root
- SD card with a dedicated **ext4 partition** (minimum: size of your WhatsApp media)
- `adb` access and basic comfort with a root shell

> **Does not work on Pixel / pure FUSE devices.** Check the [compatibility table](#does-this-work-for-my-device) at the top.

---

## Setup

### Step 1 — Partition your SD card

On a Linux host with the SD card inserted (e.g. as `/dev/sdc`):

```bash
# Wipe and create GPT
sgdisk --zap-all /dev/sdc

# Optional: keep an exFAT partition for normal file transfer
sgdisk -n 1:2048:-200G -t 1:0700 /dev/sdc
mkfs.exfat -n SDCARD /dev/sdc1

# ext4 partition for app media (fills the rest)
sgdisk -n 2:0:0 -t 2:8300 /dev/sdc
mkfs.ext4 -L WA_MEDIA /dev/sdc2    # label must match EXT4_LABEL in service.sh

partprobe /dev/sdc
```

Adjust sizes to taste. The ext4 partition must be large enough to hold your app's media folder.

### Step 2 — Fix GPT after Android vold invalidates it

When you insert a GPT-partitioned SD card, Android vold **zeroes the `EFI PART` signature** to show a "Format?" prompt. Run the repair script once as root on the device:

```bash
adb push scripts/fix_gpt.sh /data/local/tmp/
adb shell "su -c 'sh /data/local/tmp/fix_gpt.sh'"
```

`fix_gpt.sh` calculates the backup GPT LBA **dynamically** from the actual card size (`blockdev --getsize`), so it works on any SD card — no edits needed.

After this, `mmcblk0p1` and `mmcblk0p2` should appear. Android will mount the exFAT partition automatically via vold.

### Step 3 — Copy media to the ext4 partition

```bash
adb shell "su -c '
    mount -t ext4 /dev/block/mmcblk0p2 /mnt/wa_media

    # Use rsync for resumability; fall back to cp -a if unavailable
    rsync -a /data/media/0/Android/media/com.whatsapp/ /mnt/wa_media/com.whatsapp/

    # Fix SELinux labels (cp -a and rsync do not copy xattrs to ext4)
    chcon -R u:object_r:media_rw_data_file:s0 /mnt/wa_media/com.whatsapp
'"
```

> **Note:** `cp -a` silently drops SELinux xattrs on ext4. Always run `chcon` after copying or files will have `unlabeled` context and be inaccessible.
>
> **Faster alternative:** If you have a card reader on a Linux host, mount both the source and destination ext4 partitions and use `rsync -aX` — the `-X` flag preserves SELinux xattrs directly, so no `chcon` step is needed.

Verify the copy:
```bash
adb shell "su -c 'du -sh /mnt/wa_media/com.whatsapp; ls /mnt/wa_media/com.whatsapp/WhatsApp/'"
```

### Step 4 — Create the stub mount target on internal storage

The module stacks sdcardfs on top of this directory. The original media folder becomes the rollback.

```bash
adb shell "su -c '
    cd /data/media/0/Android/media
    mv com.whatsapp com.whatsapp.orig        # keep as rollback
    mkdir com.whatsapp
    chown 1023:1023 com.whatsapp
    chmod 2775 com.whatsapp
    chcon u:object_r:media_rw_data_file:s0 com.whatsapp
'"
```

### Step 5 — Install the Magisk module

```bash
# Push module files to a staging area
adb shell "su -c 'mkdir -p /data/adb/modules/wa_sd_media'"
for f in module/module.prop module/service.sh module/post-fs-data.sh module/skip_mount; do
    adb push $f /data/local/tmp/$(basename $f)
    adb shell "su -c 'cp /data/local/tmp/$(basename $f) /data/adb/modules/wa_sd_media/$(basename $f)'"
done
adb shell "su -c 'chmod 755 /data/adb/modules/wa_sd_media/service.sh /data/adb/modules/wa_sd_media/post-fs-data.sh'"
```

Edit `module/service.sh` before pushing if needed:
- `EXT4_DEV` — block device for your ext4 partition (default: `/dev/block/mmcblk0p2`)
- `EXT4_LABEL` — partition label (default: `WA_MEDIA`)
- `APP_PKG` — app package name (default: `com.whatsapp`)

> **The `EXT4_LABEL` must match the label you gave the ext4 partition with `mkfs.ext4 -L`.** This is the only value that differs per card setup. `fix_gpt.sh` is card-size-agnostic (calculates backup LBA dynamically).

### Step 6 — Reboot and verify

```bash
adb reboot
# Wait ~60 seconds, then:
adb shell "su -c 'cat /data/local/tmp/wa_sd_media.log'"
```

Expected log output:
```
HH:MM:SS === wa_sd_media service.sh start ===
HH:MM:SS Sleeping 15s for boot settle...
HH:MM:SS Awake.
HH:MM:SS Waiting for /dev/block/mmcblk0p2...
HH:MM:SS Confirmed /dev/block/mmcblk0p2 LABEL=WA_MEDIA
HH:MM:SS Mounted /dev/block/mmcblk0p2 at /mnt/wa_media
HH:MM:SS Waiting for /mnt/pass_through/0/emulated/0/Android/media/com.whatsapp...
HH:MM:SS OK: sdcardfs stack /mnt/wa_media/com.whatsapp -> /mnt/pass_through/...
HH:MM:SS === wa_sd_media done ===
```

Open WhatsApp and confirm media loads. Once verified across at least two reboots, you can reclaim the internal space:

```bash
adb shell "su -c 'rm -rf /data/media/0/Android/media/com.whatsapp.orig'"
```

---

## How the module works

`service.sh` runs as a Magisk `late_start` service after `sys.boot_completed=1`:

1. **Sleep 15 s** — Magisk fires at `boot_completed` while the shell context is still unstable; this clears the race.
2. **Poll for `/dev/block/mmcblk0p2`** — waits up to 45 s for the SD card block device to appear.
3. **Verify partition label** — `blkid` on the specific device (fast, no full-disk scan).
4. **Mount ext4** at `/mnt/wa_media` (idempotent).
5. **Poll for `pass_through` mountpoint** — waits for sdcardfs to be fully up.
6. **Stack sdcardfs** — mounts a fresh sdcardfs instance (`lower=/mnt/wa_media/com.whatsapp`) on `/mnt/pass_through/0/emulated/0/Android/media/com.whatsapp`.
7. Mount propagates via shared peer-group-44 to all runtime views and FUSE.

If the SD card is absent, the module exits cleanly. WhatsApp will show an empty media directory (the stub created in Step 4) but nothing breaks.

---

## Rollback

```bash
adb shell "su -c '
    # Unmount the stack
    umount /mnt/pass_through/0/emulated/0/Android/media/com.whatsapp
    umount /mnt/wa_media

    # Restore original media
    rm -rf /data/media/0/Android/media/com.whatsapp
    mv /data/media/0/Android/media/com.whatsapp.orig \
       /data/media/0/Android/media/com.whatsapp

    # Remove module
    rm -rf /data/adb/modules/wa_sd_media
'"
adb reboot
```

---

## Troubleshooting

**"media file does not exist" in WhatsApp after reboot**  
Check the log (`cat /data/local/tmp/wa_sd_media.log`). If it shows only `start` with nothing after, the boot-time shell was killed before the module ran. Try increasing the `sleep` value at the top of `service.sh` from 15 to 20 or 25.

**`ls` on sdcardfs paths returns EXDEV**  
You have a plain bind mount inside `/data/media` from a previous attempt. Unmount it:
```bash
umount /data/media/0/Android/media/com.whatsapp
```
Then re-run the sdcardfs stack mount from Step 6.

**Files on ext4 show as `unlabeled` in SELinux**  
Run: `chcon -R u:object_r:media_rw_data_file:s0 /mnt/wa_media/com.whatsapp`

**`mmcblk0p1`/`mmcblk0p2` not appearing after SD card insert**  
Android vold zeroed the GPT signatures. Run `scripts/fix_gpt.sh` (see Step 2).

**Module log shows `LABEL!=WA_MEDIA`**  
The ext4 partition label doesn't match. Either re-label the partition:
```bash
# on host:
e2label /dev/sdX2 WA_MEDIA
```
or update `EXT4_LABEL` in `service.sh` to match your existing label.

---

## Other apps

To redirect a different app, change `APP_PKG` in `service.sh` and repeat Steps 3–4 for that package's `Android/media/<package>` folder. The sdcardfs stacking technique works for any app that stores media under `Android/media/`.

---

## Tested environment

| Component | Version |
|---|---|
| Device | Samsung Galaxy S10e SM-G970F |
| ROM | OmniROM Android 12 |
| Kernel | 4.14.113-AmbasadiiCruel-v6.8 (open source) |
| Magisk | 27+ |
| Storage mode | `persist.sys.fuse=true` (Android 12 FUSE + sdcardfs hybrid) |
| SELinux | Enforcing |

---

## Background reading

- [Android SE: Mounting portable SD card folder to internal folder (WhatsApp)](https://android.stackexchange.com/revisions/219678/2) — the post that identified the sdcardfs-stacking technique (Android 9, no FUSE). This repo adapts it for Android 12 FUSE mode.
- [Linux mount namespaces and shared subtrees](https://www.kernel.org/doc/html/latest/filesystems/sharedsubtree.html) — explains peer groups and mount propagation.
- [Stack Exchange on how to bind mount on later versions of android](https://android.stackexchange.com/questions/217741/how-to-bind-mount-a-folder-inside-sdcard-with-correct-permissions)
