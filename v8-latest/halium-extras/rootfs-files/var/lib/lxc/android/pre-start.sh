#!/bin/sh

# lxc.autodev = 0 in our config means LXC does NOT auto-populate /dev in
# the container's new namespace -- our own lxc.mount.entry (tmpfs on dev)
# is entirely responsible for it, and that mount.entry needs dev/ to
# already exist as a real directory under $LXC_ROOTFS_PATH before liblxc
# processes it. mount-android-partitions.service (systemd, runs ONCE per
# boot) creates it once, but this hook runs on EVERY container start
# attempt (our halium-kickstart-lxc watchdog retries up to 4x) -- so
# recreate it unconditionally here too, matching standard Halium
# convention (see pre-start.sh examples across other device ports).
mkdir -p "$LXC_ROOTFS_PATH/dev" "$LXC_ROOTFS_PATH/dev/pts" "$LXC_ROOTFS_PATH/sbin" "$LXC_ROOTFS_PATH/proc" "$LXC_ROOTFS_PATH/sys" 2>/dev/null || true

# These things can be done only of rootfs is writable i.e. is ramdisk.
if [ -w $LXC_ROOTFS_PATH ]; then
    rm -f $LXC_ROOTFS_PATH/sbin/adbd

    # NAIDENO 2026-07-18: na etom system-as-root obraze real'nogo
    # init.*.rc (s mount_all/swapon_all/on nonencrypted) NET na verhnem
    # urovne $LXC_ROOTFS_PATH -- on zhivet vlozhenno v
    # system/etc/init/hw/init.rc. Staryi glob "$LXC_ROOTFS_PATH/init.*.rc"
    # nikogda ne matchilsya (sed molcha padal "No such file or directory"),
    # tak chto "on nonencrypted" -- EDINSTVENNYI trigger, zapuskayushii
    # class_start main/late_start (zygote, system_server) -- NIKOGDA ne
    # udalyalsya, a znachit eti klassy servisov, veroyatno, nikogda ne
    # startovali za vsyu istoriyu etogo proekta.
    REAL_INIT_RC="$LXC_ROOTFS_PATH/system/etc/init/hw/init.rc"
    if [ -f "$REAL_INIT_RC" ]; then
        sed -i "/mount_all /d" "$REAL_INIT_RC"
        sed -i "/swapon_all /d" "$REAL_INIT_RC"
        sed -i "/on nonencrypted/d" "$REAL_INIT_RC"
    fi
    # Ostavlyaem starye puti tozhe -- vdrug na drugoi sborke obraza oni
    # real'no matchatsya (bezvredno, esli faylov net).
    sed -i "/mount_all /d" $LXC_ROOTFS_PATH/init.*.rc 2>/dev/null || true
    sed -i "/swapon_all /d" $LXC_ROOTFS_PATH/init.*.rc 2>/dev/null || true
    sed -i "/on nonencrypted/d" $LXC_ROOTFS_PATH/init.rc 2>/dev/null || true

    # Config snippet scripts
    run-parts /var/lib/lxc/android/pre-start.d || true
fi

# Make sure bind-mount-points are available.
mkdir -p /dev/__properties__ /dev/socket

# НАЙДЕНО 2026-07-19: android::init::PropertyInit()'s CreateSerializedPropertyInfo()
# (re)compiles /dev/__properties__/property_info + all per-context prop_area
# files from the plat/vendor/system_ext property_contexts text sources on
# EVERY second_stage start -- but this regeneration is NOT idempotent: it
# only succeeds when /dev/__properties__ starts EMPTY. If stale files are
# already there (left over from ANY earlier container start attempt --
# including one that got further and crashed on something unrelated
# downstream, e.g. missing /linkerconfig below), the next attempt's
# CreateSerializedPropertyInfo()/__system_property_area_init() silently
# fails ("Failed to initialize property area" -> InitFatalReboot signal 6),
# which was the root cause chased across Находки 11-13. Confirmed via
# direct A/B test: identical second_stage invocation succeeds immediately
# after `rm -rf /dev/__properties__/*`, fails immediately without it.
# Since /dev/__properties__ here is the HOST-side bind-mount SOURCE
# (populated fresh on every real device boot's devtmpfs, so this rm is
# never destroying anything meaningful), wipe it unconditionally on every
# container start attempt so PropertyInit() always sees a clean slate.
rm -rf /dev/__properties__/*

# НАЙДЕНО 2026-07-18/19: /debug_ramdisk, /second_stage_resources, /avb,
# /linkerconfig -- стандартные каталоги РЕАЛЬНОГО boot-ramdisk (Android
# A-only ramdisk layout) / early-boot tmpfs mountpoints, которых нет в
# нашем синтетическом rootfs. Без них init (что first, что second stage)
# падает: mount("tmpfs", "/debug_ramdisk", ...) / mount("tmpfs",
# "/linkerconfig", ...) failed No such file or directory -- InitFatalReboot.
# Создаём здесь, чтобы пережить overlay/tmpfs-upper цикл этого скрипта.
mkdir -p "$LXC_ROOTFS_PATH/debug_ramdisk" "$LXC_ROOTFS_PATH/second_stage_resources" "$LXC_ROOTFS_PATH/avb" "$LXC_ROOTFS_PATH/linkerconfig"
