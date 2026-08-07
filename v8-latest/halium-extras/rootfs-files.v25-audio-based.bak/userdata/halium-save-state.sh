#!/bin/sh
mkdir -p /userdata/nm-connections-backup /userdata/bluetooth-backup /userdata/polkit-rules-backup
cp -a /etc/NetworkManager/system-connections/. /userdata/nm-connections-backup/ 2>/dev/null
cp -a /var/lib/bluetooth/. /userdata/bluetooth-backup/ 2>/dev/null
cp /etc/default/locale /userdata/saved-locale.txt 2>/dev/null
cp -a /etc/polkit-1/rules.d/. /userdata/polkit-rules-backup/ 2>/dev/null
date -u +%s > /userdata/saved-clock.txt
cat /sys/class/backlight/panel0-backlight/brightness 2>/dev/null > /userdata/saved-brightness.txt

# НАЙДЕНО 2026-07-25: "pactl get-sink-volume/get-sink-mute @DEFAULT_SINK@"
# на этой сборке pactl 14.2 падает с "No valid command specified" --
# похоже, эти подкоманды тут не работают (причина не выяснялась, не
# стоило времени). Рабочая альтернатива -- распарсить блок нужного
# синка из "pactl list sinks" (это же confirmed рабочим много раз за
# сессию). LC_ALL=C ОБЯЗАТЕЛЕН -- иначе на русской локали pactl выводит
# "Аудиоприёмник по умолчанию:" вместо "Default Sink:", и весь парсинг
# ниже молча ломается (обнаружено live: после смены языка на русский
# именно это и произошло).
su phablet -c '
export XDG_RUNTIME_DIR=/run/user/1000
export PULSE_RUNTIME_PATH=/run/user/1000/pulse
export LC_ALL=C
_default_sink=$(pactl info 2>/dev/null | sed -n "s/^Default Sink: //p")
pactl list sinks 2>/dev/null | awk -v sink="$_default_sink" "
\$0 ~ \"Name: \" sink \"\$\" {f=1}
f && /Volume:/{match(\$0,/[0-9]+%/); print substr(\$0,RSTART,RLENGTH-1); exit}
"
pactl list sinks 2>/dev/null | awk -v sink="$_default_sink" "
\$0 ~ \"Name: \" sink \"\$\" {f=1}
f && /Mute:/{print \$2; exit}
"
' > /userdata/saved-volume.txt 2>/dev/null
