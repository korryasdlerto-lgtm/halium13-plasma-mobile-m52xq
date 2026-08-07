#!/bin/sh
# 2026-07-16: the real flashlight control node on this SoC is NOT the
# generic AOSP LED-class led:torch_0/led:switch_0 pair (bound to
# leds-qti-flash, confirmed a dead end -- writes accepted but zero
# physical light, zero dmesg activity). The actual driver is a separate
# PMIC/charger chip, sm5714-fled, exposed via the Samsung camera-HAL
# sysfs node /sys/devices/virtual/camera/flash/rear_flash (single
# magic-value interface: 0=off, 100=torch on). This is owned
# root:1047 (AID_CAMERA) 0664 by default -- phablet isn't in that
# group, so ayatana-indicator-power's write silently fails without
# this chown. Same pattern as the old torch_0 script it replaces.

for i in $(seq 1 30); do
    if [ -e /sys/devices/virtual/camera/flash/rear_flash ]; then
        chown phablet /sys/devices/virtual/camera/flash/rear_flash
        break
    fi
    sleep 1
done
