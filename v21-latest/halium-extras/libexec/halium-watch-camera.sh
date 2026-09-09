#!/bin/sh
# vendor.camera-provider-2-6 crashes in a hard loop due to missing EFS
# multi-cam calibration data on this device (root cause documented, not
# fixable in software -- same conclusion independently reached by the
# sibling Ubuntu Touch project on this exact device, see its
# docs/FIXES-HISTORY.txt). Repeated stop/start cycling sometimes clears a
# stuck ICP subdev fd from a previous crashed instance, occasionally
# letting the next attempt succeed -- not reliably understood, best-effort
# mitigation only, not a guaranteed fix. Loop forever and re-kick on every
# fresh lxc@android.service active transition (it sometimes
# restarts mid-session, and a one-shot triggered-once unit never re-fires
# for that).
#
# в15, НАЙДЕНО 2026-09-08 (перенесено в эту в14-базированную сборку
# как в20/в21): этот скрипт (унаследован от Droidian) ссылался на
# lxc-android-config.service -- юнит, который в ЭТОМ проекте explicitly
# rm -f'ится при флеше (см. update-binary) в пользу lxc@android.service.
# CUR_STATE поэтому был ВСЕГДА пустой, условие никогда не выполнялось --
# вачдог физически ни разу не кикал провайдер за всё время существования
# проекта. Исправлено на реальное имя нашего юнита.
LAST_STATE=""
while true; do
    CUR_STATE=$(systemctl is-active lxc@android.service 2>/dev/null)
    if [ "$CUR_STATE" = "active" ] && [ "$LAST_STATE" != "active" ]; then
        sleep 20
        for i in 1 2 3 4 5; do
            sudo lxc-attach -n android -- sh -c 'stop vendor.camera-provider-2-6; sleep 1; start vendor.camera-provider-2-6' 2>/dev/null || true
            sleep 5
        done
    fi
    LAST_STATE="$CUR_STATE"
    sleep 3
done
