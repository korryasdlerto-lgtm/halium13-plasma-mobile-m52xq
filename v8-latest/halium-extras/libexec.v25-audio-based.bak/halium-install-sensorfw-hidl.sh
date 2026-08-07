#!/bin/sh
# The stock UBports rootfs only ships libsensorfw-qt5-hybris, which needs a
# legacy hw_get_module()-style sensors.*.so HAL module -- this device has
# none (only the modern HIDL android.hardware.sensors-service, confirmed
# 2026-07-06). Install the matching libsensorfw-qt5-hidl package (same
# upstream sensorfw-qt5 version, no dependency conflicts) if not already
# present.
if ! dpkg -l libsensorfw-qt5-hidl 2>/dev/null | grep -q '^ii'; then
    mount -o remount,rw /
    dpkg -i /usr/share/halium-extras/libsensorfw-qt5-hidl.deb 2>/dev/null || true
    mount -o remount,ro /
fi
