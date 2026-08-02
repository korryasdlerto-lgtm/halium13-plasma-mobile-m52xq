#!/bin/sh
# 2026-07-16: found that when telepathy-ofono crashes (see fix docs --
# voip_tx dangling route reference in audio_policy_configuration.xml
# crashed pulseaudio mid-call, which took telepathy-ofono down with it,
# SIGSEGV), the telepathy account "ofono/ofono/account0" is lost entirely
# (~/.local/share/telepathy/mission-control/accounts.cfg goes back to
# empty) and is NOT recreated automatically -- ofono-setup.service
# deliberately skips account creation on this device (Android SDK 27+ /
# binder RIL path: "No modem detection will be made"), it assumes
# something else creates the account once at first boot and never needs
# to run again. The underlying modem (ofonod) stays registered the whole
# time -- only the telepathy bridge to the UI is lost, showing as
# "network not found" / no signal in the indicator, and calls silently
# fail to ever ring anything.
#
# This does NOT fix why telepathy-ofono crashes in the first place (the
# voip_tx fix addresses the one root cause found so far) -- it's a safety
# net so that IF it crashes again for any other reason, the phone doesn't
# need a manual `mc-tool add` (or a full reboot) to get network/calls
# back.

LOG_TAG="halium-telepathy-ofono-account-watchdog"
CHECK_INTERVAL=15
MODEM_PATH=/ril_0
ACCOUNT=ofono/ofono/account0

log() {
    echo "$LOG_TAG: $1" | systemd-cat -t "$LOG_TAG" -p info
}

sleep 45

while true; do
    sleep "$CHECK_INTERVAL"

    modem_status=$(dbus-send --system --print-reply --reply-timeout=3000 \
        --dest=org.ofono "$MODEM_PATH" org.ofono.NetworkRegistration.GetProperties 2>/dev/null \
        | grep -A1 'string "Status"' | tail -1 | sed -n 's/.*string "\(.*\)"/\1/p')

    # Only act when the modem itself genuinely has a network -- no point
    # recreating a telepathy account if there's no real registration to
    # expose anyway (e.g. no SIM, airplane mode, out of coverage).
    case "$modem_status" in
        registered|roaming) ;;
        *) continue ;;
    esac

    account_exists=$(mc-tool list 2>/dev/null | grep -c "^${ACCOUNT}\$")

    if [ "$account_exists" -eq 0 ]; then
        log "modem is registered ($modem_status) but telepathy account $ACCOUNT is missing -- recreating"
        mc-tool add ofono/ofono "SIM 1" string:modem-objpath="$MODEM_PATH" >/dev/null 2>&1
        mc-tool enable "$ACCOUNT" >/dev/null 2>&1
        mc-tool auto-connect "$ACCOUNT" on >/dev/null 2>&1
        mc-tool request "$ACCOUNT" available >/dev/null 2>&1
        log "recreated $ACCOUNT"
    fi
done
