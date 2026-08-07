#!/bin/sh
# 2026-07-16: 32-bit bionic libc's pthread_mutex_t cannot encode a PID
# above 65535 (see "Limited by the size of pthread_mutex_t..." in
# logcat) -- once the kernel's running PID counter climbs past that on
# a long-lived boot (accumulates fast: every app launch, every HAL
# restart, every crash-loop), crash_dump32 (Android's native crash
# reporter, /apex/com.android.runtime/bin/crash_dump32) starts
# aborting on its OWN startup instead of producing a tombstone. Since
# debuggerd's crash handler then tries to report THAT abort by
# launching another crash_dump32, which also aborts the same way, this
# becomes an infinite self-sustaining fork bomb -- confirmed live
# three times in one day (up to 17000+ processes, ~100k ANOM_ABEND
# events in a single boot), each time causing severe CPU/memory
# exhaustion, an unresponsive lockscreen, and in at least one case a
# hard reset (see watchdog fix notes -- our own kicker likely got
# starved of CPU during the storm and missed its window).
#
# There is no real fix for the underlying 32-bit PID limitation (it is
# a genuine bionic/kernel constraint, not something patchable from
# here) -- stripping exec permission from crash_dump32/64 makes every
# future crash fail cleanly (ENOENT-style exec failure, no tombstone)
# instead of recursively forking. This is a real, if blunt, tradeoff:
# we lose native crash tombstones entirely, in exchange for the device
# no longer being able to melt down from this specific storm. Must be
# reapplied every boot -- /apex is (re)mounted fresh from a signed
# package each time, so a chmod does not persist on its own.

for i in $(seq 1 30); do
    if lxc-attach -n android -- test -e /apex/com.android.runtime/bin/crash_dump32 2>/dev/null; then
        lxc-attach -n android -- chmod 000 /apex/com.android.runtime/bin/crash_dump32 2>/dev/null
        lxc-attach -n android -- chmod 000 /apex/com.android.runtime/bin/crash_dump64 2>/dev/null
        break
    fi
    sleep 1
done
