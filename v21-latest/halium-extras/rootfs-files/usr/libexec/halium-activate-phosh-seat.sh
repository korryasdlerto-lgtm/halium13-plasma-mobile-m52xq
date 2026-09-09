#!/bin/sh
while :; do
    SID=$(loginctl list-sessions --no-legend 2>/dev/null | grep tty7 | awk '{print $1}')
    if [ -n "$SID" ]; then
        loginctl activate "$SID" 2>/dev/null
    fi
    sleep 0.1
done
