#!/bin/sh
# One-time (per-boot) libhybris bridge: copies base Android libs and the
# Adreno GPU driver stack — baked into this rootfs.img at build time under
# /opt/halium-lxc-bridge/ — into the LXC container's own (tmpfs-backed)
# rootfs, where the container's linker/HAL loader expects to find them.
# Sourced from a stable path inside rootfs.img rather than the live
# /android mount, since the container's system/vendor tmpfs overlay is
# always empty on every boot and the live mount may not be ready yet
# at the point this runs.
SRC=/opt/halium-lxc-bridge
DST_SYS=/var/lib/lxc/android/rootfs/system/lib64
DST_VEND=/var/lib/lxc/android/rootfs/vendor/lib64
LOG=/var/log/halium-lxc-bridge-libs.log

now_ms() {
    awk '{print int($1 * 1000)}' /proc/uptime
}

echo "$(date) uptime=$(cat /proc/uptime) START" >> "$LOG" 2>&1

[ -d "$SRC/system-lib64" ] || { echo "$(date) SRC missing, exiting" >> "$LOG" 2>&1; exit 0; }

# The container's tmpfs+overlay for /var/lib/lxc/android/rootfs/{system,vendor}
# is set up by lxc-android-config's own start script; systemd's After= ordering
# only guarantees that unit reached "active", not that its internal mount
# steps finished -- so retry until the target is actually writable rather than
# trusting ordering alone.
#
# NOTE: this device's wall clock is unreliable during early boot (jumps
# around, no RTC battery -- see halium-kickstart-lxc.sh for the same issue)
# so `date +%s` must NOT be used for the timeout math here; use
# /proc/uptime (monotonic) instead.
END_MS=$(($(now_ms) + 60000))
mkdir_tries=0
while [ "$(now_ms)" -lt "$END_MS" ]; do
    mkdir_tries=$((mkdir_tries + 1))
    mkdir -p "$DST_SYS" "$DST_VEND" 2>/dev/null
    [ -d "$DST_SYS" ] && [ -d "$DST_VEND" ] && break
    sleep 1
done
echo "$(date) uptime=$(cat /proc/uptime) mkdir loop done after $mkdir_tries tries, DST_SYS=$([ -d "$DST_SYS" ] && echo ok || echo MISSING) DST_VEND=$([ -d "$DST_VEND" ] && echo ok || echo MISSING)" >> "$LOG" 2>&1

echo "$(date) uptime=$(cat /proc/uptime) cp system-lib64 START ($(ls "$SRC/system-lib64" 2>/dev/null | wc -l) files, $(du -sh "$SRC/system-lib64" 2>/dev/null | cut -f1))" >> "$LOG" 2>&1
cp -rn "$SRC/system-lib64/." "$DST_SYS/" 2>>"$LOG"
echo "$(date) uptime=$(cat /proc/uptime) cp system-lib64 DONE" >> "$LOG" 2>&1

echo "$(date) uptime=$(cat /proc/uptime) cp vendor-lib64 START ($(ls "$SRC/vendor-lib64" 2>/dev/null | wc -l) files, $(du -sh "$SRC/vendor-lib64" 2>/dev/null | cut -f1))" >> "$LOG" 2>&1
cp -rn "$SRC/vendor-lib64/." "$DST_VEND/" 2>>"$LOG"
echo "$(date) uptime=$(cat /proc/uptime) cp vendor-lib64 DONE" >> "$LOG" 2>&1

cp -f "$LOG" /userdata/halium-lxc-bridge-libs.log 2>/dev/null || true
echo "$(date) uptime=$(cat /proc/uptime) SCRIPT END" >> "$LOG" 2>&1
