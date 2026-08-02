#!/bin/sh
export HYBRIS_LD_LIBRARY_PATH=/opt/halium-lxc-bridge/system-lib64:/opt/halium-lxc-bridge/vendor-lib64

while true
do
    /usr/bin/getprop | grep -q init.svc.*.bluetooth.audio
    if [ $? -eq 0 ] ; then
        bt_status=$(/usr/bin/getprop |grep "init.svc.*bluetooth" |grep -v audio |grep -o "\[running\]")
    else
        bt_status=$(/usr/bin/getprop |grep "init.svc.*bluetooth" |grep -o "\[running\]")
    fi
    if [ "$bt_status" = "[running]" ] ; then
        echo "Bluetooth service running"
        exit 0
    fi
    echo "Waiting for bluetooth service"
    sleep 1
done
exit 1
