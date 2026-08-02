#!/bin/sh
# The vendor's own audio.primary.default.so (/vendor/lib64/hw/, real Android
# 13 vendor partition) is a thin passthrough stub that expects to be loaded
# by the modern HIDL/AIDL passthrough framework -- it does not work when
# dlopen'd directly by pulseaudio-modules-droid-24's old (Android 7 era)
# legacy audio_hw_device_t-based client, even though a real
# android.hardware.audio.service HIDL HAL is already running (pid alive,
# confirmed via `ps`). Symptom: sinks appear in PulseAudio, streams open
# and "play" with growing buffer latency, but zero audio ever reaches
# hardware (dmesg shows no DSP/amp activity at all during playback).
#
# Fix found via github.com/pickleswithtech/SamsungS20UbuntuTouch (same
# techpack/Snapdragon family, halium-13 branch): their overlay symlinks
# audio.primary.default.so to /system/lib64/hw/audio.hidl_compat.default.so
# instead -- a proper HIDL-passthrough compatibility shim (part of the
# stock system.img, already present here too) that bridges the old
# audio_hw_device_t interface to the real running HIDL service instead of
# talking to hardware directly itself.
#
# IMPORTANT: this must bind-mount the REAL device path
# (/android/system/vendor/lib64/hw/audio.primary.default.so, resolved via
# the /android bridge to the actual read-only vendor partition) -- NOT
# /opt/halium-lxc-bridge/vendor-lib64/hw/audio.primary.default.so. The
# HAL loader inside the android container constructs this path itself and
# does not go through HYBRIS_LD_LIBRARY_PATH for it, so patching only the
# bridge copy (tried first, 2026-07-15) had no effect at all -- confirmed
# via /proc/<pulseaudio-pid>/maps showing the real /android/... path
# loaded, not the bridge one. The vendor partition itself is read-only
# and should not be written to directly -- a bind-mount is used instead
# (reversible, doesn't touch the real partition).
#
# RELIABILITY (found 2026-07-15): on the very first reboot test, this
# service ran (systemd showed "Finished") but the bind-mount silently
# never took effect -- almost certainly because /android/system/vendor
# (the LXC container's own mount, set up by the container's internal init,
# not by lxc-android-config.service itself finishing) was not actually
# populated/ready yet at that exact point in boot, matching the same
# "vendor-mount-readiness" race documented for halium-bounce-composer.sh.
# Retry for a while instead of a single attempt.

SRC=/opt/halium-lxc-bridge/system-lib64/hw/audio.hidl_compat.default.so
DST=/android/system/vendor/lib64/hw/audio.primary.default.so

for i in $(seq 1 30); do
    if [ -f "$SRC" ] && [ -f "$DST" ]; then
        if ! mountpoint -q "$DST"; then
            mount --bind "$SRC" "$DST" 2>/dev/null && break
        else
            break
        fi
    fi
    sleep 2
done
