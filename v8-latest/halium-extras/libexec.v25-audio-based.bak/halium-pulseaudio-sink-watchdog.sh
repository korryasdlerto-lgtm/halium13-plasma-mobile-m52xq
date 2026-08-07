#!/bin/sh
# НАЙДЕНО 2026-07-25: pulseaudio.service (пользовательский systemd-юнит)
# стартует независимо от phosh.service/halium-gpu-bridge-setup.sh, у
# которого бинд-маунтится /vendor на хосте. Если pulseaudio запустился
# РАНЬШЕ, чем /vendor/etc/audio_policy_configuration.xml стал доступен,
# module-droid-card падает ("Failed to parse any configuration.",
# "Failed to load module module-droid-card: initialization failed"),
# и default.pa молча проваливается на module-always-sink -- звук
# отваливается полностью (default sink = auto_null), хотя сервис
# формально "active (running)". Confirmed live: простой
# "systemctl --user restart pulseaudio.service" ПОСЛЕ появления /vendor
# чинит это мгновенно. Этот watchdog (по таймеру, как
# halium-audio-watchdog) периодически проверяет именно это условие и
# рестартует pulseaudio только когда есть реальный шанс на успех.
LOG_TAG="halium-pulseaudio-sink-watchdog"
log() {
    echo "$LOG_TAG: $1" | systemd-cat -t "$LOG_TAG" -p info
}

[ -f /vendor/etc/audio_policy_configuration.xml ] || exit 0

_default_sink=$(su phablet -c '
export XDG_RUNTIME_DIR=/run/user/1000
export PULSE_RUNTIME_PATH=/run/user/1000/pulse
export LC_ALL=C
timeout 3 pactl info 2>/dev/null
' | sed -n 's/^Default Sink: //p')

if [ "$_default_sink" = "auto_null" ]; then
    log "default sink is auto_null (module-droid-card failed at startup), /vendor now ready -- restarting pulseaudio.service"
    su phablet -c '
        export XDG_RUNTIME_DIR=/run/user/1000
        export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
        systemctl --user restart pulseaudio.service
    '
    # НАЙДЕНО 2026-07-25: gsd-media-keys подключается к pulseaudio
    # РАЗ, при собственном старте -- рестарт pulseaudio.service выше
    # (новый процесс, новый сокет) обрывает это соединение, и качельки
    # громкости перестают работать до ручного перезапуска gsd-media-
    # keys (тот же баг, что чинили вручную раньше live). Перезапускаем
    # его сразу же вместе с pulseaudio, чтобы не повторять руками
    # каждый раз.
    sleep 2
    su phablet -c '
        export XDG_RUNTIME_DIR=/run/user/1000
        export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
        export PULSE_RUNTIME_PATH=/run/user/1000/pulse
        OLDPID=$(pgrep -x gsd-media-keys)
        [ -n "$OLDPID" ] && kill "$OLDPID"
        sleep 1
        nohup /usr/libexec/gsd-media-keys >/dev/null 2>&1 &
        disown
    '
    log "gsd-media-keys relaunched to reconnect to the new pulseaudio instance"
fi

exit 0
