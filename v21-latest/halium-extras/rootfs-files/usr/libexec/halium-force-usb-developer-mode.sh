#!/bin/sh
# usb_moded's own default-mode logic refuses 'developer_mode' for uid 0
# ("default mode 'developer_mode' is not valid for uid '0', reset to
# 'ask'"), so it always falls back to a safe mode (mass_storage/charging)
# on boot. Force it explicitly via D-Bus instead, then rebind the UDC so
# the host actually re-enumerates with the new (rndis-included) gadget
# composition -- usb_moded accepts the mode change internally but does not
# perform a live gadget rebuild while the cable is already connected.
#
# FOUND 2026-08-02 (в8): root cause of the ~3s rndis.usb0 -> mass_storage
# revert cycle documented at length below -- confirmed via `strings` on
# /usr/sbin/usb_moded that 'developer_mode' is internally usb_moded's own
# built-in RESCUE mode (usbmoded_set_rescue_mode/in_rescue_mode, tied to
# the -r/--rescue and --max-cable-delay=<ms> flags). Rescue mode is BY
# DESIGN a temporary timed grant, not a persistent mode -- every fix
# attempted below was fighting that timer, not a bug. 'rndis_adb' is a
# separate, ordinary (non-rescue) mode already defined in this rootfs
# (etc/usb-moded/dyn-modes/rndis_adb.ini.in, sysfs_value=rndis,adb) that
# isn't subject to the rescue timer. Switched the forced mode below from
# developer_mode to rndis_adb.
#
# FOUND 2026-08-02 (в8, later same day): live test of rndis_adb was WORSE
# than developer_mode -- host saw continuous mass_storage (1209:0afe)
# re-enumeration every ~1s for 4+ minutes straight, RNDIS (1209:0004)
# never appeared even once (developer_mode at least settled into a
# stable mass_storage after ~3-9s). rndis_adb combines TWO gadget
# functions (rndis + ffs.adb) in one composition -- if the adb function
# side can't come up cleanly (adbd not ready to open its ffs endpoint
# yet?), the whole composite config may be failing and retrying forever
# instead of degrading to a stable state. Switched to plain 'rndis'
# (etc/usb-moded/dyn-modes/rndis.ini.in, sysfs_value=rndis only, single
# function) to remove that interaction -- not yet live-tested.
LOG=/userdata/usb-force-devmode.log
exec >> "$LOG" 2>&1
echo "=== $(date) uptime=$(cat /proc/uptime) ==="

i=0
while [ $i -lt 20 ]; do
    state=$(systemctl show usb-moded -p ActiveState --value 2>/dev/null)
    [ "$state" = "active" ] && break
    sleep 1
    i=$((i+1))
done
echo "usb-moded ActiveState=$state after ${i}s"

# usb_moded keeps churning through its own internal default-mode fallback
# resolution for several seconds after ActiveState=active fires (its own
# "no network gateway" / "reset to ask" self-resolution) -- calling
# set_mode while that's still in flight gets a generic Error.Failed. v2's
# own history found "~10s past ActiveState=active was reliable" -- but
# that was BEFORE this device's dyn-modes/*.ini templates were actually
# rendering (envsubst was missing for this whole project until 2026-07-21,
# see DROIDIAN-V5-SYSTEMD-FIX-HOWTO.md) -- now that usb_moded has real
# modes to resolve between, its own self-resolution may genuinely take
# longer. Retry set_mode itself with backoff instead of a single
# fixed-delay shot, and log each attempt's reply so this is visible on
# the next live test either way.
sleep 10

# FOUND 2026-07-21 (cross-referenced from the SEPARATE Ubuntu Touch/Lomiri
# project on this same device, project_halium_ssh_network_death_solved.md):
# usb_moded has a BUILT-IN rescue-mode cycle (mass-storage 1209:0afe <->
# working RNDIS 1209:0004, externally indistinguishable from "SSH randomly
# comes and goes") that only stops once it receives TWO specific D-Bus
# BROADCAST SIGNALS (not method calls) from turn-usb-rescue-mode-off:
# com.nokia.startup.signal.{runlevel_switch_done,init_done}. This rootfs
# already ships usb-early-init-done.service (WantedBy=multi-user.target,
# Requires=usb-moded.service) which sends exactly these -- BUT it's
# Type=oneshot with no re-trigger, so if THAT particular usb-moded.service
# instance later crashes and restarts (which it does, repeatedly, before
# stabilizing on this device -- see DROIDIAN-V5-SYSTEMD-FIX-HOWTO.md), the
# signal was sent to a listener that's now gone; D-Bus signals aren't
# queued for future subscribers, so the NEW usb_moded process never
# received it and reverts to cycling through rescue mode again. The
# dwc3_gadget_suspend_interrupt/"USB Resume end" pairs seen recurring
# every ~30-40s in pstore, even after disabling kernel-level UDC
# autosuspend below, are consistent with this rescue-mode cycle rather
# than genuine USB power management. Re-send both signals here, ourselves,
# AFTER usb-moded is confirmed stable (same timing guarantee our own
# set_mode calls already rely on) -- this targets the specific usb_moded
# process that's actually running right now, not whichever one happened
# to be alive when usb-early-init-done.service fired once, earlier,
# possibly against a since-crashed instance.
if [ -x /usr/libexec/usb-moded/turn-usb-rescue-mode-off ]; then
    timeout 5 /usr/libexec/usb-moded/turn-usb-rescue-mode-off 2>&1
    echo "turn-usb-rescue-mode-off re-run status=$?"
else
    timeout 5 dbus-send --system --type=signal /com/nokia/startup/signal com.nokia.startup.signal.runlevel_switch_done "int32:5" 2>&1
    timeout 5 dbus-send --system --type=signal /com/nokia/startup/signal com.nokia.startup.signal.init_done "int32:5" 2>&1
    echo "rescue-mode-off signals sent directly (script not found)"
fi

# EXPERIMENTAL 2026-07-21: set_mode/set_whitelisted (singular) keep
# getting silently reverted by usb_moded's own internal re-validation
# on a very regular ~6s cadence, independent of anything this script
# does (confirmed via /userdata/usb-monitor.log: the drift interval was
# identical before and after adding a repeated set_whitelisted call).
# usb_moded's own D-Bus interface (per `strings` on the binary) also
# exposes set_whitelisted_modes (PLURAL) alongside get_whitelisted_modes
# -- this looks like it replaces the *entire* persistent whitelist array
# rather than toggling one mode transiently, which may be what's needed
# to actually stick instead of getting re-evaluated away. Signature
# unconfirmed (no introspection XML found in the binary's strings) --
# this is a low-risk additional attempt (logged, not relied upon alone):
# if the type signature is wrong, dbus-send just reports an error here,
# it doesn't affect the set_whitelisted/set_mode calls that follow.
timeout 5 dbus-send --system --print-reply --dest=com.meego.usb_moded /com/meego/usb_moded com.meego.usb_moded.set_whitelisted_modes array:string:"rndis","rndis_adb","developer_mode","mtp","mass_storage","charging_only" 2>&1

timeout 5 dbus-send --system --print-reply --dest=com.meego.usb_moded /com/meego/usb_moded com.meego.usb_moded.set_whitelisted string:rndis boolean:true

i=0
while [ $i -lt 6 ]; do
    result=$(timeout 5 dbus-send --system --print-reply --dest=com.meego.usb_moded /com/meego/usb_moded com.meego.usb_moded.set_mode string:rndis 2>&1)
    echo "set_mode attempt $((i+1)): $result"
    case "$result" in
        *Error.Failed*) sleep 5; i=$((i+1)) ;;
        *) break ;;
    esac
done
sleep 1

current_c1=$(ls /sys/kernel/config/usb_gadget/g1/configs/c.1 2>&1 | grep -v '^total\|^MaxPower\|^bmAttributes')
echo "c.1 after set_mode (before any rebind): $current_c1"

# FOUND 2026-07-21 (live test): a successful set_mode now updates the live
# gadget descriptor ON ITS OWN (c.1 already shows rndis.usb0 right here,
# BEFORE the manual UDC unbind/rebind below ever runs) -- this differs
# from the assumption this rebind trick was originally written under (see
# top-of-file comment / v2 doc: "set_mode doesn't rebuild the live
# descriptor while the cable is connected"). Forcing the unbind/rebind
# anyway now ACTIVELY BREAKS a config that's already correct: it made
# usb_moded re-run its own self-resolution and fall back to mass_storage
# again ("after rebind: c.1=mass_storage.usb0" on every live test so far,
# even when "before rebind" was already rndis.usb0). Only do the
# unbind/rebind dance if set_mode genuinely left the old config in place.
case "$current_c1" in
    *rndis.usb0*)
        echo "c.1 already rndis.usb0 -- skipping unbind/rebind (would break it)"
        ;;
    *)
        echo '' > /sys/kernel/config/usb_gadget/g1/UDC 2>/dev/null
        sleep 2
        ls /sys/class/udc > /sys/kernel/config/usb_gadget/g1/UDC 2>/dev/null
        sleep 1
        echo "after rebind: c.1=$(ls /sys/kernel/config/usb_gadget/g1/configs/c.1 2>&1 | grep -v '^total\|^MaxPower\|^bmAttributes')"
        ;;
esac

# FOUND 2026-07-21 (live test, same boot as the rebind fix above):
# usb-moded-ssh.service still failed after c.1=rndis.usb0 was confirmed
# correct -- "Bind to port 8022 on 10.15.19.82 failed: Cannot assign
# requested address". The RNDIS gadget function is active at the configfs
# level, but nothing has actually put 10.15.19.82 on the resulting
# network interface -- that's normally usb_moded's own appsync/network
# setup, which (like usb-moded-ssh.service's own start below) doesn't
# fire for this D-Bus-forced mode switch. The configfs function name
# "rndis.usb0" maps directly to network interface "usb0" (standard
# Linux USB gadget configfs naming), matching the network/ip=10.15.19.82
# in etc/usb-moded/10-ubports-defaults.ini. Assign it explicitly,
# idempotent (`ip addr add` on an already-assigned address just warns,
# doesn't error the script).
ip link set usb0 up 2>&1
ip addr add 10.15.19.82/24 dev usb0 2>&1
echo "usb0 addr: $(ip addr show usb0 2>&1)"

# FOUND 2026-07-21 (live test, same boot): the UDC's runtime PM
# (/sys/class/udc/*/power/control, default "auto") lets the kernel
# autosuspend the USB link after inactivity -- confirmed via pstore:
# "dwc3_gadget_suspend_interrupt" / "USB Resume end" pairs recurring
# every ~30-40s throughout the whole boot, right up until the very last
# log line before a manual reboot. Each cycle briefly drops the link at
# the electrical level, which is a very plausible cause of the host
# seeing the RNDIS interface flicker/disappear (some hosts don't cleanly
# recover a resumed RNDIS composite function without a full
# re-enumeration). Disable autosuspend on the actual UDC device so the
# link stays continuously active instead of cycling.
for udc in /sys/class/udc/*/; do
    [ -w "${udc}power/control" ] && echo on > "${udc}power/control" 2>&1
    echo "udc autosuspend control ($udc): $(cat "${udc}power/control" 2>&1)"
done

# The appsync post-hook that would normally start usb-moded-ssh.service on
# a genuine cable-connect event doesn't fire for this D-Bus-forced switch,
# so start it explicitly.
timeout 5 systemctl start usb-moded-ssh.service
echo "usb-moded-ssh start status=$?"
echo "--- systemctl status usb-moded-ssh ---"
timeout 5 systemctl status usb-moded-ssh.service 2>&1
echo "--- journalctl -u usb-moded-ssh -b ---"
timeout 5 journalctl -u usb-moded-ssh -b --no-pager -n 100 2>&1
echo "--- ssh-generate-hostkeys direct run ---"
/usr/bin/ssh-generate-hostkeys 2>&1
echo "exit=$?"
echo "--- sshd -t direct run ---"
/usr/sbin/sshd -t 2>&1
echo "exit=$?"
ls -la /etc/ssh/ 2>&1

# FOUND 2026-07-21 (after repeated live tests): everything above is a
# ONE-SHOT setup, but the actual state keeps drifting afterward on its
# own -- usb_moded's rescue-mode cycle can re-trigger, the UDC's power
# state can flap, usb-moded-ssh.service can crash/restart -- and since
# this whole unit is Type=oneshot (see [Install] section of the .service
# file, now changed to Type=simple + Restart=always so THIS script keeps
# running for the unit's whole lifetime instead of exiting after one
# pass), nothing was left running to catch and fix any of that after the
# initial setup completed. Replace the previous one-shot exit with a
# continuous supervisor loop: re-check the same conditions above every
# few seconds for the rest of boot, log only STATE CHANGES (not every
# poll, to keep the log readable), and re-apply whichever fix is needed
# the moment something drifts, instead of waiting for a human to notice
# and force another full reboot cycle.
MONLOG=/userdata/usb-monitor.log
exec 4>>"$MONLOG"
echo "=== monitor loop starting $(date) uptime=$(cat /proc/uptime) ===" >&4

# ADDED 2026-07-21: the ~3.07s rndis.usb0 -> mass_storage.usb0 revert
# persists even on a usb_moded instance that has been stable (no restart)
# for over a minute AND already received the rescue-mode-off signal
# (confirmed live: /userdata/usb-moded-debug.log showed a single
# "INIT DONE in 8.12s" with zero further restarts, yet /userdata/
# usb-monitor.log kept showing the same ~3.1s grant/revert cycle for the
# next 90+ seconds after that). The crash-loop/rescue-mode theory is
# therefore NOT the (sole) cause of the periodic revert. usb_moded's own
# binary exposes umudev_cable_state_start_timer/stop_timer/timer_cb and a
# --max-cable-delay option -- this looks like a udev-driven cable-state
# debounce that could be re-firing on real recurring udev events (the
# sm5714 charger driver's periodic polling is a live suspect). Capture a
# live udevadm feed, timestamped against the same /proc/uptime clock as
# usb-monitor.log, so the next drift event can be directly correlated
# against real kernel/udev activity instead of guessed at.
UDEVLOG=/userdata/usb-udev-monitor.log
(udevadm monitor --udev --property 2>&1 | while IFS= read -r udevline; do
    echo "$(cat /proc/uptime | cut -d' ' -f1) $udevline"
done >> "$UDEVLOG") &
echo "udev monitor capture started, pid=$!" >&4

# ADDED 2026-07-21 (same investigation): the udev capture above caught a
# real hardware-level burst right at each revert -- /devices/virtual/
# android_usb/android0 (legacy interface, previously assumed absent on
# this Qualcomm chip -- it is NOT) cycling DISCONNECTED/CONNECTED/
# DISCONNECTED/CONNECTED/CONFIGURED within ~500ms, plus a "change" uevent
# on the actual UDC (a600000.dwc3) at the same instant. This is a real
# electrical/kernel-level re-enumeration, not usb_moded reacting in
# software. dmesg from the same window should show which kernel driver
# is actually initiating it (msm-dwc3, or the Type-C/PD manager -- dmesg
# during an earlier TWRP boot showed "TCM: manager_usb_enum_state_check_
# work", a Samsung Type-C manager periodic watchdog, as a live suspect).
# Capture dmesg -k (kernel's own timestamps, directly comparable to the
# uptime-based stamps used everywhere else in this script) continuously.
DMESGLOG=/userdata/usb-dmesg-monitor.log
(dmesg -w 2>&1 >> "$DMESGLOG") &
echo "dmesg monitor capture started, pid=$!" >&4

# ADDED 2026-07-21 (same investigation, deeper): dmesg confirmed
# android_work()/config_usb_cfg_link are just configfs's OWN uevent
# notifier -- part of the SAME driver, not an independent competitor.
# The device_check_sec=3 watchdog in usb_notify.c (kernel/samsung/sm7325/
# drivers/usb/notify/usb_notify.c, device_connect_check(), hardcoded
# .device_check_sec = 3 in usb_notifier.c/usb_notifier_qcom.c) looked
# like an exact match for the ~3.1s timing, but its own pr_info never
# appeared in the captured dmesg, AND NOTIFY_EVENT_DEVICE_CONNECT (the
# only thing that defuses it) is only ever sent from dock_notify.c --
# i.e. this watchdog is a HOST-mode/dock mechanism, not applicable to
# our peripheral/gadget RNDIS scenario at all. Ruled out.
# So the revert to mass_storage is caused by SOMETHING writing a new
# function symlink into configs/c.1 -- but our own dbus-send calls are
# the only D-Bus traffic we've been logging (only OUR OWN method calls
# and their replies, not the whole bus). usb_moded's binary exposes
# umudev_cable_state_start_timer/stop_timer/timer_cb (found via strings
# earlier) -- if usb_moded reverts the mode via its OWN internal C code
# path (not through its external D-Bus API), we would never see it in
# our targeted dbus-send logging. Capture the ENTIRE system bus instead
# of just our own calls, to either catch an external actor or prove
# there is none (pointing conclusively at usb_moded's internal logic).
DBUSLOG=/userdata/usb-dbus-monitor.log
(dbus-monitor --system 2>&1 | while IFS= read -r dbusline; do
    echo "$(cat /proc/uptime | cut -d' ' -f1) $dbusline"
done >> "$DBUSLOG") &
echo "dbus-monitor (full system bus) capture started, pid=$!" >&4

prev_c1="_init_"
prev_ip="_init_"
prev_ssh="_init_"
prev_pm="_init_"

# FOUND 2026-07-21 (live test): the whole supervisor loop went silent
# at uptime=34s (no more lines in usb-monitor.log) while the REST of the
# system stayed alive for another ~1450s (confirmed via the separately-
# backgrounded dmesg -w capture, which kept logging the whole time, and
# pstore showing no panic/watchdog reset -- only an eventual power-key
# press by the user). The background captures (udevadm/dmesg/dbus-
# monitor, all backgrounded with &) survived; only this foreground
# while-loop froze. None of systemctl/dbus-send/turn-usb-rescue-mode-off
# below had a timeout -- under the heavier load of the now-actually-
# running Android container, any one of them blocking indefinitely
# (D-Bus/systemd contention) would silently wedge the whole loop with
# no trace in the log (the process stays alive, so Restart=always never
# retriggers). Wrap every command that talks to systemd/D-Bus in
# `timeout N`.
i=0
while [ $i -lt 3600 ]; do
    now=$(cat /proc/uptime | cut -d' ' -f1)
    c1=$(ls /sys/kernel/config/usb_gadget/g1/configs/c.1 2>/dev/null | grep -v '^total\|^MaxPower\|^bmAttributes' | tr '\n' ',')
    ipaddr=$(ip -4 addr show usb0 2>/dev/null | grep -o 'inet [0-9.]*' | cut -d' ' -f2)
    sshstate=$(timeout 5 systemctl show usb-moded-ssh -p ActiveState --value 2>/dev/null)
    pmstate=$(cat /sys/class/udc/*/power/control 2>/dev/null | head -1)

    if [ "$c1" != "$prev_c1" ] || [ "$ipaddr" != "$prev_ip" ] || [ "$sshstate" != "$prev_ssh" ] || [ "$pmstate" != "$prev_pm" ]; then
        echo "$now c.1=[$c1] ip=[$ipaddr] ssh=[$sshstate] pm=[$pmstate]" >&4
    fi

    # FOUND 2026-07-21 (tested and DISPROVEN): tried requiring 5
    # consecutive bad polls before intervening (hypothesis: our own
    # immediate reaction was preventing natural settling). Live result:
    # WITHOUT intervention, c.1 does NOT keep flickering on its own --
    # it flips to mass_storage.usb0 ONCE after each set_mode grant
    # expires and then sits there, stable, doing nothing further, until
    # we call set_mode again. So the "settling" the delay gave it a
    # chance to reach was the WRONG stable state (mass_storage), not
    # rndis. Confirmed: each set_mode grants almost exactly ~3s of
    # rndis.usb0 no matter how long we wait before re-asserting it --
    # waiting longer before fixing just means more time stuck in
    # mass_storage for no benefit. Reverted to reacting on the very
    # first bad poll (best available online-time ratio measured so far,
    # ~50% vs ~14% with the 5-poll delay) while we look for a way to
    # actually extend the grant itself instead of just re-requesting it
    # faster.
    case "$c1" in
        *rndis.usb0*) : ;;
        *)
            echo "$now DRIFT: c.1 not rndis.usb0 -- re-applying rescue-off + set_whitelisted + set_mode" >&4
            if [ -x /usr/libexec/usb-moded/turn-usb-rescue-mode-off ]; then
                timeout 5 /usr/libexec/usb-moded/turn-usb-rescue-mode-off >&4 2>&1
            fi
            timeout 5 dbus-send --system --print-reply --dest=com.meego.usb_moded /com/meego/usb_moded com.meego.usb_moded.set_whitelisted string:rndis boolean:true >&4 2>&1
            timeout 5 dbus-send --system --print-reply --dest=com.meego.usb_moded /com/meego/usb_moded com.meego.usb_moded.set_mode string:rndis >&4 2>&1
            ;;
    esac

    if [ -z "$ipaddr" ]; then
        echo "$now DRIFT: usb0 has no IP -- re-adding 10.15.19.82/24" >&4
        ip link set usb0 up >&4 2>&1
        ip addr add 10.15.19.82/24 dev usb0 >&4 2>&1
    fi

    if [ "$pmstate" != "on" ] && [ -n "$pmstate" ]; then
        echo "$now DRIFT: UDC power/control=$pmstate -- forcing on" >&4
        for udc in /sys/class/udc/*/; do
            [ -w "${udc}power/control" ] && echo on > "${udc}power/control" 2>/dev/null
        done
    fi

    if [ "$sshstate" != "active" ]; then
        echo "$now DRIFT: usb-moded-ssh ActiveState=$sshstate -- restarting" >&4
        timeout 5 systemctl restart usb-moded-ssh.service >&4 2>&1
    fi

    prev_c1="$c1"; prev_ip="$ipaddr"; prev_ssh="$sshstate"; prev_pm="$pmstate"
    sleep 1
    i=$((i+1))
done
echo "=== monitor loop ending (max iterations reached) $(date) uptime=$(cat /proc/uptime) ===" >&4
