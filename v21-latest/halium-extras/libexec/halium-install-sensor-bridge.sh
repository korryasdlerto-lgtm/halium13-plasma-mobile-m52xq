#!/bin/sh
# 2026-07-16: halium_sensor_bridge needs to live at /vendor/bin/ inside the
# android container (Treble linker namespace only resolves vendor libs like
# android.hardware.sensors-V1-ndk.so for binaries whose OWN path is under
# /vendor -- confirmed live that running it from /data fails with "library
# not found"). Rather than baking it into vendor.img at flash time (this
# project's convention is to never touch the system/vendor images directly
# -- everything goes through runtime injection instead, matching
# kernel-modules-fixed/, libgbinder safety nets, etc.), the binary ships on
# the writable /data partition (placed directly by update-binary, same as
# rootfs.img itself) and this script copies it into /vendor/bin fresh on
# every boot.

SRC=/data/halium-vendor-inject/halium_sensor_bridge
DEST=/vendor/bin/halium_sensor_bridge

for i in $(seq 1 30); do
    if lxc-attach -n android -- test -d /vendor/bin 2>/dev/null; then
        lxc-attach -n android -- mount -o remount,rw /vendor 2>/dev/null
        lxc-attach -n android -- cp "$SRC" "$DEST"
        lxc-attach -n android -- chmod 755 "$DEST"
        break
    fi
    sleep 1
done
