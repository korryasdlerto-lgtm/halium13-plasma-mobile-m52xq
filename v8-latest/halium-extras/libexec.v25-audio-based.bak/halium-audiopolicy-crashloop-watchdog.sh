#!/bin/sh
# 2026-07-16: found via user report that the device has been running hot
# and draining battery "since yesterday evening" (2026-07-15), independent
# of the WiFi/WCN crash-loop found and watchdogged earlier today.
#
# Root cause: this vendor image genuinely has NO native audioserver binary
# at all (not just disabled/renamed -- /system/bin/audioserver does not
# exist under any name; confirmed the real audio path here is PulseAudio
# -> audio.hidl_compat.default.so -> android.hardware.audio.service HIDL,
# entirely bypassing native Android audioserver). The "media.audio_policy"
# binder service is instead expected to be provided by droidmedia's own
# lightweight stand-in, the init.rc service "minimedia"
# (/system/bin/minimediaservice, see servicemanager.rc) -- this process IS
# present and IS running, but crash-loops continuously with ZERO logcat
# output of its own (confirmed via --pid filtering and live strace
# attach attempts, which lost the race against how fast it dies and
# respawns -- consistent with an external SIGKILL, e.g. lowmemorykiller,
# rather than a self-reported crash).
#
# Every time minimedia dies, system_server's CaptureStateTracker
# immediately re-throws "Audio policy service died" in a tight loop (no
# backoff), which is the actual source of sustained ~65% CPU on
# system_server -- this is what generates the heat and battery drain,
# and is suspected to also be why call audio routing fails (Android's
# telephony stack needs a working AudioPolicyService binder to route
# call audio, so a permanently-dying minimedia would explain calls
# connecting but having no ringback / dropping quickly, reported the
# same day).
#
# ROOT CAUSE OF WHY MINIMEDIA ITSELF DIES: NOT FOUND. This watchdog does
# NOT fix that -- it only detects the resulting storm and stops
# minimedia's respawn cycle via `setprop ctl.stop`, trading "call audio
# routing/camera shutter sound don't work" for "phone doesn't overheat
# and drain the battery". Same trade-off philosophy as
# halium-wifi-crashloop-watchdog.sh.

LOG_TAG="halium-audiopolicy-crashloop-watchdog"
WINDOW_SECONDS=20
STORM_THRESHOLD=30
CHECK_INTERVAL=5
STATE_FILE=/run/halium-audiopolicy-crashloop-watchdog.handled

log() {
    echo "$LOG_TAG: $1" | systemd-cat -t "$LOG_TAG" -p info
}

sleep 60

while true; do
    sleep "$CHECK_INTERVAL"

    [ -e "$STATE_FILE" ] && continue

    died_count=$(lxc-attach -n android -- logcat -d -t 500 2>/dev/null \
        | grep -c "Audio policy service died")

    if [ "${died_count:-0}" -ge "$STORM_THRESHOLD" ]; then
        log "detected Audio policy service crash-loop storm ($died_count occurrences in recent log) -- stopping minimedia respawn to prevent CPU/battery drain"
        lxc-attach -n android -- setprop ctl.stop minimedia 2>/dev/null
        log "minimedia service stopped. Call audio routing and camera shutter sound may not work until next reboot -- this is expected."
        touch "$STATE_FILE"
    fi
done
