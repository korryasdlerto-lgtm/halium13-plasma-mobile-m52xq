#!/bin/sh
# 2026-07-16: halium_sensor_bridge (AIDL client to android.hardware.sensors.ISensors,
# see device/samsung/m52xq/sensor_bridge/ in the AOSP tree) gets its FMQ event
# subscription silently orphaned whenever something else on the android side
# re-establishes its own connection to ISensors -- confirmed reproducible: every
# single time lightdm/lomiri restarts (which happens routinely -- compositor
# recovers itself from crashes throughout the day), the bridge process stays
# alive (doesn't crash, just sits blocked in the FMQ wait forever) but the
# /data/vendor/sensor_bridge/accelerometer file stops updating, silently
# breaking auto-rotate until something manually kills and restarts the bridge.
#
# This polls the accelerometer file's mtime; if it goes stale (no update in
# STALE_THRESHOLD seconds) while the bridge process is alive, kill -9 + restart
# it, which forces a fresh initialize()/activate() and a fresh (non-orphaned)
# FMQ subscription.

LOG_TAG="halium-sensor-bridge-watchdog"
CHECK_INTERVAL=5
STALE_THRESHOLD=8
ACCEL_FILE=/data/vendor/sensor_bridge/accelerometer

log() {
    echo "$LOG_TAG: $1" | systemd-cat -t "$LOG_TAG" -p info
}

start_bridge() {
    lxc-attach -n android -- sh -c \
        "nohup /vendor/bin/halium_sensor_bridge > /data/local/tmp/sensor_bridge.log 2>&1 < /dev/null &"
}

sleep 30
start_bridge

while true; do
    sleep "$CHECK_INTERVAL"

    # NOTE: pgrep/pkill -x match against /proc/PID/comm, which the kernel
    # truncates to 15 chars (TASK_COMM_LEN) -- "halium_sensor_bridge" is 21
    # chars, so -x NEVER matches and this check always (wrongly) concluded
    # "not running", spawning a fresh instance every single cycle (confirmed
    # live: 13 orphaned copies accumulated in under a minute). -f matches the
    # full cmdline instead, which does contain the untruncated binary path.
    if ! lxc-attach -n android -- pgrep -f halium_sensor_bridge >/dev/null 2>&1; then
        log "bridge process not running, starting it"
        start_bridge
        sleep 3
        continue
    fi

    mtime=$(lxc-attach -n android -- stat -c %Y "$ACCEL_FILE" 2>/dev/null)
    now=$(date +%s)
    [ -z "$mtime" ] && continue

    age=$((now - mtime))
    if [ "$age" -gt "$STALE_THRESHOLD" ]; then
        log "accelerometer bridge file stale (${age}s old) -- FMQ subscription likely orphaned, restarting bridge"
        lxc-attach -n android -- pkill -9 -f halium_sensor_bridge 2>/dev/null
        sleep 1
        start_bridge
    fi
done
