#!/bin/sh
# libgsthybris.so/libgsthybrissink.so hang gst-plugin-scanner indefinitely
# when it tries to inspect them (confirmed 2026-07-03), which blocks
# media-hub.service in "activating" for 1.5+ minutes and blacks out the
# camera app's viewfinder while stuck. A pre-existing (now possibly reset by
# a fresh rootfs/Format Data) GStreamer registry cache had these marked
# broken/skipped, which is what actually kept things working -- not a real
# fix. Move the plugins out of GStreamer's scan path permanently instead of
# depending on cache state, and make sure the cache doesn't reference them.
GST_DIR=/usr/lib/aarch64-linux-gnu/gstreamer-1.0
DISABLED_DIR=/var/lib/halium-gst-hybris-disabled
mount -o remount,rw /
mkdir -p "$DISABLED_DIR"
for f in libgsthybris.so libgsthybrissink.so; do
    [ -f "$GST_DIR/$f" ] && mv "$GST_DIR/$f" "$DISABLED_DIR/$f"
done
mount -o remount,ro /
rm -f /home/phablet/.cache/gstreamer-1.0/registry.aarch64.bin
