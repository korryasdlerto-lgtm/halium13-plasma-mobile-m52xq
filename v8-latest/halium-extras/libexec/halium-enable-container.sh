#!/bin/sh
# Ручной запуск Android-контейнера. Контейнер больше НИКОГДА не
# стартует сам (см. lxc@android.service.d/00-first-boot-gate.conf) --
# запускать только этим скриптом, когда SSH/раб.стол уже точно живы.
#
# ИСПРАВЛЕНО 2026-08-01 (в7): этот файл достался в наследство от фазы
# Droidian и ссылался на "lxc-android-config.service" (стоковый юнит
# из пакета lxc-android-config) -- НЕ на наш кастомный шаблонный юнит
# "lxc@android.service". Наш проект использует именно lxc@android.service,
# так что ЭТОТ старый скрипт никогда не запускал наш контейнер (был
# мёртвым кодом), а стоковый lxc-android-config.service мог всё это
# время оставаться СВОИМ отдельным, не заблокированным путём автозапуска
# -- вероятный кандидат на "просочившийся" через наш запрет контейнер
# (см. 00-first-boot-gate.conf в этой же папке). Нужно ЛИБО убедиться
# что lxc-android-config.service отключён/замаскирован, ЛИБО тоже
# повесить на него ConditionPathExists.
touch /userdata/CONTAINER_ENABLED
systemctl start lxc@android.service
