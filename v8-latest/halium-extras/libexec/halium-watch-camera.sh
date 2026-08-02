#!/bin/sh
# vendor.camera-provider-2-6 crashes in a hard loop due to missing EFS
# multi-cam calibration data on this device (root cause documented, not
# fixable in software). Repeated stop/start cycling sometimes clears a
# stuck ICP subdev fd from a previous crashed instance, occasionally
# letting the next attempt succeed -- not reliably understood, best-effort
# mitigation only, not a guaranteed fix. Loop forever and re-kick on every
# fresh lxc-android-config.service active transition (it sometimes
# restarts mid-session, and a one-shot triggered-once unit never re-fires
# for that).
LAST_STATE=""
while true; do
    CUR_STATE=$(systemctl is-active lxc-android-config.service 2>/dev/null)
    if [ "$CUR_STATE" = "active" ] && [ "$LAST_STATE" != "active" ]; then
        sleep 20
        for i in 1 2 3 4 5; do
            sudo lxc-attach -n android -- sh -c 'stop vendor.camera-provider-2-6; sleep 1; start vendor.camera-provider-2-6' 2>/dev/null || true
            sleep 5
        done
    fi
    LAST_STATE="$CUR_STATE"
    sleep 3
done
