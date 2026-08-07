#!/bin/sh
# Bind host /vendor, /system, /dev/__properties__ onto the running Android
# container's real filesystem, and swap in the hwcomposer-capable phoc build,
# so phoc/libhybris (running on the host/glibc side) can find EGL/GLES vendor
# libraries and read real Android system properties (ro.hardware.egl etc).
#
# /vendor and /system must already exist as empty directories in the host
# rootfs.img (created once via: mount -o remount,rw /; mkdir -p /vendor
# /system; mount -o remount,ro /) -- ExecStartPre can bind-mount onto them
# but can't create them on a read-only root.

# FOUND 2026-07-21 live: the old /userdata/phoc-downgrade-backup/phoc-0.47.0-old
# copy lost its executable bit at some point (plain `cp`, never `chmod +x`'d),
# so this bind-mount silently succeeded but phosh.service crash-looped with
# "dbus-run-session: failed to exec '/usr/bin/phoc': Permission denied".
# Prefer the rootfs.img-shipped copy (usr/bin/phoc-0.47.0, ships with correct
# perms on every flash) and fall back to the old /userdata path for
# already-flashed devices that only have that one; chmod defensively either way.
#
# FOUND AGAIN 2026-07-21, later same day: the version-string idempotency
# check below ("already 0.47.0, skip re-mount") is not enough on its own --
# seen live losing the +x bit again on a LATER phosh.service restart even
# after a prior restart had it working, root cause not fully pinned down
# (suspected race across the rapid ExecStartPre-triggered restart cycle).
# Make the chmod itself unconditional, every single run, regardless of the
# version check outcome or whether the bind-mount already happened -- it's
# a no-op if already correct, cheap, and removes this whole class of bug.
chmod 755 /usr/bin/phoc 2>/dev/null || true
if ! /usr/bin/phoc --version 2>/dev/null | grep -q "0.47.0"; then
    if [ -f /usr/bin/phoc-0.47.0 ]; then
        chmod 755 /usr/bin/phoc-0.47.0 2>/dev/null || true
        mount --bind /usr/bin/phoc-0.47.0 /usr/bin/phoc 2>/dev/null || true
    elif [ -f /userdata/phoc-downgrade-backup/phoc-0.47.0-old ]; then
        chmod 755 /userdata/phoc-downgrade-backup/phoc-0.47.0-old 2>/dev/null || true
        mount --bind /userdata/phoc-downgrade-backup/phoc-0.47.0-old /usr/bin/phoc 2>/dev/null || true
    fi
    chmod 755 /usr/bin/phoc 2>/dev/null || true
fi

mountpoint -q /vendor || mount --bind /android/vendor /vendor 2>/dev/null || true
mountpoint -q /system || mount --bind /android/system/system /system 2>/dev/null || true

# FOUND 2026-07-29 live: wayfire's hwcomposer/EGL backend triggers a REAL
# kernel a660_zap (Adreno GPU zap-shader) PIL boot on the host side, same as
# surfaceflinger does inside the container -- "Failed to locate
# a660_zap.mdt(rc:-2)" / "pil_boot failed for a660_zap" in pstore, right
# before a hardware watchdog reboot. The container-side fix (mount-patched-v3.sh)
# already solves this for ${R}/vendor/firmware, but that's a namespace-local
# tmpfs overlay invisible to the host -- host's /vendor/firmware (bind-mounted
# from /android/vendor above) is missing the zap files for the same reason
# the plain vendor partition is: the real bytes live on a separate FAT
# partition (/dev/sda23, already mounted by the container mount hook at
# /android/system/vendor/firmware_mnt), not in /vendor/firmware itself.
# Same fix, host side: overlay a tmpfs on host's /vendor/firmware with the
# existing content plus the real zap bytes copied in.
#
# FOUND 2026-07-29, second pass: /android/system/vendor/firmware_mnt is set
# up by the container's OWN mount hook (lxc.hook.mount), which races against
# this ExecStartPre on a cold container start -- wait briefly instead of
# silently skipping the whole block on a lost race (matches the same class
# of race documented in mount-patched-v3.sh Находка 26/33).
i=0
while [ ! -d /android/system/vendor/firmware_mnt/image ] && [ "$i" -lt 20 ]; do
    sleep 0.5
    i=$((i + 1))
done

if [ -d /android/system/vendor/firmware_mnt/image ] && ! mountpoint -q /vendor/firmware-zap-staging 2>/dev/null; then
    mkdir -p /vendor/firmware-zap-staging 2>/dev/null || true
    mount -t tmpfs gpu-firmware-staging /vendor/firmware-zap-staging 2>/dev/null || true
    cp -a /vendor/firmware/. /vendor/firmware-zap-staging/ 2>/dev/null || true
    for zf in a660_zap.mdt a660_zap.b00 a660_zap.b01 a660_zap.b02; do
        cp /android/system/vendor/firmware_mnt/image/"$zf" /vendor/firmware-zap-staging/ 2>/dev/null || true
        chmod 644 /vendor/firmware-zap-staging/"$zf" 2>/dev/null || true
    done
    mount --bind /vendor/firmware-zap-staging /vendor/firmware 2>/dev/null || true

    # FOUND 2026-07-29: same as mount-patched-v3.sh Находка (2026-07-28,
    # в3) for the container -- the kernel tries a THIRD, direct firmware
    # lookup path ("/firmware/image/a660_zap.*") before ever falling back to
    # the racy sysfs/ueventd fallback, and a660_zap.b02 reliably loses that
    # race (ENODEV on sendfile). Populating this direct path lets
    # request_firmware() succeed immediately without ever needing the
    # fallback, avoiding the race entirely instead of trying to win it.
    mkdir -p /firmware/image 2>/dev/null || true
    for zf in a660_zap.mdt a660_zap.b00 a660_zap.b01 a660_zap.b02; do
        cp /android/system/vendor/firmware_mnt/image/"$zf" /firmware/image/ 2>/dev/null || true
        chmod 644 /firmware/image/"$zf" 2>/dev/null || true
    done
fi

CPID=$(lxc-info -n android 2>/dev/null | awk '/^PID:/{print $2}')
if [ -n "$CPID" ] && [ -d "/proc/$CPID/root/dev/__properties__" ]; then
    mount --bind "/proc/$CPID/root/dev/__properties__" /dev/__properties__ 2>/dev/null || true
fi

if [ -x /userdata/phosh-session-debug-clean ]; then
    mountpoint -q /usr/bin/phosh-session || mount --bind /userdata/phosh-session-debug-clean /usr/bin/phosh-session 2>/dev/null || true
fi

exit 0
