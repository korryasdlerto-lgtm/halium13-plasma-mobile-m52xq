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

# FOUND 2026-07-31 (в5, autostart hardening): these used to be a plain
# `|| true` no-op -- fine when run manually well after the container had
# time to settle, but with lxc@android.service auto-started this
# ExecStartPre can fire before the container's own init has populated
# /android/vendor and /android/system/system on the host side yet, so
# the bind silently mounted nothing and every downstream check
# (android-service@hwcomposer's /system/etc/init grep) failed forever
# no matter how many times Restart=on-failure retried the OUTER service
# -- this script itself never retried its OWN bind. Wait for the source
# paths to actually be populated first (same pattern as the firmware
# wait loop below).
if ! mountpoint -q /vendor; then
    i=0
    while [ ! -d /android/vendor/firmware ] && [ "$i" -lt 20 ]; do
        sleep 0.5
        i=$((i + 1))
    done
    mount --bind /android/vendor /vendor 2>/dev/null || true
fi
if ! mountpoint -q /system; then
    i=0
    while [ ! -d /android/system/system/etc ] && [ "$i" -lt 20 ]; do
        sleep 0.5
        i=$((i + 1))
    done
    mount --bind /android/system/system /system 2>/dev/null || true
fi

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

# FOUND 2026-07-30, third pass (в5): staging dir used to live under
# /vendor/firmware-zap-staging -- but host /vendor is mounted read-only
# (confirmed live: "mkdir: /vendor/firmware-zap-staging: Read-only file
# system"), so mkdir silently failed (2>/dev/null swallowed it) and
# every step after cascaded to a no-op, all the way through the final
# bind-mount ("special device ... does not exist"). None of this showed
# up as a script failure (every line has its own `|| true`), it just
# quietly never worked -- the a660_zap host crash kept happening despite
# this block appearing to run cleanly (exit 0). /run is tmpfs and always
# writable regardless of /vendor's own mount state; only the FINAL bind
# target (/vendor/firmware) needs to exist, not be writable, which a
# plain bind-mount doesn't require.
if [ -d /android/system/vendor/firmware_mnt/image ] && ! mountpoint -q /run/gpu-firmware-staging 2>/dev/null; then
    mkdir -p /run/gpu-firmware-staging 2>/dev/null || true
    mount -t tmpfs gpu-firmware-staging /run/gpu-firmware-staging 2>/dev/null || true
    cp -a /vendor/firmware/. /run/gpu-firmware-staging/ 2>/dev/null || true
    for zf in a660_zap.mdt a660_zap.b00 a660_zap.b01 a660_zap.b02; do
        cp /android/system/vendor/firmware_mnt/image/"$zf" /run/gpu-firmware-staging/ 2>/dev/null || true
        chmod 644 /run/gpu-firmware-staging/"$zf" 2>/dev/null || true
    done
    mount --bind /run/gpu-firmware-staging /vendor/firmware 2>/dev/null || true

    # FOUND 2026-07-29: same as mount-patched-v3.sh Находка (2026-07-28,
    # в3) for the container -- the kernel tries a THIRD, direct firmware
    # lookup path ("/firmware/image/a660_zap.*") before ever falling back to
    # the racy sysfs/ueventd fallback, and a660_zap.b02 reliably loses that
    # race (ENODEV on sendfile). Populating this direct path lets
    # request_firmware() succeed immediately without ever needing the
    # fallback, avoiding the race entirely instead of trying to win it.
    #
    # FOUND 2026-07-30 (в5): unlike /vendor and /system, /firmware/image was
    # never created as a persistent empty directory inside the shared
    # rootfs.img -- host root boots as a read-only overlay
    # (lowerdir=/halium-system, upperdir=/tmpmnt/rootfs-overlay, mounted
    # "ro" itself, so even the upperdir doesn't help), confirmed live:
    # "mkdir: /firmware: Read-only file system". Even after creating
    # /firmware/image once via a temporary remount,rw, plain `cp` into it
    # still failed on every SUBSEQENT boot (root goes back to ro) -- same
    # tmpfs-staging + bind-mount pattern as /vendor/firmware above, not a
    # direct write.
    if ! mountpoint -q /firmware/image 2>/dev/null; then
        mkdir -p /run/gpu-firmware-direct-staging /firmware/image 2>/dev/null || true
        for zf in a660_zap.mdt a660_zap.b00 a660_zap.b01 a660_zap.b02; do
            cp /android/system/vendor/firmware_mnt/image/"$zf" /run/gpu-firmware-direct-staging/ 2>/dev/null || true
            chmod 644 /run/gpu-firmware-direct-staging/"$zf" 2>/dev/null || true
        done
        mount --bind /run/gpu-firmware-direct-staging /firmware/image 2>/dev/null || true
    fi
fi

CPID=$(lxc-info -n android 2>/dev/null | awk '/^PID:/{print $2}')
if [ -n "$CPID" ] && [ -d "/proc/$CPID/root/dev/__properties__" ]; then
    mount --bind "/proc/$CPID/root/dev/__properties__" /dev/__properties__ 2>/dev/null || true
fi

if [ -x /userdata/phosh-session-debug-clean ]; then
    mountpoint -q /usr/bin/phosh-session || mount --bind /userdata/phosh-session-debug-clean /usr/bin/phosh-session 2>/dev/null || true
fi

# FOUND 2026-07-31 (в5): touch (synaptics_ts i2c) needs a manual driver
# bind every boot -- its regulator suppliers aren't ready when the driver
# auto-probes at module-load time, so it sits deferred forever without
# this. Runs here (ExecStartPre of android-service@hwcomposer, which
# plasma-mobile-wf.service depends on) so it's in place before the shell
# needs input.
for i in $(seq 1 20); do
    [ -e /sys/bus/i2c/drivers/synaptics_ts/24-004b ] && break
    echo 24-004b > /sys/bus/i2c/drivers/synaptics_ts/bind 2>/dev/null && break
    sleep 0.5
done

exit 0
