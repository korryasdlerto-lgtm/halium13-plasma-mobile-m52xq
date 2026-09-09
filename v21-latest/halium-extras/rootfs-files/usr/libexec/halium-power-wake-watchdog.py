#!/usr/bin/env python3
# в16, СОЗДАНО 2026-09-08 (перенесено в эту в14-базированную сборку
# как в20): живой, повторяющийся баг -- panel0-backlight's bl_power и
# DRM-выхода card0-DSI-1's dpms иногда залипают в "выключено" после
# ухода экрана в сон по таймауту простоя, хотя brightness остаётся
# ненулевым. Простое `echo 0 > .../bl_power` не помогает -- реальный
# DPMS на уровне DRM/KMS управляется исключительно самим
# compositor'ом (wayfire) через atomic-commit, sysfs-путь
# /sys/class/drm/.../dpms в этом ядре read-only даже для root.
# Единственный подтверждённый живьём рабочий фикс --
# `systemctl restart plasma-mobile-wf.service` (полный передёрг
# сессии), проверено дважды за один вечер.
#
# ВАЖНО, извлечённый урок из истории этого проекта: предыдущий
# watchdog (halium-plasma-shell-watchdog.sh, в10/в11) угадывал
# "легитимна ли ещё загрузка" по таймингам (grace period от
# /proc/<pid>/stat) и минимум дважды ложно убивал нормально
# стартующую сессию -- полностью удалён в в12 по явному требованию
# пользователя. Этот watchdog НЕ повторяет ту ошибку: он не гадает по
# времени вообще. Единственное условие срабатывания -- реальное,
# измеримое состояние ядра (dpms == "Off") в момент физического
# короткого нажатия кнопки питания (KEY_POWER, event0/qpnp_pon --
# штатный Qualcomm PMIC power-on драйвер на этом чипсете). Экран не
# может быть "легитимно ожидаемо" в DPMS=Off ИМЕННО в момент нажатия
# кнопки питания -- пользователь физически хочет его включить. Нет
# способа ложно сработать на нормальной загрузке: сервис не трогает
# ничего, пока кто-то не нажмёт кнопку питания, а на свежей загрузке
# экран по определению не в DPMS=Off (иначе там нечего было бы
# показывать пользователю).
#
# Если dpms уже "On" в момент нажатия -- сервис ничего не делает,
# отдавая нажатие штатной обработке HandlePowerKey=lock в logind
# (никакого перехвата/grab устройства -- просто параллельное
# неисключительное чтение того же /dev/input/event0, оба слушателя
# получают событие независимо).

import struct
import subprocess
import time

DEV_PATH = "/dev/input/event0"  # qpnp_pon -- кнопка питания на этом чипсете
DPMS_PATH = "/sys/class/drm/card0/card0-DSI-1/dpms"
SERVICE = "plasma-mobile-wf.service"

EVENT_FMT = "llHHi"  # struct input_event: timeval{sec,usec} + type + code + value
EVENT_SIZE = struct.calcsize(EVENT_FMT)

EV_KEY = 1
KEY_POWER = 116


def log(msg):
    subprocess.run(
        ["systemd-cat", "-t", "halium-power-wake-watchdog", "-p", "info"],
        input=msg.encode(),
    )


def dpms_is_off():
    try:
        with open(DPMS_PATH) as f:
            return f.read().strip() == "Off"
    except OSError:
        return False


def wake_session():
    log(f"KEY_POWER нажата при dpms=Off -- перезапускаю {SERVICE}")
    subprocess.run(["systemctl", "restart", SERVICE])


def main():
    log("запущен, слежу за " + DEV_PATH)
    while True:
        try:
            with open(DEV_PATH, "rb") as dev:
                while True:
                    data = dev.read(EVENT_SIZE)
                    if len(data) != EVENT_SIZE:
                        continue
                    _, _, ev_type, code, value = struct.unpack(EVENT_FMT, data)
                    if ev_type == EV_KEY and code == KEY_POWER and value == 1:
                        if dpms_is_off():
                            wake_session()
        except OSError as e:
            # устройство временно недоступно (например, во время
            # переинициализации compositor'а) -- не падать насовсем,
            # подождать и переоткрыть
            log(f"ошибка чтения {DEV_PATH}: {e}, повтор через 3с")
            time.sleep(3)


if __name__ == "__main__":
    main()
