#!/bin/sh
# oFono's binder-based RIL plugin and Android's own com.android.phone app
# both try to hold an active IRadio session against the same rild
# instance -- com.android.phone (part of the normal Android framework,
# started by system_server/ActivityManagerService, NOT an init.rc
# service, so it can't be stopped via setprop ctl.stop like
# wpa_supplicant/wificond) wins that race and oFono's
# NetworkRegistration.Status gets stuck on "searching" forever, even
# though the SIM is read fine and rild itself is healthy.
#
# This port drives telephony entirely through oFono/telepathy-ofono, not
# through Android's own in-container dialer/telephony stack -- disabling
# com.android.phone here costs nothing functionally on this device and
# frees the IRadio session for oFono.
#
# Confirmed live 2026-07-15: `pm disable-user com.android.phone` (which
# also kills the currently-running instance) resolves NetworkRegistration.
# Status to "registered" within under a minute, with no other changes.
#
# `pm` needs the full Android framework (system_server/PackageManagerService)
# up, which takes a while after lxc-android-config.service itself reports
# started -- retry for a while rather than a single attempt. Idempotent:
# disabling an already-disabled package is a harmless no-op.

for i in $(seq 1 30); do
    if lxc-attach -n android -- pm disable-user --user 0 com.android.phone >/dev/null 2>&1; then
        break
    fi
    sleep 2
done
