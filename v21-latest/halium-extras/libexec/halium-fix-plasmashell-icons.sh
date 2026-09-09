#!/bin/sh
# НАЙДЕНО 2026-09-07: известный, ранее только задокументированный
# (не исправленный) баг -- см. README соседнего репо
# halium13-plasma-mobile-m52xq, "Known issues": Kirigami.Icon's
# `status` property иногда навсегда зависает на `Loading` (никогда не
# переходит в `Ready`), из-за чего ВСЕ ярлыки на домашнем экране
# невидимы (хотя функционально рабочие -- тап и драг работают).
# Подтверждено живьём на этом устройстве: баг гоночный, НЕ на каждой
# загрузке, и один рестарт plasmashell тоже не 100%-но лечит -- иногда
# нужно несколько попыток. Причина -- логическая гонка внутри
# libkirigami6/libKF6IconThemes'ного асинхронного кода загрузки
# иконок, вне исходников этого проекта.
#
# ОБНОВЛЕНО 2026-09-07 (по явному запросу): вместо слепого
# безусловного рестарта -- реальная проверка через тот же маркер, что
# использовался при живой диагностике: если после рестарта plasmashell
# в его собственном логе снова всплывает "kf.iconthemes: Icon theme
# \"\" not found", значит гонка повторилась -- пробуем ещё раз, до
# MAX_ATTEMPTS попыток.
LOG_TAG="halium-fix-plasmashell-icons"
MAX_ATTEMPTS=3
WAIT_FOR_PID_SEC=60
CHECK_LOG="/tmp/.halium-fix-plasmashell-icons-check.log"

log() {
    echo "$LOG_TAG: $1" | systemd-cat -t "$LOG_TAG" -p info
}

# Ждём, пока plasmashell вообще появится (за 5с после boot он может
# ещё не успеть стартовать в первый раз -- см. историю тайминга в
# halium-container-autostart.sh, тот же класс проблемы).
i=0
PLASMASHELL_PID=""
while [ "$i" -lt "$WAIT_FOR_PID_SEC" ]; do
    PLASMASHELL_PID=$(pgrep -n -u phablet plasmashell)
    [ -n "$PLASMASHELL_PID" ] && break
    sleep 1
    i=$((i + 1))
done

if [ -z "$PLASMASHELL_PID" ]; then
    log "plasmashell не запустился за ${WAIT_FOR_PID_SEC}с, сдаёмся"
    exit 0
fi

attempt=1
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    ENVFILE="/proc/$PLASMASHELL_PID/environ"
    WAYLAND_DISPLAY_VAL=$(tr '\0' '\n' < "$ENVFILE" 2>/dev/null | sed -n 's/^WAYLAND_DISPLAY=//p')
    DBUS_ADDR_VAL=$(tr '\0' '\n' < "$ENVFILE" 2>/dev/null | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p')
    XDG_RUNTIME_VAL=$(tr '\0' '\n' < "$ENVFILE" 2>/dev/null | sed -n 's/^XDG_RUNTIME_DIR=//p')

    if [ -z "$WAYLAND_DISPLAY_VAL" ] || [ -z "$DBUS_ADDR_VAL" ] || [ -z "$XDG_RUNTIME_VAL" ]; then
        log "попытка $attempt: не удалось прочитать переменные окружения сессии из pid $PLASMASHELL_PID, сдаёмся"
        exit 0
    fi

    log "попытка $attempt: убиваем plasmashell (pid $PLASMASHELL_PID), перезапускаем с проверкой иконочной темы"
    kill -9 "$PLASMASHELL_PID"
    sleep 1
    rm -f "$CHECK_LOG"

    su phablet -c "env XDG_SESSION_TYPE=wayland DBUS_SESSION_BUS_ADDRESS='$DBUS_ADDR_VAL' WAYLAND_DISPLAY='$WAYLAND_DISPLAY_VAL' XDG_RUNTIME_DIR='$XDG_RUNTIME_VAL' XDG_CURRENT_DESKTOP=KDE QT_PLUGIN_PATH=/usr/lib/aarch64-linux-gnu/qt6/plugins PLASMA_DEFAULT_SHELL=org.kde.plasma.mobileshell QT_LOGGING_RULES='kf.iconthemes.debug=true' setsid /usr/bin/plasmashell > '$CHECK_LOG' 2>&1 < /dev/null &"

    # Даём новому процессу время дойти до момента, когда он либо
    # успешно проинициализировал иконочную тему, либо застрял --
    # тот же маркер ошибки, что подтверждён живьём при диагностике.
    sleep 8

    NEW_PID=$(pgrep -n -u phablet plasmashell)
    if [ -z "$NEW_PID" ]; then
        log "попытка $attempt: plasmashell не поднялся после рестарта, сдаёмся"
        exit 0
    fi

    if grep -q 'kf.iconthemes: Icon theme "" not found' "$CHECK_LOG" 2>/dev/null; then
        log "попытка $attempt: гонка повторилась (\"Icon theme not found\" снова в логе)"
        PLASMASHELL_PID="$NEW_PID"
        attempt=$((attempt + 1))
        continue
    fi

    log "попытка $attempt: иконочная тема загрузилась чисто, готово"
    exit 0
done

log "исчерпаны все $MAX_ATTEMPTS попытки, иконки могут остаться невидимыми до ручного вмешательства"
