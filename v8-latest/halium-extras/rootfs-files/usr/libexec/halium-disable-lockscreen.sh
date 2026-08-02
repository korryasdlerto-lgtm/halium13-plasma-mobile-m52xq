#!/bin/sh
# Disables the Phosh lockscreen unlock-code requirement on first boot.
# Idempotent: reads current value first, only writes if still True.
# Independent of phosh.service's own restart cycle (triggered once via
# multi-user.target, not hooked into phosh.service ExecStartPre) --
# a previous attempt to hook touch/unlock fixes into phosh.service
# ExecStartPre caused repeated re-triggering on every phosh restart and
# hung the device; this script avoids that class of bug entirely.

i=0
while [ $i -lt 30 ]; do
  [ -S /run/user/1000/bus ] && break
  sleep 1
  i=$((i + 1))
done

[ -S /run/user/1000/bus ] || exit 0

su phablet -c 'XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus python3 -c "
import gi
gi.require_version(\"Gio\", \"2.0\")
from gi.repository import Gio
s = Gio.Settings.new(\"sm.puri.phosh.lockscreen\")
if s.get_boolean(\"require-unlock\"):
    s.set_boolean(\"require-unlock\", False)
    Gio.Settings.sync()
"'
