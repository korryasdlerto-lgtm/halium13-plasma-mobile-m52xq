#!/bin/sh
# ПОРТИРОВАНО 2026-09-06 из соседнего Droidian-проекта на этом же
# устройстве (halium-container-autostart.sh, в его в38), с тех пор
# тайминг несколько раз менялся по факту живых тестов на этом
# устройстве. Единый постоянный механизм автостарта Android-контейнера
# -- работает на КАЖДОЙ загрузке (не только первой), через таймер с
# задержкой 45с (halium-container-autostart.timer). Разница между
# первым и всеми последующими стартами -- только в задержке, реализована
# ВНУТРИ этого скрипта, без отдельной маскировки/размаскировки других
# юнитов:
#   - маркера /userdata/CONTAINER_ENABLED ещё нет -> это первый запуск
#     после флеша, досыпаем ещё 10с (итого 55с с момента boot, вместо
#     обычных 45с) -- даём хост-стороне (systemd/Plasma Mobile/
#     usb-moded) побольше времени стабилизироваться на самой
#     нестабильной загрузке, ПОТОМ создаём маркер и стартуем.
#   - маркер уже есть -> обычная загрузка, стартуем сразу (45с с
#     момента boot, без дополнительной задержки).
#
# ИСТОРИЯ ТАЙМИНГА (все правки живьём, на этом же устройстве):
#   в9 (порт из Droidian): 25с/45с -- в живом тесте даже "первых" 45с
#     не хватило, контейнер не отвечал (`lxc-attach: Connection
#     refused`). Временно переключили на "всегда 45с".
#   в10 (сейчас): база таймера поднята до 45с, +10с на первом запуске
#     (итого 45с/55с) -- ветка "первый раз это или нет" возвращена
#     обратно, просто с бОльшими числами.
#
# ЗАМЕНЯЕТ собой в8's предыдущий подход ("touch /data/CONTAINER_ENABLED"
# прямо в update-binary при флеше -- маркер стоял уже В МОМЕНТ первой
# загрузки, то есть lxc@android.service мог стартовать вообще без
# задержки, той же гонкой, что уронила в5 на 5+ минут без картинки/SSH,
# см. FIXES-V7-DESKTOP-AND-AUTOSTART.md). update-binary снова сбрасывает
# маркер при каждом флеше (как было в в7) -- решение "первый раз это
# или нет" теперь целиком внутри этого скрипта, а не в update-binary.
#
# ОТЛИЧИЕ ОТ ДРОИДИАНА: здесь контейнерный юнит называется
# lxc@android.service (шаблонный lxc-android-config юнит), а не
# lxc-android-config.service -- см. halium-enable-container.sh и
# lxc@android.service.d/00-first-boot-gate.conf в этом же проекте.
#
# в11, НАЙДЕНО 2026-09-07 (живой, многократно повторяющийся баг на
# КАЖДОЙ прошивке/загрузке): `/` иногда поднимается ОБРАТНО в ro
# (overlay поверх rootfs.img остаётся read-only вместо ожидаемого rw)
# -- причина в initrd, не найдена (нужна разборка boot.img, не
# сделано). Следствие: lxc@android.service падает с "Failed to set up
# special execution directory in /var/lib: Read-only file system"
# (status=238/STATE_DIRECTORY), контейнер никогда не стартует, весь
# HAL-мост (камера/сенсоры/телефония/bluetooth) недоступен до ручного
# `mount -o remount,rw /` по SSH. Раньше чинилось только вручную,
# каждый раз заново после каждой перезагрузки/перепрошивки. Теперь --
# автоматическая проверка+фикс прямо здесь, перед стартом контейнера.
LOG_TAG="halium-container-autostart"
log() {
    echo "$LOG_TAG: $1" | systemd-cat -t "$LOG_TAG" -p info
}

# в20, НАЙДЕНО 2026-09-08 (живой краш-тест на свежепрошитой в15, фикс
# перенесён и в эту в14-базированную сборку): блок ro-remount ниже
# раньше стоял ПОСЛЕ трёх лок-скрин фиксов (chgrp shadow/chmod
# kscreenlocker_greet/sed HandlePowerKey). На реальной загрузке /
# оказался ещё смонтирован ro именно в момент выполнения chmod -- он
# тихо провалился ("Файловая система доступна только для чтения",
# ошибка ушла только в лог, скрипт не остановился), а chgrp shadow
# чуть выше почему-то прошёл (видимо, /etc и /usr в этот момент были
# в разном состоянии по записи). Итог: kscreenlocker_greet снова
# оказался с правами 000, экран блокировки не мог запуститься, "пароль
# не спрашивает" после свежей прошивки. Фикс: проверка+remount,rw
# теперь САМАЯ ПЕРВАЯ операция в скрипте, до вообще любой попытки
# что-то менять в /etc или /usr.
ROOT_MOUNT_OPTS=$(awk '$2 == "/" {print $4}' /proc/mounts)
case ",$ROOT_MOUNT_OPTS," in
    *,ro,*)
        log "/ смонтирован ro -- remount,rw в самом начале, до лок-скрин фиксов (в11-баг с initrd)"
        mount -o remount,rw /
        NEW_OPTS=$(awk '$2 == "/" {print $4}' /proc/mounts)
        case ",$NEW_OPTS," in
            *,ro,*) log "ПРЕДУПРЕЖДЕНИЕ: remount,rw не сработал, / всё ещё ro -- все дальнейшие фиксы, скорее всего, тоже провалятся" ;;
            *) log "remount,rw успешен" ;;
        esac
        ;;
    *)
        log "/ уже rw, remount не нужен"
        ;;
esac

# в14, НАЙДЕНО 2026-09-08 (по прямой наводке из истории соседнего
# Droidian-проекта -- у них ИДЕНТИЧНЫЙ баг, в35->в36): /etc/shadow
# оказывается группы root вместо shadow на каждой свежей загрузке
# (/etc -- тот же tmpfs-оверлей, что и весь /, сбрасывается каждый
# раз). Из-за этого setgid-хелпер unix_chkpwd (root:shadow) получает
# EACCES при открытии /etc/shadow, и ЛЮБАЯ проверка пароля через PAM
# (экран блокировки, su, login) либо не проходит вообще, либо ведёт
# себя непредсказуемо. У Droidian строка live-подтверждена, у нас
# живьём подтверждено ТО ЖЕ самое (group=root) вечером 2026-09-08.
chgrp shadow /etc/shadow 2>&1 | while IFS= read -r line; do log "chgrp shadow /etc/shadow: $line"; done
log "/etc/shadow group fixed to shadow (was root on this boot: $([ "$(stat -c %G /etc/shadow)" = shadow ] && echo ok || echo STILL-WRONG))"

# в14, НАЙДЕНО 2026-09-08: kscreenlocker_greet (бинарник экрана
# блокировки) идёт в пакете с правами 000 -- буквально ни у кого нет
# права его выполнить, даже у root (для execute Linux не даёт
# CAP_DAC_OVERRIDE переопределить полностью нулевые права). Без этого
# фикса экран блокировки в принципе не может запуститься -- ни по
# таймауту простоя, ни по кнопке. НЕ setuid (Qt сам откажется
# стартовать setuid-бинарник как "security hole") -- обычные 755,
# аутентификация всё равно идёт через отдельный setgid-shadow хелпер
# unix_chkpwd, а не через права самого greeter.
chmod 755 /usr/lib/aarch64-linux-gnu/libexec/kscreenlocker_greet 2>&1 | while IFS= read -r line; do log "chmod kscreenlocker_greet: $line"; done

# в14, НАЙДЕНО 2026-09-08: логинд по умолчанию делает poweroff по
# короткому нажатию кнопки питания. Меняем на блокировку экрана --
# использует ТОТ ЖЕ нативный пайплайн, что уже подтверждён рабочим
# через таймаут простоя (kscreenlocker greeter + PAM). logind.conf --
# тоже /etc, тоже tmpfs, тоже сбрасывается каждую загрузку.
sed -i 's/^#\?HandlePowerKey=.*/HandlePowerKey=lock/' /etc/systemd/logind.conf 2>&1 | while IFS= read -r line; do log "logind.conf HandlePowerKey: $line"; done
systemctl reload systemd-logind.service 2>&1 | while IFS= read -r line; do log "logind reload: $line"; done

if [ ! -f /userdata/CONTAINER_ENABLED ]; then
    log "no marker yet -- first boot, sleeping extra 10s (55s total)"
    sleep 10
    touch /userdata/CONTAINER_ENABLED
    log "marker created"
else
    log "marker already exists -- regular boot (45s total)"
fi

systemctl reset-failed lxc@android.service 2>/dev/null
systemctl start lxc@android.service
log "container start requested"

# ПОРТИРОВАНО ВМЕСТЕ С ТАЙМЕРОМ (тот же родной скрипт в Droidian):
# найдено в параллельном (Ubuntu Touch) проекте на этом же устройстве,
# актуально и здесь -- system.img тот же самый файл (общий симлинк),
# userdebug-сборка. RescueParty.java (isDisabled(), ~строка 151):
#   if (Build.IS_USERDEBUG && isUsbActive()) { return true; /* disabled */ }
# -- на подключённом USB RescueParty самоотключается, но на батарее
# защита снимается: при повторяющемся краше system_server RescueParty
# проходит полную эскалационную лестницу (RESET_SETTINGS_* ->
# WARM_REBOOT) за ~45 секунд и финальный system_server шлёт
# sys.powerctl='reboot,RescueParty' -- настоящий полный ребут
# устройства, инициированный самим Android, не краш "снизу".
# persist.sys.disable_rescue=true -- официальное AOSP-свойство,
# полностью отключает RescueParty, переживает перезагрузку. К этому
# моменту lxc-android-ready (ExecStartPost) уже отработал -- systemctl
# start синхронный и не возвращается, пока весь ExecStartPost не
# завершится -- property-сервис контейнера точно поднят.
lxc-attach -n android -- setprop persist.sys.disable_rescue true 2>&1 | \
    while IFS= read -r line; do log "disable_rescue setprop: $line"; done
log "persist.sys.disable_rescue=true applied"
