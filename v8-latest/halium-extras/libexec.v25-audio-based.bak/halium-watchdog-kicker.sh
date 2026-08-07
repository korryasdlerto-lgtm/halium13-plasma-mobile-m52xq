#!/bin/sh
# The bootloader leaves /dev/watchdog armed (confirmed via dmesg: "watchdog:
# watchdog0: watchdog did not stop!" a few seconds into kernel uptime) and
# nothing in the Halium boot flow ever normally pets it (that job is done by
# an Android-side service on a stock boot, which we never reach). Without
# petting, the hardware resets the SoC completely silently (no panic/oops)
# at a fixed ~100-103s mark. This exact fix (device path, open mode, byte
# written, interval) was already found and confirmed working once before,
# 2026-07-05 (v22) -- lost somewhere before this session's system.img
# rebuild. Re-added 2026-07-10. Note the device is /dev/watchdog (misc
# 10,130), NOT /dev/watchdog0 (242,0, a different driver/interface) -- an
# earlier attempt this same session fed the wrong node and had no effect.
# FOUND 2026-07-19/20 (previous session, cross-referenced 2026-07-21):
# sleep 2 leaves too large a gap between kicks -- during heavy I/O
# stalls (Android LXC container startup: cgroup/netns setup, mounting
# large *-patched.jar files) a single missed window is enough to hit
# the ~100-103s hardware watchdog deadline. Confirmed live: switching
# to sleep 0.3 let the device survive 5+ minutes with zero reboots in
# a controlled test where it had previously been rebooting every
# attempt; forgetting to reapply this fix (reverting to sleep 2) was
# independently confirmed as the actual cause of a string of spontaneous
# reboots that had been misattributed to GPU/DRM work at the time.
exec 3<>/dev/watchdog
while true; do
    printf '.' >&3
    sleep 0.3
done
