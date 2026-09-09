#!/bin/sh
# Fallback in case the udev KERNEL== name for this kernels binder driver
# doesnt match our rules (binder vs binder0 vs binderfs-mounted nodes) --
# just chmod whatever actually exists, unconditionally, before phosh starts.
for f in /dev/binder /dev/binder0 /dev/hwbinder /dev/vndbinder /dev/binderfs/binder /dev/binderfs/hwbinder /dev/binderfs/vndbinder; do
    [ -e "$f" ] && chmod 0666 "$f" 2>/dev/null
done
echo "$(date) binder devices: $(ls -la /dev/binder* /dev/hwbinder /dev/vndbinder /dev/binderfs/ 2>&1 | tr "\n" " ")" >> /var/log/halium-binder-chmod.log
exit 0
