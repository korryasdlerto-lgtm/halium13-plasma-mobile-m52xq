#!/bin/sh
# lxc-android-config.service can get stuck indefinitely: zygote inside the
# Android container sometimes crash-loops with a genuine ART bug
# ("NoClassDefFoundError: Class not found using the boot class loader"
# during SystemServiceRegistry preload) instead of settling, which leaves
# lxc-android-ready's property-service wait blocked forever (the unit's own
# TimeoutStartSec=0 is intentional, so a slow-but-healthy boot never gets
# killed prematurely). Watch init.svc.zygote directly: if it sits in
# "restarting" continuously for 30s, this attempt is wedged -- force a
# fresh container restart rather than waiting forever.
#
# IMPORTANT: this device has no RTC battery and its wall clock jumps
# around wildly during early boot (seen jumping 1974 -> 2021 -> 2026 and
# back within the same boot). `date +%s` is NOT safe for measuring
# elapsed time here -- a backward jump makes "now - stuck_since" go
# negative and the 30s threshold may never trip. Use /proc/uptime
# (monotonic, unaffected by wall-clock changes) instead.
now_ms() {
    awk '{print int($1 * 1000)}' /proc/uptime
}

ATTEMPTS=4
attempt=1
while [ "$attempt" -le "$ATTEMPTS" ]; do
    systemctl start lxc-android-config.service &
    START_PID=$!

    STUCK_SINCE=""
    ATTEMPT_START_MS=$(now_ms)
    while kill -0 "$START_PID" 2>/dev/null; do
        state=$(lxc-attach -n android -- getprop init.svc.zygote 2>&1)
        now=$(now_ms)
        # НАЙДЕНО 2026-07-18: с тех пор как /init реально стартует, он
        # сам крашится/ребутится ВНУТРИ lxc-start (LXC обрабатывает
        # "Container requested reboot" не выходя из процесса) -- zygote
        # property НИКОГДА не успевает стать "restarting" (init падает
        # раньше, чем property-сервис вообще поднимается), так что
        # ВЕСЬ существующий zygote-based watchdog ниже никогда не
        # срабатывает, и "systemctl start" в фоне висит бесконечно.
        # Отдельный, безусловный таймаут по общему времени попытки --
        # не зависит от того, что показывает zygote property.
        if [ $((now - ATTEMPT_START_MS)) -ge 60000 ]; then
            echo "$(date) uptime=$(cat /proc/uptime) attempt=$attempt HARD TIMEOUT 60s (init self-reboot loop, zygote watchdog never triggered) -- forcing stop" >> /var/log/lxc-poll-diag.log 2>&1
            systemctl stop lxc-android-config.service 2>/dev/null
            systemctl reset-failed lxc-android-config.service 2>/dev/null
            break
        fi
        lxcinfo=$(lxc-info -n android 2>&1)
        lxcpid=$(lxc-info -n android -p -H 2>/dev/null)
        {
            echo "$(date) uptime=$(cat /proc/uptime) attempt=$attempt state=[$state]"
            echo "  lxc-info: $(echo "$lxcinfo" | tr '\n' '|')"
            if [ -n "$lxcpid" ] && [ -d "/proc/$lxcpid" ]; then
                echo "  status: $(tr '\n' ';' < /proc/$lxcpid/status 2>/dev/null | head -c 400)"
                echo "  stack:  $(cat /proc/$lxcpid/stack 2>&1 | tr '\n' '|')"
                echo "  wchan:  $(cat /proc/$lxcpid/wchan 2>&1)"
                echo "  container init cmdline: $(tr '\0' ' ' < /proc/$lxcpid/root/proc/1/cmdline 2>/dev/null)"
            fi
            echo "  ps of lxc-start/init on host: $(ps -eo pid,ppid,stat,comm 2>/dev/null | grep -i 'lxc-start\|lxc-\|env -i' | tr '\n' '|')"
        } >> /var/log/lxc-poll-diag.log 2>&1
        if [ "$state" = "restarting" ]; then
            if [ -z "$STUCK_SINCE" ]; then
                STUCK_SINCE=$now
                {
                    echo "=== zygote crash-loop logcat capture $(date) uptime=$(cat /proc/uptime) attempt=$attempt ==="
                    lxc-attach -n android -- logcat -b all -d 2>&1
                    echo "=== END logcat capture ==="
                } >> /var/log/zygote-crash-logcat.log 2>&1
                cp -f /var/log/zygote-crash-logcat.log /userdata/zygote-crash-logcat.log 2>/dev/null || true
            fi
            if [ $((now - STUCK_SINCE)) -ge 30000 ]; then
                systemctl stop lxc-android-config.service 2>/dev/null
                systemctl reset-failed lxc-android-config.service 2>/dev/null
                break
            fi
        else
            STUCK_SINCE=""
        fi
        sleep 2
    done
    cp -f /var/log/lxc-poll-diag.log /userdata/lxc-poll-diag.log 2>/dev/null || true

    wait "$START_PID" 2>/dev/null

    if systemctl is-active --quiet lxc-android-config.service; then
        exit 0
    fi

    systemctl stop lxc-android-config.service 2>/dev/null
    systemctl reset-failed lxc-android-config.service 2>/dev/null
    # Give the kernel a moment to fully release the previous container's
    # network namespace before retrying -- retrying too fast can hit
    # "Failed to allocate new network namespace id (File exists)" from a
    # not-yet-garbage-collected netns of the just-killed attempt.
    sleep 5
    attempt=$((attempt + 1))
done

# Final attempt: раньше -- "no watchdog, just let the unit's own
# TimeoutStartSec (still 0/infinite) be the last resort". Теперь, когда
# init реально ребутится ВНУТРИ lxc-start бесконечно, "0/infinite"
# значит РЕАЛЬНО бесконечно -- добавляем timeout, чтобы этот скрипт
# (и юнит halium-kickstart-lxc.service) гарантированно завершился,
# не блокируя остальной boot навсегда.
timeout 60 systemctl start lxc-android-config.service
systemctl stop lxc-android-config.service 2>/dev/null
systemctl reset-failed lxc-android-config.service 2>/dev/null
exit 1
