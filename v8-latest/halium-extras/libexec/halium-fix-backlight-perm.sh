#!/bin/sh
# Same pattern as halium-fix-torch-perm.sh: the backlight brightness
# control that Lomiri's brightness slider writes to as the phablet user
# is owned system:system (0664) with no group phablet belongs to
# granted write access -- direct unprivileged write as phablet fails
# with "Permission denied" (confirmed 2026-07-15), so the slider
# silently does nothing even though the kernel/panel driver itself
# works fine (a root-privileged write does actually change brightness).

for i in $(seq 1 30); do
    if [ -e /sys/class/backlight/panel0-backlight/brightness ]; then
        chown phablet /sys/class/backlight/panel0-backlight/brightness
        break
    fi
    sleep 1
done
