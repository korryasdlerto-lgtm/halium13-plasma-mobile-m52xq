#!/bin/sh
export HYBRIS_LD_LIBRARY_PATH=/opt/halium-lxc-bridge/system-lib64:/opt/halium-lxc-bridge/vendor-lib64

# в14, НАЙДЕНО+ПОДТВЕРЖДЕНО ЖИВЬЁМ 2026-09-08: на этом устройстве
# ro.bt.bdaddr_path пуст, а ro.vendor.bt.bdaddr_path указывает на
# /mnt/vendor/efs/bluetooth/bt_addr -- путь, которого в этом halium-
# мосте просто нет (efs-раздел не пробрасывается). Оригинальный
# скрипт (elif-цепочка) на этом падал ЖЁСТКО (`cp` неудачный -> exit 1)
# ДО того, как успевал дойти до последнего фолбэка --
# persist.vendor.service.bdroid.bdaddr -- а это свойство на самом
# деле СОДЕРЖИТ реальный рабочий MAC (22:22:35:02:c2:3e, подтверждено
# `bluetoothctl show` после ручной правки). Из-за этого
# ExecStartPost=bluebinder_post.sh падал status=1/FAILURE на КАЖДОЙ
# загрузке, bluetoothctl показывал "No default controller available"
# -- даже после того как в13 наконец поставил сам демон bluez.
# Фикс: пробуем property-based способ (самый надёжный на этом
# устройстве) ПЕРВЫМ, path-based -- только как fallback, и неудачный
# `cp` для path-based вариантов больше не считается фатальным --
# просто идём дальше по цепочке вместо exit 1.

# Check for port provided script to populate the bluetooth address
if [ -x /usr/bin/droid/droid-get-bt-address.sh ] ; then
    /usr/bin/droid/droid-get-bt-address.sh
fi

# If the bluetooth address is provided by another script use that
if [ -f /var/lib/bluetooth/board-address ] ; then
    exit 0
fi

mkdir -p /var/lib/bluetooth

# Getting address file from properties
bt_addr_file=$(/usr/bin/getprop ro.bt.bdaddr_path)
bt_addr_vendor_file=$(/usr/bin/getprop ro.vendor.bt.bdaddr_path)
bt_addr_prop=$(/usr/bin/getprop persist.vendor.service.bdroid.bdaddr)

if [ "$bt_addr_prop" != "" ]; then
    echo "$bt_addr_prop" | awk -F: '{do printf "%s"(NF>1?FS:RS),$NF;while(--NF)}' > /var/lib/bluetooth/board-address
elif [ "$bt_addr_file" != "" ] && cp "$bt_addr_file" /var/lib/bluetooth/board-address 2>/dev/null; then
    :
elif [ "$bt_addr_vendor_file" != "" ] && cp "$bt_addr_vendor_file" /var/lib/bluetooth/board-address 2>/dev/null; then
    :
else
    echo "Failed to get bluetooth address!"
    exit 1
fi

if [ ! -s /var/lib/bluetooth/board-address ]; then
    echo "Failed to set bluetooth address."
    exit 1
fi

# Set proper permissions
chown root:root /var/lib/bluetooth/board-address
chmod 644 /var/lib/bluetooth/board-address
exit 0
