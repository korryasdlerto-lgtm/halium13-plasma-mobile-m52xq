#!/bin/sh
exec >> /userdata/bounce-composer-boot.log 2>&1
set -x
now_ms() {
    awk '{print int($1 * 1000)}' /proc/uptime
}
echo "BREADCRUMB: bounce-composer starting, uptime_ms=$(now_ms)"
MARKER=/run/halium-composer-bounced

# system.img -- system-as-root, top-level "bin"/"etc" symlinks exist but
# "lib64"/"lib" are missing from this build; without them the host-side
# compositor's literal /system/lib64/{libEGL,libGLESv1_CM,libGLESv2}.so
# lookup ENOENTs and it SIGABRTs before ever reaching EGL init.
ln -sf /android/system/system/lib64 /android/system/lib64 2>/dev/null
ln -sf /android/system/system/lib /android/system/lib 2>/dev/null
ln -sf /android/system/system/build.prop /android/system/build.prop 2>/dev/null

check_vendor() {
    cat /vendor/lib64/egl/libGLESv2_adreno.so >/dev/null 2>&1
}
if ! check_vendor; then
    echo "BREADCRUMB: vendor not ready, entering remount retry loop, uptime_ms=$(now_ms)"
    for i in 1 2 3 4 5; do
        umount /android/system/vendor/dsp 2>/dev/null
        umount /android/system/vendor/firmware-modem 2>/dev/null
        umount /android/system/vendor/firmware_mnt 2>/dev/null
        umount /android/system/vendor 2>/dev/null
        mount -o ro /dev/mapper/vendor /android/system/vendor 2>/dev/null
        mount -t vfat -o ro /dev/sda23 /android/system/vendor/firmware_mnt 2>/dev/null
        mount -t vfat -o ro /dev/sda18 /android/system/vendor/firmware-modem 2>/dev/null
        mount -t ext4 -o ro,nosuid,nodev /dev/sda17 /android/system/vendor/dsp 2>/dev/null
        check_vendor && break
        sleep 2
    done
fi

if [ ! -e "$MARKER" ]; then
    echo "BREADCRUMB: bouncing composer service, uptime_ms=$(now_ms)"
    lxc-attach -n android -- setprop ctl.stop surfaceflinger 2>/dev/null || true
    lxc-attach -n android -- setprop ctl.stop vendor.qti.hardware.display.composer 2>/dev/null || true
    sleep 1
    lxc-attach -n android -- setprop ctl.start vendor.qti.hardware.display.composer 2>/dev/null || true
    # Android's own vendor wpa_supplicant (wifi HAL) is not needed -- host
    # NetworkManager drives wlan0 directly via its own wpa_supplicant. Left
    # running, the vendor one issues a vendor-scan-with-MAC-randomization
    # request roughly once a second that this driver rejects
    # ("SCAN RANDOMIZATION not supported" / "Scan Request Failed" spammed
    # to dmesg continuously), which was observed as wifi instability
    # (found 2026-07-15). Stopping it does not affect the host wifi
    # connection (verified: nmcli stays connected, ping keeps working).
    lxc-attach -n android -- setprop ctl.stop wpa_supplicant 2>/dev/null || true
    touch "$MARKER"
fi

echo "BREADCRUMB: entering PID-stability wait loop, uptime_ms=$(now_ms)"
prev_pid=""
stable_count=0
needed_stable=4
max_wait=90
waited=0
while [ "$waited" -lt "$max_wait" ]; do
    state=$(lxc-attach -n android -- getprop init.svc.vendor.qti.hardware.display.composer 2>/dev/null)
    pid=$(lxc-attach -n android -- getprop init.svc_debug_pid.vendor.qti.hardware.display.composer 2>/dev/null)
    if [ "$state" = "running" ] && [ -n "$pid" ] && [ "$pid" = "$prev_pid" ]; then
        stable_count=$((stable_count + 1))
        if [ "$stable_count" -ge "$needed_stable" ]; then
            break
        fi
    else
        stable_count=0
    fi
    prev_pid="$pid"
    sleep 1
    waited=$((waited + 1))
done

# surfaceflinger is Android's own composer3 client; it competes with the
# host-side compositor for the composer HAL and causes
# "failed to create composer client" if it's alive when lomiri-system-
# compositor tries to connect. The single ctl.stop above (guarded by
# MARKER, so it only runs once per boot) is not enough -- surfaceflinger
# has been observed running again later in the same boot (respawned by
# Android's own init, exact trigger not diagnosed). So re-check and
# re-stop it on EVERY invocation of this script, not just the first one.
sf_state=$(lxc-attach -n android -- getprop init.svc.surfaceflinger 2>/dev/null)
if [ "$sf_state" != "stopped" ]; then
    echo "BREADCRUMB: surfaceflinger is '$sf_state', re-stopping, uptime_ms=$(now_ms)"
    lxc-attach -n android -- setprop ctl.stop surfaceflinger 2>/dev/null || true
    sleep 1
fi

echo "BREADCRUMB: bounce-composer finishing (waited=${waited}s, stable_count=$stable_count), uptime_ms=$(now_ms)"
sleep 2
