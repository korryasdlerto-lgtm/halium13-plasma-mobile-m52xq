#!/bin/sh
# FOUND 2026-07-21 live: on a fresh flash, the touch IC (synaptics_ts)
# frequently comes up only PARTIALLY initialized -- kernel module loaded
# (lsmod shows it), but only /dev/input/event6 (sec_touchscreen) exists,
# not event7/8/9 (sec_touchpad/sec_touchproximity/uinput-sec-fp). Same
# "wedged touch IC" class of bug documented for the parallel Ubuntu
# Touch/Lomiri project on this same device -- a single rmmod+insmod
# cycle of JUST synaptics_ts.ko (nothing else -- see the safety note
# below) resets the IC and all 4 input devices reappear.
#
# CRITICAL SAFETY NOTE (carried over from the parallel project's own
# hard lesson): NEVER rmmod multiple kernel modules in one invocation --
# doing so caused immediate spontaneous device reboots there. Only
# ever touch synaptics_ts.ko itself; its dependencies (sec_common_fn,
# sec_tsp_dumpkey, sec_tclm_v2, sec_cmd, sec_secure_touch, sec_tsp_log)
# are left alone -- reinserting synaptics_ts.ko alone is what actually
# clears a wedged IC (confirmed live).
#
# Idempotent: only acts if event7 is missing; safe to run on every
# phosh.service start.
#
# ADDED 2026-07-23: this script was previously connected via
# ExecStartPre on phosh.service and caused a real regression --
# phosh.service restarts frequently enough on this hardware that the
# rmmod/insmod cycle could get retriggered too often, and repeated
# rmmod/insmod under load made the device totally unresponsive
# (SSH/adb "No route to host"). The event7-presence check alone wasn't
# enough (there may be a window where event7 briefly disappears between
# restarts, retriggering the cycle). Added a hard rate-limit: skip
# entirely if we already ran within the last RATE_LIMIT_SEC seconds,
# regardless of event7 state.
LOG=/userdata/halium-fix-touch-and-unlock.log
MARKER=/userdata/halium-fix-touch-and-unlock.lastrun
MARKER2=/userdata/halium-fix-touch-and-unlock-settings-done
RATE_LIMIT_SEC=60
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null; }

log "=== start ==="

now=$(cut -d' ' -f1 /proc/uptime)
now=${now%.*}
if [ -f "$MARKER" ]; then
    last=$(cat "$MARKER" 2>/dev/null)
    last=${last:-0}
    elapsed=$((now - last))
    # НАЙДЕНО 2026-07-23: marker хранит /proc/uptime от ПРЕДЫДУЩЕЙ загрузки,
    # но после ребута /proc/uptime сбрасывается в маленькое число -- elapsed
    # уходит в минус, и "elapsed -lt RATE_LIMIT_SEC" на отрицательном числе
    # тоже true, так что фикс тача ошибочно пропускался на каждой свежей
    # загрузке. Явная проверка "elapsed -ge 0" отличает реальный недавний
    # запуск от заново обнулившегося аптайма.
    if [ "$elapsed" -ge 0 ] && [ "$elapsed" -lt "$RATE_LIMIT_SEC" ]; then
        log "rate-limited: only ${elapsed}s since last run (< ${RATE_LIMIT_SEC}s), skipping entirely"
        log "=== end (rate-limited) ==="
        exit 0
    fi
fi
echo "$now" > "$MARKER"

if [ ! -e /dev/input/event7 ]; then
    log "touch IC looks wedged (event7 missing) -- reloading synaptics_ts.ko"
    MOD=/userdata/kernel-modules-fixed/synaptics_ts.ko
    if [ -f "$MOD" ]; then
        /usr/sbin/rmmod synaptics_ts 2>>"$LOG"
        rc=$?
        log "rmmod synaptics_ts exit=$rc"
        if [ "$rc" = "0" ]; then
            sleep 1
            /usr/sbin/insmod "$MOD" 2>>"$LOG"
            log "insmod synaptics_ts exit=$?"
            sleep 2
        fi
    else
        log "module not found at $MOD, skipping"
    fi
    ls -la /dev/input/ >> "$LOG" 2>&1
else
    log "touch devices already present, skipping reload"
fi

# FOUND 2026-07-20/21: on-screen PIN entry is unreliable enough on this
# hardware (touch taps not always landing precisely on the small keypad
# buttons) that the lockscreen effectively blocks getting to the
# desktop even though the password itself is correct -- see project
# history. Disabling require-unlock removes the PIN gate entirely.
# Must run as the actual phablet user (uid 1000) with its own
# XDG_RUNTIME_DIR -- running this as root against uid 1000's runtime
# dir fails ("owned by uid 1000, not our uid 0").
#
# НАЙДЕНО 2026-07-24 (вероятный корень "phoc теряет seat через ~20с"
# бага): "su - phablet" (login-shell, дефис) идёт через ДРУГОЙ PAM-стек
# (su-l) чем "su phablet" (обычный su) -- confirmed live через
# journalctl: su-l создаёт полноценную залогиненную PAM-сессию, которая
# иногда получает от logind тот же номер сессии (session/cN), что
# буквально через мгновение потом присваивается собственной
# PAMName=login-сессии capsh/phoc (см. phosh.service). Когда su-l
# закрывается (после недолгого асинхронного "waiting for processes to
# exit"), logind, похоже, сносит D-Bus объект session/cN уже ПОСЛЕ
# переиспользования номера для сессии phoc -- откуда и "Could not close
# device: Unknown object session/cN" и следом "Your session has no
# seat" у phoc, хотя сам phoc не падал и продолжает работать. Этот
# скрипт запускается через ExecStartPre НА КАЖДОМ старте phosh.service,
# то есть на каждом старте гонка повторяется. Убран дефис -- обычный su
# идёт через лёгкий PAM-стек (su, не su-l) и не создаёт отдельную
# нумерованную logind-сессию, что должно устранить гонку. XDG_RUNTIME_DIR
# и так задаётся явно ниже, login-шелл для этого не требовался.
# НАЙДЕНО 2026-07-25: su-l дефис убрали 2026-07-24, но dbus-run-session САМ
# ПО СЕБЕ тоже открывает отдельную PAM/logind-сессию (та же гонка за
# номером session/cN с capsh/phoc) -- этот блок гонял dbus-run-session НА
# КАЖДОМ старте phosh.service без всякой защиты "один раз", то есть гонка
# повторялась каждый рестарт (подтверждено живьём: сессия/яркость умирали
# через ~20с после каждого рестарта phosh.service, даже без вотчдога).
# gsettings-значение персистентно (dconf), повторный запуск после первого
# успешного не нужен -- защищаем маркером, как touch-фикс выше.
if [ ! -f "$MARKER2" ]; then
    su phablet -c 'XDG_RUNTIME_DIR=/run/user/1000 dbus-run-session -- python3 -c "
import gi
gi.require_version(\"Gio\", \"2.0\")
from gi.repository import Gio
s = Gio.Settings.new(\"sm.puri.phosh.lockscreen\")
s.set_boolean(\"require-unlock\", False)
Gio.Settings.sync()
"' >> "$LOG" 2>&1
    touch "$MARKER2"
    log "require-unlock=false applied (attempted, first time)"
else
    log "settings guard: already applied before, skipping dbus-run-session entirely"
fi

# НАЙДЕНО 2026-07-25: смена языка в Настройках пишет только в
# AccountsService (/var/lib/AccountsService/users/phablet, Languages=)
# -- обычно это читает гритер при логине, а у нас автологин через
# capsh, так что этот шаг никогда не выполнялся (см. halium-restore-
# state.sh, где такой же мост уже есть, но тот скрипт гоняется только
# ОДИН РАЗ за полную загрузку). Дублируем мост здесь, так как этот
# скрипт запускается на КАЖДОМ старте phosh.service (ExecStartPre) --
# чтобы смена языка применялась просто рестартом phosh, без полной
# перезагрузки устройства. Без гонки/защиты маркером не обойтись
# смысла нет -- это чистое чтение+запись файлов, дешёвое и безопасное
# на каждом запуске.
_as_lang=""
if [ -f /var/lib/AccountsService/users/phablet ]; then
    _as_lang=$(grep '^Languages=' /var/lib/AccountsService/users/phablet 2>/dev/null | \
        sed 's/^Languages=//; s/;.*//')
fi
if [ -n "$_as_lang" ] && locale -a 2>/dev/null | grep -qi "^$(echo "$_as_lang" | sed 's/UTF-8/utf8/i')\$"; then
    _cur_lang=$(grep '^LANG=' /etc/default/locale 2>/dev/null | sed 's/^LANG=//')
    if [ "$_cur_lang" != "$_as_lang" ]; then
        cat > /etc/default/locale <<LOCALE_EOF
#  File generated by update-locale
LANG=$_as_lang
LC_MESSAGES=$_as_lang
LC_CTYPE=$_as_lang
LOCALE_EOF
        cp /etc/default/locale /userdata/saved-locale.txt 2>/dev/null
        log "locale bridge: AccountsService language ($_as_lang) applied to /etc/default/locale"
    fi
fi

log "=== end ==="
exit 0
