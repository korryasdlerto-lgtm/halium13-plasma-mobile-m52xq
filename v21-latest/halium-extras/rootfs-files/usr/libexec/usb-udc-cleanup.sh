#!/bin/sh
# Adapted from usb-moded-conf-wrapper.sh (Ubuntu Touch m52xq fix, late June
# 2026): TWRP leaves the UDC (a600000.dwc3) bound to whatever gadget config
# it set up, so the first configfs gadget assembly on real boot hits EBUSY.
# Force peripheral mode, explicitly unbind the UDC, and clear out any
# leftover config/function entries before handing off to the real
# configurator.
G=/sys/kernel/config/usb_gadget/g1
LOG=/var/log/usb-udc-cleanup.log
LOG2=/userdata/usb-udc-cleanup.log

log() {
    echo "$(date '+%H:%M:%S') $*" >> "$LOG" 2>/dev/null
    echo "$(date '+%H:%M:%S') $*" >> "$LOG2" 2>/dev/null
    echo "<6>usb-udc-cleanup: $*" > /dev/kmsg 2>/dev/null
}

log "=== wrapper START ==="

# FOUND 2026-07-21 (suggested by user while chasing the regular ~3-6s
# developer_mode revert): /var/lib/usb-moded/usb-moded.ini (usb_moded's
# own persistent state file, whitelist=developer_mode) was completely
# ABSENT from rootfs.img even after being created live via D-Bus -- most
# likely because usb_moded tries to persist its state back to this file
# after every mode change, that write silently fails if / is still
# mounted read-only at that point (this project's rootfs boots read-only
# by default, see halium-early-remount-rw.service elsewhere in this
# tree, which only guarantees rw ordering relative to systemd-journald,
# not relative to usb-moded.service), and a failed persist may be why
# the "temporary grant" observed live keeps expiring back to the uid-0
# safe default every few seconds instead of sticking. Force / rw here,
# unconditionally, before usb-moded's own config handling runs -- cheap
# and idempotent if it's already rw.
mount -o remount,rw / 2>>"$LOG2"
log "remount / rw status=$?"

if [ -d /sys/bus/platform/drivers/msm-dwc3 ]; then
    for dev in /sys/bus/platform/drivers/msm-dwc3/*/; do
        if [ -f "${dev}mode" ]; then
            log "dwc3 $(basename $dev): mode=$(cat ${dev}mode 2>/dev/null) -> peripheral"
            echo peripheral > "${dev}mode" 2>/dev/null
        fi
    done
    sleep 1
fi

if [ -d "$G" ]; then
    log "g1 exists, UDC=[$(cat $G/UDC 2>/dev/null)]"
    echo '' > "$G/UDC" 2>/dev/null || true
    i=0
    while [ "$(cat $G/UDC 2>/dev/null)" != "" ] && [ $i -lt 10 ]; do
        sleep 1; i=$((i+1))
    done
    log "UDC after unbind: [$(cat $G/UDC 2>/dev/null)] waited=${i}s"
    if [ -d "$G/configs/c.1" ]; then
        for lnk in "$G/configs/c.1/"*; do
            [ -L "$lnk" ] && rm -f "$lnk" 2>/dev/null && log "rm symlink: $lnk"
        done
    fi
    if [ -d "$G/functions" ]; then
        for f in "$G/functions/"*/; do
            [ -d "$f" ] && rmdir "$f" 2>/dev/null && log "rmdir func: $f"
        done
    fi
else
    log "g1 not found - fresh start"
fi

log "UDC list: $(ls /sys/class/udc 2>/dev/null)"

# /etc is read-only at runtime (classic Ubuntu Touch system-image layout:
# "/dev/root / rootfs defaults,ro" in the generated fstab, only the paths
# listed in /etc/system-image/writable-paths get individual writable
# bind-mounts). usb_moded needs to write BOTH /etc/usb-moded/dyn-modes/*.ini
# (rendered configs -- it has no idea /run/ubports-usb-moded-conf exists)
# AND /etc/udhcpd.conf (symlinked into /run/usb-moded/ for developer_mode's
# dhcp server), neither of which is a writable-path.
#
# An overlayfs mount here hit EPERM on file creation (this Android-derived
# kernel's overlayfs build appears to be restricted/patched vs. vanilla).
# Work around it with a plain tmpfs copy + bind-mount instead: copy the
# current /etc into a fresh tmpfs directory, then bind-mount that over
# /etc. Ordinary tmpfs doesn't have overlayfs's kernel-specific quirks.
if ! grep -q " /etc tmpfs " /proc/mounts 2>/dev/null; then
    mkdir -p /run/etc-rw
    cp -a /etc/. /run/etc-rw/ 2>>"$LOG2"
    log "etc copy-to-tmpfs status=$?"
    # cp -a preserves /etc's own mode bits onto the copy; this device's
    # /etc happens to be 700 (root:root), relying on the read-only mount
    # itself for protection rather than directory permissions. Once
    # bind-mounted that 700 blocks ANY non-root traversal into /etc at
    # all (broke ssh logins: "Permission denied" reading /etc/passwd,
    # /etc/bash.bashrc, etc). Force the standard 755.
    chmod 755 /run/etc-rw 2>>"$LOG2"
    log "etc chmod status=$?"
    mount --bind /run/etc-rw /etc 2>>"$LOG2"
    log "etc bind-rw mount status=$?"
fi

# SAFETY NET (found 2026-07-21, live test, TWICE): usb-moded-ssh.service's
# own `sshd -t` ExecStartPre failed with "/etc/ssh/sshd_config: No such
# file or directory" even though the real on-disk rootfs.img definitely
# has it (verified offline via TWRP both times) -- root cause not pinned
# down (usb-moded.service restarts many times, crash-looping, before it
# stabilizes; likely the /etc copy-to-tmpfs above ran to completion on an
# EARLIER attempt that got killed/interrupted partway through copying,
# left an incomplete /run/etc-rw bind-mounted anyway, and every LATER
# attempt (including the one that finally succeeds) just sees the
# already-tmpfs /etc via the guard above and skips re-copying, forever
# missing sshd_config).
#
# First attempt at a fix (2026-07-21, early) put this same check INSIDE
# the guarded block above (only runs on the very first, not-yet-tmpfs
# attempt) -- did NOT survive a second live test, presumably because
# THAT first attempt is exactly the one that gets interrupted. Moved
# out here, UNCONDITIONAL on every single invocation (cheap: a stat + a
# 3.4KB copy), checking the live /etc (whatever it currently resolves
# to, tmpfs-bound or not) against a static backup copy shipped at a
# path that's never shadowed by the /etc bind-mount trick.
if [ ! -s /etc/ssh/sshd_config ] && [ -s /usr/libexec/sshd_config.rescue-backup ]; then
    mkdir -p /etc/ssh
    cp /usr/libexec/sshd_config.rescue-backup /etc/ssh/sshd_config 2>>"$LOG2"
    chmod 644 /etc/ssh/sshd_config 2>>"$LOG2"
    log "sshd_config rescue-backup restore status=$?"
fi

log "calling real configurator"

exec /usr/libexec/ubports-usb-moded-configurator
