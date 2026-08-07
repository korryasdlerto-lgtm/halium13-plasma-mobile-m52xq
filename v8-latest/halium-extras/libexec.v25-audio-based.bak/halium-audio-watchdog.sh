#!/bin/sh
# 2026-07-16: companion to halium-fix-audio-hal.sh, which only retries the
# audio.primary.default.so bind-mount ONCE at boot (up to 60s). This
# watchdog re-checks the SAME condition periodically (via a systemd timer,
# not a long-lived process) for the rest of the uptime, in case the
# bind-mount is ever undone at runtime (e.g. by an unexpected remount of
# /android/system/vendor, or a container restart) -- cheap and idempotent,
# safe to run repeatedly since it's a no-op once the mount is already
# correct.

LOG_TAG="halium-audio-watchdog"
SRC=/opt/halium-lxc-bridge/system-lib64/hw/audio.hidl_compat.default.so
DST=/android/system/vendor/lib64/hw/audio.primary.default.so

log() {
    echo "$LOG_TAG: $1" | systemd-cat -t "$LOG_TAG" -p info
}

if [ ! -f "$SRC" ] || [ ! -f "$DST" ]; then
    # Container not ready / paths not present yet -- next timer tick will retry.
    exit 0
fi

if ! mountpoint -q "$DST"; then
    log "audio.primary.default.so bind-mount missing, re-applying"
    if mount --bind "$SRC" "$DST" 2>/dev/null; then
        log "bind-mount restored"
    else
        log "failed to restore bind-mount, will retry next timer tick"
    fi
fi
