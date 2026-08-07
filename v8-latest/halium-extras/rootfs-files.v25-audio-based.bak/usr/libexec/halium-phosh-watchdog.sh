#!/bin/sh
# Detects the "phoc alive but no shell client" stuck state (compositor
# running with nothing to render -- physically stuck on the boot logo
# even though phoc itself never crashed) and restarts phosh.service to
# recover. Independent of phosh.service's own ExecStartPre/restart
# cycle by design -- a prior attempt to hook a similar recovery action
# directly into phosh.service's ExecStartPre re-triggered on every one
# of its own restarts and hung the device (see project HOWTO). This
# runs on its own timer instead (halium-phosh-watchdog.timer), so it is
# never in a position to retrigger itself.
#
# Stuck-state definition: phoc has been running for more than 90s AND
# no /usr/libexec/phosh (the actual shell client) process exists yet.
# The 90s threshold avoids false positives during phosh.service's own
# normal startup window, where phoc is briefly alive alone for a few
# seconds before gnome-session spawns the shell.

# Defensive: re-assert the executable bit on phoc every run, cheap and
# idempotent. Found live (2026-07-21, Fix 1 for в8) that
# phoc-0.47.0-old ships inside userdata-overlay.tar.gz without +x,
# which mount --bind then propagates onto /usr/bin/phoc, crash-looping
# phosh.service with "systemd-cat: Failed to execute process:
# Permission denied". update-binary now chmods the overlay copy once
# at flash time, but this is a second, always-on safety net in case it
# regresses again for any reason (e.g. a future overlay rebuild).
chmod 755 /userdata/phoc-downgrade-backup/phoc-0.47.0-old 2>/dev/null || true
chmod 755 /usr/bin/phoc 2>/dev/null || true

if systemctl is-failed --quiet phosh.service; then
    echo "$(date): phosh.service is in failed state, resetting and restarting" >> /userdata/halium-phosh-watchdog.log
    systemctl reset-failed phosh.service
    systemctl restart phosh.service
    exit 0
fi

PHOC_PID=$(pgrep -f '/usr/bin/phoc ' | head -1)
[ -n "$PHOC_PID" ] || exit 0

if pgrep -f '/usr/libexec/phosh$' >/dev/null 2>&1; then
    exit 0
fi

PHOC_ETIME=$(ps -o etimes= -p "$PHOC_PID" 2>/dev/null | tr -d ' ')
[ -n "$PHOC_ETIME" ] || exit 0

if [ "$PHOC_ETIME" -gt 90 ]; then
    echo "$(date): phoc PID $PHOC_PID alive ${PHOC_ETIME}s with no shell client, restarting phosh.service" >> /userdata/halium-phosh-watchdog.log
    systemctl restart phosh.service
fi
