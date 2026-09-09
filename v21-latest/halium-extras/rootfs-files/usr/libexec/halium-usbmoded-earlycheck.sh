#!/bin/sh
OUT=/userdata/usbmoded-earlycheck3.log
: > "$OUT"
i=0
while [ $i -lt 30 ]; do
    {
        echo "=== snapshot $i $(date) uptime=$(cat /proc/uptime 2>/dev/null) ==="
        systemctl show usb-moded -p ActiveState,SubState,Result,NRestarts 2>&1
        echo "UDC=[$(cat /sys/kernel/config/usb_gadget/g1/UDC 2>&1)]"
        echo "gadget functions: $(ls /sys/kernel/config/usb_gadget/g1/functions 2>&1)"
        echo "gadget c.1 links: $(ls -la /sys/kernel/config/usb_gadget/g1/configs/c.1 2>&1 | grep -v '^total\|^d')"
        echo "ip addr usb0/rndis0: $(ip addr show usb0 2>&1; ip addr show rndis0 2>&1)"
        echo "usb-moded runtime mode:"
        cat /run/ubports-usb-moded-conf/*.ini 2>&1 | grep -i mode
        if [ "$i" = "3" ]; then
            echo "--- forcing developer_mode via dbus (as root) ---"
            dbus-send --system --print-reply --dest=com.meego.usb_moded /com/meego/usb_moded com.meego.usb_moded.set_whitelisted string:developer_mode boolean:true 2>&1
            dbus-send --system --print-reply --dest=com.meego.usb_moded /com/meego/usb_moded com.meego.usb_moded.set_mode string:developer_mode 2>&1
            sleep 1
            echo "--- forcing UDC rebind so host re-enumerates with new gadget composition ---"
            echo "before: functions=$(ls /sys/kernel/config/usb_gadget/g1/functions 2>&1) c.1=$(ls /sys/kernel/config/usb_gadget/g1/configs/c.1 2>&1 | grep -v '^total\|^MaxPower\|^bmAttributes')"
            echo '' > /sys/kernel/config/usb_gadget/g1/UDC 2>&1
            echo "unbind status=$?"
            sleep 2
            echo "$(ls /sys/class/udc 2>/dev/null)" > /sys/kernel/config/usb_gadget/g1/UDC 2>&1
            echo "rebind status=$?"
            sleep 1
            echo "after: functions=$(ls /sys/kernel/config/usb_gadget/g1/functions 2>&1) c.1=$(ls /sys/kernel/config/usb_gadget/g1/configs/c.1 2>&1 | grep -v '^total\|^MaxPower\|^bmAttributes')"
        fi
        echo
    } >> "$OUT" 2>&1
    i=$((i+1))
    sleep 3
done
{
    echo "=== final journalctl -u usb-moded -b ==="
    journalctl -u usb-moded -b --no-pager -n 500 2>&1
} >> "$OUT" 2>&1
