#!/bin/sh
# 2026-07-16: on some boots the WCN chip (icnss2 platform driver) never
# finishes initializing -- dmesg fills with "icnss2: Modules not
# initialized just return" roughly once a second, forever, and
# android.hardware.wifi@1.0-service (vendor.wifi_hal_legacy) crash-loops:
# each "Wifi Turning On from UI" write to /dev/wlan blocks for up to
# HDD_WLAN_START_WAIT_TIME (20s, see qcacld-3.0 wlan_hdd_hostapd.c/
# wlan_hdd_main.c), times out, the HAL thread SIGSEGVs, android init
# respawns the service, and it retries forever. This burns CPU
# continuously and is the most likely cause of the heat/battery-drain
# reports on 2026-07-16 -- confirmed via `top` showing sustained load
# during the hang, and confirmed the WLAN driver itself never recovers
# without a full reboot (rmmod/insmod of the wlan stack live is
# explicitly avoided in this project -- has caused spontaneous
# reboots/hangs before).
#
# This watchdog does NOT attempt to fix the underlying WCN init race
# (unknown root cause, intermittent -- worked fine on the very next
# boot with no changes). It only detects the crash-loop signature and
# stops retrying, to stop the battery drain -- properly via
# `setprop ctl.stop` (a plain kill would just have Android init
# respawn the service again). WiFi stays off until the next reboot;
# this is a deliberate trade-off (dead WiFi > drained battery).

LOG_TAG="halium-wifi-crashloop-watchdog"
WINDOW_SECONDS=90
CRASH_THRESHOLD=4
CHECK_INTERVAL=5
STATE_FILE=/run/halium-wifi-crashloop-watchdog.handled

log() {
    echo "$LOG_TAG: $1" | systemd-cat -t "$LOG_TAG" -p info
}

# Give lxc-android-config a reasonable head start before the first check.
sleep 60

while true; do
    sleep "$CHECK_INTERVAL"

    # Already handled this boot -- nothing more to do until next reboot.
    [ -e "$STATE_FILE" ] && continue

    # If wlan0 exists, WiFi came up fine -- no crash loop, nothing to watch for.
    if ip link show wlan0 >/dev/null 2>&1; then
        continue
    fi

    since_ts=$(date -d "-${WINDOW_SECONDS} seconds" '+%Y-%m-%d %H:%M:%S')
    crash_count=$(journalctl -k --since "$since_ts" --no-pager 2>/dev/null \
        | grep -c "Wifi Turning On from UI")

    if [ "${crash_count:-0}" -ge "$CRASH_THRESHOLD" ]; then
        log "detected WiFi crash loop ($crash_count restarts in ${WINDOW_SECONDS}s, no wlan0) -- stopping retries to prevent battery drain"
        lxc-attach -n android -- setprop ctl.stop vendor.wifi_hal_legacy 2>/dev/null
        lxc-attach -n android -- setprop ctl.stop wificond 2>/dev/null
        lxc-attach -n android -- setprop ctl.stop cnss-daemon 2>/dev/null
        log "WiFi HAL services stopped. WiFi will stay off until next reboot -- this is expected, reboot to retry."
        touch "$STATE_FILE"
    fi
done
