#!/bin/sh
# On a genuinely fresh boot, halium-bounce-composer.sh's single
# once-per-boot composer bounce can occasionally fire before the
# Android composer HAL is truly ready, leaving lightdm stuck in a
# fast crash loop ("failed to create composer client" on every
# attempt, since the marker prevents any further bounce). Recovering
# by hand is: stop lightdm, clear the bounce marker, truncate the
# compositor log, start lightdm -- which forces one fresh full
# bounce+wait cycle.
#
# This script does that SAME recovery, but only ONCE per boot and
# only if lightdm is genuinely thrashing (several restarts within a
# short window) -- NOT a tight per-attempt bounce loop like the one
# that caused a kernel panic earlier in this project (see
# ФИКСЫ_ДЛЯ_В35.txt, "ОПАСНЫЙ ИНЦИДЕНТ"). One deliberate recovery
# attempt, then this script exits for good.
#
# IMPORTANT: this device has no RTC battery, wall clock jumps around
# during early boot -- use /proc/uptime, not date, for timing.
now_ms() {
    awk '{print int($1 * 1000)}' /proc/uptime
}

# Two checkpoints: an early one (catches the common case fast) and a
# later one at ~100s (catches boots that keep thrashing past the
# first recovery attempt, or past a slower natural stabilization --
# observed once needing 28 restarts before settling on its own).
# Each checkpoint can fire the recovery cycle AT MOST ONCE, and only
# if lightdm is still not active by then -- so at most 2 recovery
# actions total, minutes apart, never a tight per-attempt loop.
THRESHOLD_RESTARTS=3
POLL_MS=2000
CHECKPOINTS_MS="45000 100000"

recover() {
    systemctl stop lightdm.service
    rm -f /run/halium-composer-bounced
    : > /var/log/lightdm/unity-system-compositor.log 2>/dev/null || true
    systemctl start lightdm.service
}

# A Type=notify service in a fast crash loop can report ActiveState=active
# for a brief instant right before it dies and restarts again -- a single
# check is not reliable enough to conclude "stable". Confirm by checking
# twice, 3s apart, and requiring active BOTH times.
is_stable() {
    [ "$(systemctl show lightdm.service -p ActiveState --value 2>/dev/null)" = "active" ] || return 1
    sleep 3
    [ "$(systemctl show lightdm.service -p ActiveState --value 2>/dev/null)" = "active" ]
}

start=$(now_ms)
for checkpoint in $CHECKPOINTS_MS; do
    while true; do
        now=$(now_ms)
        elapsed=$((now - start))
        [ "$elapsed" -ge "$checkpoint" ] && break

        is_stable && exit 0

        sleep_s=$(awk -v ms="$POLL_MS" 'BEGIN{printf "%.1f", ms/1000}')
        sleep "$sleep_s"
    done

    is_stable && exit 0

    restarts=$(systemctl show lightdm.service -p NRestarts --value 2>/dev/null)
    if [ -n "$restarts" ] && [ "$restarts" -ge "$THRESHOLD_RESTARTS" ] 2>/dev/null; then
        recover
        # Give the fresh cycle a few seconds before the next checkpoint
        # re-checks, so it isn't immediately judged against its own
        # brand-new (low) restart counter.
        sleep 5
    fi
done
exit 0
