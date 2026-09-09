#!/bin/sh
mkdir -p /userdata/nm-connections-backup /userdata/bluetooth-backup /userdata/polkit-rules-backup
cp -a /etc/NetworkManager/system-connections/. /userdata/nm-connections-backup/ 2>/dev/null
cp -a /var/lib/bluetooth/. /userdata/bluetooth-backup/ 2>/dev/null
cp /etc/default/locale /userdata/saved-locale.txt 2>/dev/null
cp -a /etc/polkit-1/rules.d/. /userdata/polkit-rules-backup/ 2>/dev/null
date -u +%s > /userdata/saved-clock.txt
cat /sys/class/backlight/panel0-backlight/brightness 2>/dev/null > /userdata/saved-brightness.txt
