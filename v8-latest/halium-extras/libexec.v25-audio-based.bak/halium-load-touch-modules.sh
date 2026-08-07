#!/bin/sh
for m in sec_tsp_log sec_secure_touch sec_common_fn sec_cmd sec_tclm_v2 sec_tsp_dumpkey synaptics_ts wlan camera; do
    insmod "/userdata/kernel-modules-fixed/${m}.ko" 2>/dev/null || true
done

# The synaptics_ts driver's input node comes up with "enabled=0" (confirmed
# 2026-07-06): normally an Android-side PowerManagerService "screen on" call
# flips this, but system_server doesn't reliably reach that point in our
# setup. Without it, the touch IC stays in a low-power/no-scan state -- IRQs
# barely fire and no coordinate data streams even though the driver is
# loaded. Force it on directly; retry briefly since the sysfs node only
# appears once the i2c device has actually probed.
for i in $(seq 1 20); do
    for f in /sys/devices/platform/soc/*/i2c-*/*-004b/input/input*/enabled; do
        [ -f "$f" ] && echo 1 > "$f" 2>/dev/null
    done
    sleep 1
done
