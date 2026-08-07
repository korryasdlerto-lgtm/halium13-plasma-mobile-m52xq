#!/bin/sh
# Установка исправленного аудио-стека (pulseaudio + droid-hal, arm64+armhf,
# реальный 32-битный Qualcomm HAL audio.primary.lahaina.so) при первой
# загрузке после прошивки v21. Идемпотентно — проверяет маркер-файл.
#
# История: изначально ставился pipewire-audio, но реальный HAL для этого
# чипа (lahaina) существует только в 32-битной сборке (/vendor/lib/hw/
# audio.primary.lahaina.so), 64-битная версия — пустая заглушка
# audio.primary.default.so, которая падает сегфолтом. Поэтому здесь
# полный droidian-родной PulseAudio (arm64 хост-процесс + armhf
# module-droid-card) вместо PipeWire.
MARKER=/var/lib/halium-audio-fix-done
DEBS_DIR=/usr/local/lib/halium-audio-fix-debs
LOG=/var/log/halium-audio-fix-install.log

[ -f "$MARKER" ] && exit 0
[ -d "$DEBS_DIR" ] || exit 0

{
    echo "=== halium-install-audio-fix.sh $(date) ==="

    dpkg --add-architecture armhf
    dpkg --add-architecture arm64

    # pipewire-audio/pipewire-alsa конфликтуют с pulseaudio на уровне apt.
    apt-get remove -y pipewire-audio pipewire-alsa 2>&1 || \
        dpkg -r pipewire-audio pipewire-alsa 2>&1 || true

    # НАЙДЕНО 2026-07-27: одиночный проход dpkg -i на ~290 пакетах падает
    # каскадно из-за pre-dependency ordering (libexpat1:armhf pre-depends
    # libc6 >= 2.38, но libc6:armhf ещё не сконфигурирован в момент его
    # установки) -- см. подробный разбор в update-binary. Повторный
    # проход dpkg -i после configure чинит это.
    #
    # НАЙДЕНО 2026-07-27 (перенесено из v25): libasound2-plugins:arm64/
    # :armhf собраны с разным содержимым общего /etc/alsa/conf.d/99-
    # pulseaudio-default.conf.example -- --force-overwrite безопасен,
    # файл не активный конфиг.
    dpkg -i --force-confold --force-overwrite "$DEBS_DIR"/*.deb 2>&1
    dpkg --configure -a 2>&1
    dpkg -i --force-confold --force-overwrite "$DEBS_DIR"/*.deb 2>&1
    dpkg --configure -a 2>&1
    dpkg --configure -a 2>&1

    ldconfig 2>&1

    # pipewire-pulse.socket слушает тот же путь, что и pulseaudio.socket,
    # и побеждает гонку за сокет по умолчанию -- маскируем.
    mkdir -p /etc/systemd/user
    ln -sf /dev/null /etc/systemd/user/pipewire-pulse.socket
    ln -sf /dev/null /etc/systemd/user/pipewire-pulse.service
    if [ -f /usr/lib/systemd/user/pulseaudio.socket ]; then
        mkdir -p /etc/systemd/user/sockets.target.wants
        ln -sf ../pulseaudio.socket /etc/systemd/user/sockets.target.wants/pulseaudio.socket
    fi

    touch "$MARKER"
    echo "=== done $(date) ==="
} >> "$LOG" 2>&1
