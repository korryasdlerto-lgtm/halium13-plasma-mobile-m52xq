#!/bin/sh
# НАЙДЕНО 2026-07-25: /etc/systemd/system биндмаунтится с
# /data/system-data/etc/systemd/system (реального раздела sda34) --
# подтверждено через /proc/self/mountinfo. Тем не менее ЛЮБАЯ живая
# правка туда -- НЕ ТОЛЬКО симлинки-энейблеры, но и СОДЕРЖИМОЕ самих
# .service-файлов -- НЕ переживает реальную перезагрузку, откатывается
# обратно к тому, что реально было в прошивке на момент flash.
# Подтверждено многократно живьём (включая сам текст After= внутри
# halium-start-container-delayed.service). Механизм сброса не найден.
# Единственное, что реально переживает перезагрузку -- содержимое
# /userdata (этот скрипт сам тому пример). Поэтому пишем ПОЛНОЕ,
# правильное содержимое юнита прямо здесь, каждую загрузку, а не
# полагаемся на то, что где-то уже лежит правильная версия.
rm -f /etc/systemd/system/lxc-android-config.service

cat > /etc/systemd/system/halium-start-container-delayed.service <<'HALIUM_UNIT_EOF'
[Unit]
Description=Start the Android LXC container after boot, wait for readiness, then bring phosh up
After=usb-moded-ssh.service
Wants=usb-moded-ssh.service

[Service]
Type=oneshot
ExecStart=/usr/libexec/halium-start-container-delayed.sh
RemainAfterExit=yes
TimeoutStartSec=90

[Install]
WantedBy=multi-user.target
HALIUM_UNIT_EOF

# НАЙДЕНО 2026-07-25 (продолжение): даже с правильным содержимым и
# правильным .wants-симлинком, пассивное включение через
# multi-user.target.wants ПОДТВЕРЖДЁННО ненадёжно -- та же самая
# болячка, что изначально была найдена для lxc-android-config.service
# самого (job иногда просто никогда не создаётся). Переключено на
# ТАЙМЕР -- механизм, уже подтверждённо надёжный в этом проекте
# (halium-phosh-watchdog.timer всегда срабатывает). Таймер сам
# вызывает systemctl start явно через 15с после boot, а не полагается
# на пассивный .wants pull-in.
cat > /etc/systemd/system/halium-start-container-delayed.timer <<'HALIUM_TIMER_EOF'
[Unit]
Description=Trigger halium-start-container-delayed.service shortly after boot (timer, not passive .wants)

[Timer]
OnBootSec=15s
AccuracySec=1s

[Install]
WantedBy=timers.target
HALIUM_TIMER_EOF

mkdir -p /etc/systemd/system/timers.target.wants
ln -sf ../halium-start-container-delayed.timer \
    /etc/systemd/system/timers.target.wants/halium-start-container-delayed.timer

mkdir -p /etc/systemd/system/multi-user.target.wants
[ -f /usr/lib/systemd/system/seatd.service ] && \
    ln -sf ../seatd.service /etc/systemd/system/multi-user.target.wants/seatd.service
systemctl daemon-reload 2>/dev/null || true

mkdir -p /etc/NetworkManager/system-connections
if [ -d /userdata/nm-connections-backup ]; then
    cp -a /userdata/nm-connections-backup/. /etc/NetworkManager/system-connections/ 2>/dev/null
    chmod 600 /etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null
fi
mkdir -p /var/lib/bluetooth
if [ -d /userdata/bluetooth-backup ]; then
    cp -a /userdata/bluetooth-backup/. /var/lib/bluetooth/ 2>/dev/null
fi
if [ -f /userdata/saved-locale.txt ]; then
    cp /userdata/saved-locale.txt /etc/default/locale 2>/dev/null
fi
mkdir -p /etc/polkit-1/rules.d
if [ -d /userdata/polkit-rules-backup ]; then
    cp -a /userdata/polkit-rules-backup/. /etc/polkit-1/rules.d/ 2>/dev/null
    chmod 755 /etc/polkit-1 /etc/polkit-1/rules.d 2>/dev/null
    chmod 644 /etc/polkit-1/rules.d/*.rules 2>/dev/null
fi

# Best-effort clock restore from last save (no RTC, no NTP client on this
# image -- boots to a stale Jan 2021 default otherwise). Only gets us to
# "last known time before shutdown" -- real sync happens below once
# network is actually up.
if [ -f /userdata/saved-clock.txt ]; then
    _saved_ts=$(cat /userdata/saved-clock.txt 2>/dev/null)
    [ -n "$_saved_ts" ] && date -u -s "@$_saved_ts" >/dev/null 2>&1
fi

# Backlight brightness: wait briefly for the real panel backlight device
# to be probed by the kernel/udev before writing (can lag a couple
# seconds after local-fs.target on cold boot). This early write is only
# a floor/fallback -- gsd-power (GNOME's power daemon) starts much later
# with the desktop session (observed ~3min after this service on a real
# boot) and overwrites brightness with its own value, undoing this write.
# The background loop below re-applies our saved value AFTER gsd-power
# has started and settled, to actually win that race.
if [ -f /userdata/saved-brightness.txt ]; then
    _saved_br=$(cat /userdata/saved-brightness.txt 2>/dev/null)
    if [ -n "$_saved_br" ]; then
        _i=0
        while [ ! -w /sys/class/backlight/panel0-backlight/brightness ] && [ "$_i" -lt 20 ]; do
            sleep 0.5
            _i=$((_i + 1))
        done
        echo "$_saved_br" > /sys/class/backlight/panel0-backlight/brightness 2>/dev/null

        (
            _i=0
            while [ "$_i" -lt 120 ]; do
                if pgrep -x gsd-power >/dev/null 2>&1; then
                    sleep 5
                    echo "$_saved_br" > /sys/class/backlight/panel0-backlight/brightness 2>/dev/null
                    break
                fi
                _i=$((_i + 1))
                sleep 2
            done
        ) &
        disown 2>/dev/null || true
    fi
fi

# Real-time clock fix: no NTP client on this image, so the restore above
# only gets last-saved (offline) time, not real time. Once actual network
# connectivity exists, fetch real time from an HTTPS response's Date:
# header (cert verification off for this one bootstrap request only,
# since a cert-verified HTTPS request itself fails while the clock is
# still wrong -- chicken-and-egg). Backgrounded + retried since this
# service runs BEFORE NetworkManager even starts.
(
    _i=0
    while [ "$_i" -lt 60 ]; do
        _hdr=$(wget --no-check-certificate -S --spider --timeout=8 https://www.google.com 2>&1 | grep -i "^[[:space:]]*Date:" | head -1)
        _datestr=$(echo "$_hdr" | sed -e 's/^[[:space:]]*[Dd]ate:[[:space:]]*//')
        if [ -n "$_datestr" ]; then
            _epoch=$(date -u -d "$_datestr" +%s 2>/dev/null)
            if [ -n "$_epoch" ]; then
                date -u -s "@$_epoch" >/dev/null 2>&1
                date -u +%s > /userdata/saved-clock.txt 2>/dev/null
                break
            fi
        fi
        _i=$((_i + 1))
        sleep 5
    done
) &
disown 2>/dev/null || true
