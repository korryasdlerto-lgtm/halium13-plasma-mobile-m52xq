#!/bin/sh
# НАЙДЕНО 2026-07-24/25: простой "systemctl start lxc-android-config.service"
# из oneshot-юнита (даже строго After=multi-user.target, то есть уже
# после того как SSH поднят) НЕ работает надёжно на чистой прошивке --
# phosh.service успевает попытаться стартовать РАНЬШЕ, чем контейнер
# реально готов (systemd-юнит "active" != Android-init внутри
# контейнера реально загрузился), зависает на ExecStartPre
# (halium-bounce-composer.sh) НАВСЕГДА -- в отличие от ручной
# последовательности по SSH, где мы ЖДЁМ реальной готовности перед
# перезапуском phosh. Этот скрипт повторяет именно ручную
# последовательность: запустить контейнер, дождаться реальной
# готовности (zygote running внутри), ТОЛЬКО ПОТОМ перезапустить phosh.
LOG=/userdata/halium-start-container-delayed.log
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null; }

log "=== start ==="
systemctl unmask lxc-android-config.service 2>&1 | while read -r line; do log "$line"; done
systemctl start lxc-android-config.service
log "lxc-android-config.service start issued, is-active=$(systemctl is-active lxc-android-config.service)"

# Ждём реальной готовности Android-контейнера (zygote), не просто
# "юнит active" -- до 60 секунд, проверка каждые 2 секунды.
i=0
ready=0
while [ "$i" -lt 30 ]; do
    zygote_state=$(lxc-attach -n android -- getprop init.svc.zygote 2>/dev/null)
    log "attempt $i: init.svc.zygote=$zygote_state"
    if [ "$zygote_state" = "running" ]; then
        ready=1
        break
    fi
    sleep 2
    i=$((i + 1))
done

if [ "$ready" = "1" ]; then
    log "container ready (zygote running) after $((i * 2))s -- restarting phosh.service"
    systemctl restart phosh.service
    log "phosh.service restart issued, is-active=$(systemctl is-active phosh.service)"
else
    log "WARNING: zygote never reached 'running' within 60s -- NOT restarting phosh.service (would just hang identically to the automatic race). Manual intervention needed."
fi
log "=== end ==="
