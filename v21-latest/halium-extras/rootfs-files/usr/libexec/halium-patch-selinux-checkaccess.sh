#!/bin/sh
# FOUND 2026-07-19 (v2 project session, Находки 17/28/32) / restored+automated 2026-07-21:
# android::init's wait_for_coldboot_done builtin action blocks forever
# waiting on the 'ro.cold_boot_done' property SET to succeed -- but that
# SET is rejected by selinux_check_access() (SELinux permission check)
# because there is no real sepolicy loaded (intentionally -- loading a
# real compiled sepolicy via /sys/fs/selinux/load has crashed/rebooted
# this whole device before, see project memory feedback_no_sepolicy_load,
# NOT the same risk as these patches). With no sepolicy, the permission
# check can never be satisfied, so init hangs indefinitely at this one
# builtin action and never reaches later init.rc triggers -- which is
# why 'ro.hardware'/'ro.zygote' (set from vendor/build.prop parsing,
# later in the boot sequence) and zygote's own service registration
# never happen, even though the property AREA itself initializes fine
# and vendor/build.prop physically contains the right values.
#
# Deeper into boot (Находки 28, 32 in v2 session, AFTER zygote/system_server
# start forking) THREE MORE libselinux.so functions hit the exact same
# "no sepolicy loaded" wall and need the identical treatment:
#   - selinux_android_setcontext()          -- JNI FatalError in
#     nativeForkSystemServer otherwise (com_android_internal_os_Zygote.cpp)
#   - selinux_android_restorecon()          -- installd SIGSEGV/ENOTSUP
#   - selinux_android_restorecon_pkgdir()   -- same, package-dir variant
#
# All FOUR functions get the exact same safe, pure-userspace patch: their
# first 8 bytes are replaced with an unconditional "return 0 (allow)":
#   mov w0, #0   ; bytes: 00 00 80 52
#   ret          ; bytes: c0 03 5f d6
# This does NOT touch the kernel/sepolicy subsystem at all (unlike
# /sys/fs/selinux/load), so it does not carry the same device-crash risk
# documented in feedback_no_sepolicy_load. Confirmed live in v2: after all
# four, InitFatalReboot dropped to 0, zygote/system_server started,
# PackageManagerService/installd ran cleanly (~90 packages restorecon'd).
#
# (NOT included here: Находка 13's libc.so PropertyInit() patch -- that
# fixes a DIFFERENT bug, a SIGSEGV from an uninitialized property_info_area
# pointer, which this v5 device does not hit -- /dev/__properties__ has
# been confirmed to populate correctly without it. Left undone
# deliberately; see DROIDIAN-V5-SYSTEMD-FIX-HOWTO.md.)
#
# TWO copies of libselinux.so need patching (both confirmed live, both
# are plain files on host-accessible paths -- no lxc-attach needed, this
# can run BEFORE the container ever starts):
#   1. /android/system/system/lib64/libselinux.so -- the real one on the
#      system partition (used by the container via the SHALLOWFIX
#      bind-mount pattern in mount.sh -- same inode).
#   2. /userdata/libselinux-stub.so -- a second copy, target of a
#      pre-existing bind-mount trick that overlays it onto a legacy
#      android_usb compat path (see project history for why this
#      second copy exists at all).
#
# Idempotent: reads the 8 bytes at each patch offset first, only backs
# up + patches a given (file, offset) pair if not already patched --
# safe to run on every boot.

LOG=/var/log/halium-patch-selinux-checkaccess.log
LOG2=/userdata/halium-patch-selinux-checkaccess.log
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG2" 2>/dev/null
}

PATCHED_HEX="00 00 80 52 c0 03 5f d6"
PATCH_BIN=/usr/libexec/halium-selinux-checkaccess-patch.bin

log "=== halium-patch-selinux-checkaccess.sh start ==="

# offset(decimal) name -- one line per libselinux.so function patched
PATCHES="
63096 selinux_check_access
85496 selinux_android_setcontext
87868 selinux_android_restorecon
90300 selinux_android_restorecon_pkgdir
"

patch_offset() {
    target="$1"
    offset="$2"
    name="$3"
    current="$(dd if="$target" bs=1 skip=$offset count=8 2>/dev/null | od -An -tx1 | tr -s ' ')"
    current="$(echo "$current" | sed 's/^ *//;s/ *$//')"
    if [ "$current" = "$PATCHED_HEX" ]; then
        log "already patched: $target @$offset ($name)"
        return
    fi
    bak="${target}.bak-pre-${name}-patch-$(date '+%Y%m%d')"
    if [ ! -f "$bak" ]; then
        cp "$target" "$bak" 2>/dev/null
        log "backup created: $bak status=$?"
    fi
    dd if="$PATCH_BIN" of="$target" bs=1 seek=$offset count=8 conv=notrunc 2>/dev/null
    sync
    newval="$(dd if="$target" bs=1 skip=$offset count=8 2>/dev/null | od -An -tx1 | tr -s ' ')"
    newval="$(echo "$newval" | sed 's/^ *//;s/ *$//')"
    if [ "$newval" = "$PATCHED_HEX" ]; then
        log "PATCHED OK: $target @$offset ($name)"
    else
        log "PATCH FAILED (bytes=[$newval]): $target @$offset ($name)"
    fi
}

patch_file() {
    target="$1"
    if [ ! -f "$target" ]; then
        log "SKIP (missing): $target"
        return
    fi
    echo "$PATCHES" | while read -r offset name; do
        [ -z "$offset" ] && continue
        patch_offset "$target" "$offset" "$name"
    done
}

patch_file /android/system/system/lib64/libselinux.so
patch_file /userdata/libselinux-stub.so

log "=== halium-patch-selinux-checkaccess.sh end ==="
