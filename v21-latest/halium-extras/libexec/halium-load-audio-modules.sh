#!/bin/sh
# Loads the WCD938x/Bolero/Q6-DSP audio kernel module chain, triggers
# ADSP (audio DSP coprocessor) firmware boot, and brings up the ASoC
# sound card. Requires the CONFIG_QCOM_APR=n kernel fix (halium_boot
# v42+) -- see fix docs for the full apr_send_pkt duplicate-export
# story.
#
# STATUS (2026-07-15): full working audio confirmed live, including
# real speaker/media output via the audio.hidl_compat.default.so HAL
# bind-mount (see halium-fix-audio-hal.service). This script handles
# the kernel-module side of the chain.
#
# RELIABILITY (found 2026-07-15, repeated across multiple reboots):
# rx_macro_dlkm/tx_macro_dlkm/va_macro_dlkm/native_dlkm/machine_dlkm
# consistently fail to insmod when run as part of the plain sequential
# loop below, on EVERY tested reboot -- but succeed instantly when
# inserted by hand over SSH moments later. All 5 of these are exactly
# the modules that depend, directly or indirectly, on the asynchronous
# "Q6 is Up" / apr_adsp_up() notification (see apr.c/audio_notifier.c/
# audio_pdr.c) firing first -- bolero_register_macro() in particular
# only proceeds past registering a macro once ALL qcom,num-macros
# macros have called in, and won't do anything useful before the DSP
# notifier chain has actually completed. The plain loop below runs in
# well under a second with zero delay between inserts, almost
# certainly faster than that async notification chain resolves on a
# cold boot. Retry these 5 specifically, with real delay between
# attempts, instead of a single best-effort pass.
#
# CAUTION: unloading this module chain (rmmod) AFTER the ADSP has
# already been booted has caused a spontaneous device reboot/hang in
# testing, repeatedly. Never add automatic unload/reload logic here.
# Fresh insmod-only, retried, is safe; rmmod is not.

MODDIR=/userdata/kernel-modules-fixed

for m in snd_event_dlkm q6_pdr_dlkm q6_notifier_dlkm apr_dlkm q6_dlkm \
         wcd_core_dlkm swr_dlkm wcd9xxx_dlkm wcd938x_dlkm \
         pinctrl_lpi_dlkm pinctrl_wcd_dlkm swr_ctrl_dlkm swr_dmic_dlkm \
         wcd938x_slave_dlkm bolero_cdc_dlkm adsp_loader_dlkm stub_dlkm \
         hdmi_dlkm platform_dlkm sec_audio_sysfs snd-soc-tfa98xx; do
    insmod "$MODDIR/${m}.ko" 2>/dev/null || true
done

# Manual ADSP boot trigger: on stock Android this is normally poked by a
# vendor/HAL service during early boot; nothing in the Halium/LXC path
# does this, so without it the ADSP firmware never starts even though
# the module chain above loads cleanly.
[ -w /sys/kernel/boot_adsp/boot ] && echo 1 > /sys/kernel/boot_adsp/boot 2>/dev/null || true

# The 5 modules that need the async DSP-ready notification chain to
# have actually completed first -- retry with real delay, up to ~60s.
for i in $(seq 1 20); do
    all_loaded=1
    for m in rx_macro_dlkm tx_macro_dlkm va_macro_dlkm native_dlkm machine_dlkm; do
        if ! lsmod | grep -q "^${m} "; then
            insmod "$MODDIR/${m}.ko" 2>/dev/null || true
            all_loaded=0
        fi
    done
    [ "$all_loaded" = "1" ] && break
    sleep 3
done
