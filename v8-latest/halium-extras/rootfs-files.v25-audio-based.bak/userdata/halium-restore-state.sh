#!/bin/sh
# v21: разовая установка исправленного аудио-стека (см.
# /usr/libexec/halium-install-audio-fix.sh) -- идемпотентно, сам
# проверяет маркер /var/lib/halium-audio-fix-done, так что вызов на
# каждой загрузке безопасен и быстр после первого раза.
mount -o remount,rw / 2>/dev/null || true
[ -x /usr/libexec/halium-install-audio-fix.sh ] && \
    /usr/libexec/halium-install-audio-fix.sh &

# НАЙДЕНО 2026-07-25: /etc ЦЕЛИКОМ смонтирован как ОТДЕЛЬНЫЙ tmpfs
# (подтверждено: `mount` показывает "tmpfs on /etc type tmpfs
# (rw,...)"), а НЕ как часть персистентного overlay корня. Поэтому
# ЛЮБОЙ файл, записанный напрямую в /etc/* (не через bind-mount с
# /userdata или /data), полностью исчезает при каждой перезагрузке --
# ровно та же болячка, что уже была найдена и обойдена для
# /etc/systemd/system/* выше в этом файле, только для аудио-стека
# (zz-droid-modern-32bit.conf, default.pa) она ещё не была применена,
# из-за чего звук ломался (SIGSYS crash-loop) после каждой полной
# перезагрузки, хотя весь остальной live-фикс был на месте. Пишем
# оба файла заново из этого скрипта каждую загрузку -- ровно тот же
# приём, что и для .service-юнитов ниже.
mkdir -p /etc/systemd/user/pulseaudio.service.d
cat > /etc/systemd/user/pulseaudio.service.d/zz-droid-modern-32bit.conf <<'ZZCONF_EOF'
[Service]
Type=simple
LockPersonality=no
MemoryDenyWriteExecute=no
NoNewPrivileges=no
RestrictNamespaces=no
SystemCallFilter=
SystemCallArchitectures=
Environment=ANDROID_ROOT=/android
Environment=HYBRIS_LD_LIBRARY_PATH=/system/lib/bootstrap:/system/lib:/vendor/lib
Environment=LD_PRELOAD=
Environment=PULSE_MODULES_DROID_EXTRA_CARD_ARGS=
ZZCONF_EOF

mkdir -p /etc/pulse
cat > /etc/pulse/default.pa <<'DEFAULTPA_EOF'
#!/usr/bin/pulseaudio -nF
#
# This file is part of PulseAudio.
#
# PulseAudio is free software; you can redistribute it and/or modify it
# under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# PulseAudio is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with PulseAudio; if not, see <http://www.gnu.org/licenses/>.

# This startup script is used only if PulseAudio is started per-user
# (i.e. not in system mode)

.fail

### Automatically restore the volume of streams and devices
load-module module-device-restore
load-module module-stream-restore
load-module module-card-restore

### Automatically augment property information from .desktop files
### stored in /usr/share/application
load-module module-augment-properties

### Should be after module-*-restore but before module-*-detect
load-module module-switch-on-port-available

### Load audio drivers statically
### (it's probably better to not load these drivers manually, but instead
### use module-udev-detect -- see below -- for doing this automatically)
#load-module module-alsa-sink
#load-module module-alsa-source device=hw:1,0
#load-module module-oss device="/dev/dsp" sink_name=output source_name=input
#load-module module-oss-mmap device="/dev/dsp" sink_name=output source_name=input
#load-module module-null-sink
#load-module module-pipe-sink

### Automatically load driver modules depending on the hardware available
.ifexists module-udev-detect.so
load-module module-udev-detect
.else
### Use the static hardware detection module (for systems that lack udev support)
load-module module-detect
.endif

### Automatically connect sink and source if JACK server is present
.ifexists module-jackdbus-detect.so
.nofail
load-module module-jackdbus-detect channels=2
.fail
.endif

### Automatically load driver modules for Bluetooth hardware
.ifexists module-bluetooth-policy.so
load-module module-bluetooth-policy
.endif

.ifexists module-bluetooth-discover.so
load-module module-bluetooth-discover
.endif

### Load several protocols
.ifexists module-esound-protocol-unix.so
load-module module-esound-protocol-unix
.endif
load-module module-native-protocol-unix

### Network access (may be configured with paprefs, so leave this commented
### here if you plan to use paprefs)
#load-module module-esound-protocol-tcp
#load-module module-native-protocol-tcp
#load-module module-zeroconf-publish

### Load the RTP receiver module (also configured via paprefs, see above)
#load-module module-rtp-recv

### Load the RTP sender module (also configured via paprefs, see above)
#load-module module-null-sink sink_name=rtp format=s16be channels=2 rate=44100 sink_properties="device.description='RTP Multicast Sink'"
#load-module module-rtp-send source=rtp.monitor

### Load additional modules from GSettings. This can be configured with the paprefs tool.
### Please keep in mind that the modules configured by paprefs might conflict with manually
### loaded modules.
.ifexists module-gsettings.so
.nofail
load-module module-gsettings
.fail
.endif


### Automatically restore the default sink/source when changed by the user
### during runtime
### NOTE: This should be loaded as early as possible so that subsequent modules
### that look up the default sink/source get the right value
load-module module-default-device-restore

### Make sure we always have a sink around, even if it is a null sink.
load-module module-droid-card
load-module module-always-sink

### Honour intended role device property
load-module module-intended-roles

### Automatically suspend sinks/sources that become idle for too long
load-module module-suspend-on-idle

### If autoexit on idle is enabled we want to make sure we only quit
### when no local session needs us anymore.
.ifexists module-console-kit.so
load-module module-console-kit
.endif
.ifexists module-systemd-login.so
load-module module-systemd-login
.endif

### Enable positioned event sounds
load-module module-position-event-sounds

### Cork music/video streams when a phone stream is active
load-module module-role-cork

### Modules to allow autoloading of filters (such as echo cancellation)
### on demand. module-filter-heuristics tries to determine what filters
### make sense, and module-filter-apply does the heavy-lifting of
### loading modules and rerouting streams.
load-module module-filter-heuristics
load-module module-filter-apply

### Make some devices default
#set-default-sink output
#set-default-source input
DEFAULTPA_EOF

mkdir -p /etc/systemd/user
ln -sf /dev/null /etc/systemd/user/pipewire-pulse.socket
ln -sf /dev/null /etc/systemd/user/pipewire-pulse.service
if [ -f /usr/lib/systemd/user/pulseaudio.socket ]; then
    mkdir -p /etc/systemd/user/sockets.target.wants
    ln -sf ../pulseaudio.socket /etc/systemd/user/sockets.target.wants/pulseaudio.socket
fi

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
# НАЙДЕНО 2026-07-27, ПЕРЕДЕЛАНО (перенесено из v25): раньше здесь была
# отдельная ветка if/else на /userdata/PHOSH_FIRST_BOOT_OK, создававшая
# ОТДЕЛЬНЫЙ одноразовый 55с-таймер только на первую загрузку. Не
# сработало ни разу ни в v22, ни в v23 -- контейнер всё равно стартовал
# сразу же на первой загрузке, ломая SSH. Гейт первой загрузки теперь
# живёт ЦЕЛИКОМ в lxc-android-config.service.d/00-first-boot-gate.conf
# (ConditionPathExists=/userdata/CONTAINER_ENABLED, контейнер НИКОГДА не
# стартует сам -- только вручную через halium-enable-container.sh) --
# см. этот файл. Здесь, ниже, теперь БЕЗУСЛОВНО (каждую загрузку
# одинаково) создаётся обычный halium-start-container-delayed.service/
# .timer, как и было до всей этой истории с гейтом.

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
OnBootSec=25s
AccuracySec=1s

[Install]
WantedBy=timers.target
HALIUM_TIMER_EOF

mkdir -p /etc/systemd/system/timers.target.wants
ln -sf ../halium-start-container-delayed.timer \
    /etc/systemd/system/timers.target.wants/halium-start-container-delayed.timer
# КОНЕЦ безусловного создания halium-start-container-delayed -- гейт первой
# загрузки теперь в lxc-android-config.service.d/00-first-boot-gate.conf

mkdir -p /etc/systemd/system/multi-user.target.wants
[ -f /usr/lib/systemd/system/seatd.service ] && \
    ln -sf ../seatd.service /etc/systemd/system/multi-user.target.wants/seatd.service

# НАЙДЕНО 2026-07-25: halium-pulseaudio-sink-watchdog -- та же болячка,
# что и с halium-start-container-delayed.service выше: /etc целиком
# tmpfs, юниты которых нет во ФЛЕШНУТОМ rootfs.img (этот появился уже
# после v21-флеша, живьём) не переживают перезагрузку. Пишем юнит и
# таймер прямо здесь, чтобы работало и на уже прошитом устройстве без
# пересборки/переflash-а архива. Сам скрипт /usr/libexec/halium-
# pulseaudio-sink-watchdog.sh лежит вне /etc (в персистентном overlay),
# ему это не нужно.
cat > /etc/systemd/system/halium-pulseaudio-sink-watchdog.service <<'PAWATCHDOG_SVC_EOF'
[Unit]
Description=Restart pulseaudio.service if it fell back to auto_null (module-droid-card lost the boot-time race against /vendor mount)

[Service]
Type=oneshot
ExecStart=/usr/libexec/halium-pulseaudio-sink-watchdog.sh
PAWATCHDOG_SVC_EOF

cat > /etc/systemd/system/halium-pulseaudio-sink-watchdog.timer <<'PAWATCHDOG_TIMER_EOF'
[Unit]
Description=Periodically check pulseaudio fell back to auto_null and retry once /vendor is ready

[Timer]
OnBootSec=20s
OnUnitActiveSec=20s
AccuracySec=5s

[Install]
WantedBy=timers.target
PAWATCHDOG_TIMER_EOF

ln -sf ../halium-pulseaudio-sink-watchdog.timer \
    /etc/systemd/system/timers.target.wants/halium-pulseaudio-sink-watchdog.timer

systemctl daemon-reload 2>/dev/null || true

# НАЙДЕНО 2026-07-25: enable-симлинк + daemon-reload НЕ гарантируют, что
# таймер реально запустится -- если timers.target к этому моменту
# загрузки уже пройден, systemd не подхватывает заново появившийся
# .wants-симлинк задним числом. Живой пример: halium-pulseaudio-sink-
# watchdog.timer после этого блока показывал "enabled" в systemctl, но
# "Active: inactive (dead)", "Trigger: n/a" -- то есть вообще ни разу не
# сработал за всю загрузку, и звук молча оставался сломанным до ручного
# запуска. Explicit "systemctl start" не полагается на то, пройден ли
# target уже или нет.
systemctl start halium-start-container-delayed.timer 2>/dev/null || true
systemctl start halium-pulseaudio-sink-watchdog.timer 2>/dev/null || true

mkdir -p /etc/NetworkManager/system-connections
if [ -d /userdata/nm-connections-backup ]; then
    cp -a /userdata/nm-connections-backup/. /etc/NetworkManager/system-connections/ 2>/dev/null
    chmod 600 /etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null
fi
mkdir -p /var/lib/bluetooth
if [ -d /userdata/bluetooth-backup ]; then
    cp -a /userdata/bluetooth-backup/. /var/lib/bluetooth/ 2>/dev/null
fi
# НАЙДЕНО 2026-07-25: смена языка в Настройках (gnome-control-center
# Region & Language) пишет ТОЛЬКО в AccountsService
# (/var/lib/AccountsService/users/phablet, Languages=...) -- это
# стандартное поведение GNOME, где обычно ГРИТЕР при следующем логине
# читает это поле и экспортирует LANG для новой сессии. В этой сборке
# настоящего логин-экрана нет (capsh в phosh.service сразу запускает
# сессию под uid 1000, минуя greeter), поэтому ничего не переносило
# AccountsService -> /etc/default/locale -- язык не менялся ни сразу,
# ни после перезагрузки, причём saved-locale.txt тут ни при чём
# (просто хранил старое значение, которое ничего и не должно было
# менять). AccountsService-файл САМ ПО СЕБЕ уже персистентен (bind-mount
# с /userdata/system-data/var/lib/AccountsService, см. /etc/fstab), так
# что он и есть настоящий источник истины -- берём язык оттуда.
_as_lang=""
if [ -f /var/lib/AccountsService/users/phablet ]; then
    _as_lang=$(grep '^Languages=' /var/lib/AccountsService/users/phablet 2>/dev/null | \
        sed 's/^Languages=//; s/;.*//')
fi
if [ -n "$_as_lang" ] && locale -a 2>/dev/null | grep -qi "^$(echo "$_as_lang" | sed 's/UTF-8/utf8/i')\$"; then
    cat > /etc/default/locale <<LOCALE_EOF
#  File generated by update-locale
LANG=$_as_lang
LC_MESSAGES=$_as_lang
LC_CTYPE=$_as_lang
LOCALE_EOF
    cp /etc/default/locale /userdata/saved-locale.txt 2>/dev/null
elif [ -f /userdata/saved-locale.txt ]; then
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

# Volume: то же самое, что и с яркостью выше -- pulseaudio поднимается
# нескоро (пользовательский systemd-сервис, ждёт полной desktop-сессии),
# и сохранённая громкость никак не может быть выставлена раньше, чем
# оживёт pactl. Ждём в фоне: pactl подключается -- проверка активная,
# retry-цикл, а не жёсткий sleep.
if [ -f /userdata/saved-volume.txt ]; then
    (
        _saved_vol=$(sed -n '1p' /userdata/saved-volume.txt 2>/dev/null)
        _saved_mute=$(sed -n '2p' /userdata/saved-volume.txt 2>/dev/null)
        _i=0
        while [ "$_i" -lt 120 ]; do
            if su phablet -c 'export XDG_RUNTIME_DIR=/run/user/1000; export PULSE_RUNTIME_PATH=/run/user/1000/pulse; timeout 3 pactl info' >/dev/null 2>&1; then
                [ -n "$_saved_vol" ] && su phablet -c "export XDG_RUNTIME_DIR=/run/user/1000; export PULSE_RUNTIME_PATH=/run/user/1000/pulse; pactl set-sink-volume @DEFAULT_SINK@ ${_saved_vol}%" >/dev/null 2>&1
                [ -n "$_saved_mute" ] && su phablet -c "export XDG_RUNTIME_DIR=/run/user/1000; export PULSE_RUNTIME_PATH=/run/user/1000/pulse; pactl set-sink-mute @DEFAULT_SINK@ ${_saved_mute}" >/dev/null 2>&1
                break
            fi
            _i=$((_i + 1))
            sleep 2
        done
    ) &
    disown 2>/dev/null || true
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
