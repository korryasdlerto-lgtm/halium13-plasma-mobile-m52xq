#!/bin/sh
# Перезапуск android-контейнера на 71.7 сек аптайма ХОСТА (не контейнера).
# На 1-м запуске после прошивки/установки -- пропускаем и просто ставим маркер,
# начиная со 2-го запуска -- работает на постоянной основе.
MARKER=/userdata/.halium-container-restart-71-seen

if [ ! -f "$MARKER" ]; then
    touch "$MARKER"
    exit 0
fi

while :; do
    UP=$(awk '{print $1}' /proc/uptime)
    REACHED=$(awk -v u="$UP" 'BEGIN{print (u>=71.7)?1:0}')
    [ "$REACHED" = "1" ] && break
    sleep 0.1
done

systemctl restart halium-kickstart-lxc.service
