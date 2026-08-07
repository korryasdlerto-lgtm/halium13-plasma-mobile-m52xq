#!/bin/sh
# Ручной запуск Android-контейнера. Контейнер больше НИКОГДА не
# стартует сам (см. lxc-android-config.service.d/00-first-boot-gate.conf) --
# запускать только этим скриптом, когда SSH/раб.стол уже точно живы.
touch /userdata/CONTAINER_ENABLED
systemctl start lxc-android-config.service
