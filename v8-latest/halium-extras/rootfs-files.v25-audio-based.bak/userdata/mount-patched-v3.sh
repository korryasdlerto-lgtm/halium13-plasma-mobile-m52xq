#!/bin/sh
# КРИТИЧЕСКАЯ НАХОДКА 2026-07-19: LXC применяет `lxc.environment =
# PATH=...` (заданный в /var/lib/lxc/android/config для окружения
# КОНТЕЙНЕРА -- /system/bin:/vendor/bin:/apex/... и т.д.) ТАКЖЕ и к
# ЭТОМУ хук-скрипту (lxc.hook.mount), хотя mount.sh -- ХОСТОВЫЙ
# скрипт, которому нужны ХОСТОВЫЕ /bin, /usr/bin. Из-за этого "mount",
# "install", "grep", "head" и другие базовые утилиты были "not found"
# (exit 127) практически ВЕЗДЕ в этом файле, молча проглатываемые
# "|| true" -- подтверждено live-диагностикой (mount-hook.log без
# "2>/dev/null"). Вероятно, объясняет МНОГИЕ "тихо не срабатывающие"
# фиксы за всю историю проекта, не только libnativeloader.so. Явно
# восстанавливаем хостовый PATH в самом начале скрипта. См.
# DROIDIAN-V2-SYSTEMD-FIX-HOWTO.md Находка 20.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
exec >> /userdata/mount-hook.log 2>&1
set -x

# ПРЕДОХРАНИТЕЛЬ 2026-07-18 (v2, безусловный): персистентный счётчик
# на /userdata НЕ переживает между попытками ИЗ ЭТОГО контекста
# (cat каждый раз видит пустоту, хотя echo только что писал "1" --
# ещё один случай "не персистится между per-attempt namespace",
# аналогично bind-mount'ам). Вместо счётчика -- простая безусловная
# пауза КАЖДУЮ попытку, тормозит тугой бесконечный цикл
# "Container requested reboot" (сотни/мин без этого) до разумного
# темпа, вне зависимости от того, работает ли персистентность.
echo "CIRCUITBREAKER unconditional sleep 3s"
sleep 3

R="${LXC_ROOTFS_MOUNT}"

# НАЙДЕНО 2026-07-19 (Находка 33): "${R}/data/user/0" оказался
# ОТДЕЛЬНЫМ bind-mount'ом (mount id виден в mountinfo как child
# отдельного /data), хотя "${R}/data/user_de/0" -- просто обычный
# подкаталог того же /data. Оба физически на одном разделе
# (/dev/sda34), но раз это РАЗНЫЕ vfsmount, rename(2) между ними
# возвращает EXDEV ("Cross-device link") -- installd мигрирует данные
# пакетов из user/0 в user_de/0 через rename() и ПОГОЛОВНО падает на
# этом для КАЖДОГО пакета (включая com.android.providers.settings,
# из-за чего SettingsProvider не может открыть свою БД и system_server
# уходит в FATAL EXCEPTION). Источник этого лишнего под-mount'а не
# найден (не наш config/mount.sh, вероятно остаточный vold-артефакт на
# самой партиции) -- просто размонтируем его, чтобы user/0 снова стал
# обычным подкаталогом, как user_de/0.
umount "${R}/data/user/0" 2>/dev/null || true

# ОТКАЧЕНО 2026-07-19 (Находка 22): пробовали здесь bind делегированной
# cgroup2-директории этого запуска (/sys/fs/cgroup/lxc.payload.android-N)
# поверх ${R}/sys/fs/cgroup, чтобы обойти EROFS от nsdelegate -- НЕ
# ПОМОГЛО (тот же EROFS даже для верно определённого поддерева). Реальный
# фикс -- убрать cgroup2 lxc.mount.entry из config целиком (см. config,
# Находка 22) -- без него /sys/fs/cgroup внутри контейнера просто не
# смонтирован, и createProcessGroup() деградирует до мягкого
# предупреждения вместо фатальной ошибки.

# НАЙДЕНО 2026-07-18 через init-eloop-diag: exec("/init") ловил ELOOP не
# из-за резолва самого /init (он чистый, ведёт на реальный файл
# system/system/bin/init), а из-за ELF-интерпретатора (/system/bin/linker64
# в PT_INTERP init-бинаря). "${R}/system/bin" -- это compat-симлинк вида
# "system/bin -> /system/bin" (АБСОЛЮТНЫЙ), стандартный для system-as-root
# образов, рассчитанный на топологию где /system -- ОТДЕЛЬНЫЙ mountpoint
# внутри УЖЕ существующего "/". У нас же корень контейнера = САМА партиция
# system, поэтому "${R}/system" = вложенный system/-подкаталог партиции, и
# абсолютный "/system/bin" внутри него резолвится САМ В СЕБЯ -- petля.
# Убираем симлинк, подставляем реальный bind на настоящий вложенный каталог.
# ВАЖНО: голые команды (rm/mkdir/chmod) в этом hook-контексте
# ИНТЕРМИТТЕНТНО дают "not found" (видели даже у ДАВНО работающего
# stock-кода ниже в этом же файле -- не про позицию в скрипте, PATH
# нестабилен). `mount` при этом стабильно резолвится. Используем
# абсолютные /usr/bin/-пути вместо голых имён для надёжности.
# ВАЖНО (найдено 2026-07-18, второй заход): rm/mkdir меняют САМУ
# партицию (теперь rw) и переживают между попытками lxc-start -- но
# `mount --bind` -- per-mount-namespace (CLONE_NEWNS у каждой попытки
# свой) и НЕ переживает! Первая попытка чинит symlink -> пустой каталог
# (персистентно), но САМ bind нужно повторять КАЖДУЮ попытку, иначе
# каталог остаётся пустым (без содержимого system/system/$X) и exec
# падает на "No such file or directory" (не находит интерпретатор ELF,
# например /system/bin/linker64). rm/mkdir -- только если ещё symlink;
# mount --bind -- ВСЕГДА, если REAL существует.
# НАЙДЕНО 2026-07-19 (Находка 25): та же ELOOP/nested-shallow история,
# что и apex (Находка 21) -- "framework" отсутствовал в списке, из-за
# чего ${R}/system/framework был ПОЧТИ ПУСТ (framework.jar физически
# лежит только во вложенном system/system/framework) -- zygote реально
# доходил до инициализации ART, но падал с "Native registration unable
# to find class 'com/android/internal/os/RuntimeInit'; aborting..."
# (framework.jar из BOOTCLASSPATH банально не резолвился). Заодно
# добавлены app/priv-app (системные APK, включая Settings/SystemUI),
# fonts, usr -- та же самая нерешённая нехватка, ещё не успевшая себя
# проявить.
for SHALLOW in bin lib lib64 xbin etc apex framework app priv-app fonts usr; do
    P="${R}/system/${SHALLOW}"
    REAL="${R}/system/system/${SHALLOW}"
    if [ -d "$REAL" ]; then
        if [ -L "$P" ]; then
            /usr/bin/rm -f "$P"
            echo "SHALLOWFIX rm status=$? for $P"
        fi
        # НАЙДЕНО 2026-07-19: не только симлинк -- "$P" мог ВООБЩЕ НЕ
        # СУЩЕСТВОВАТЬ (ни файл, ни симлинк, ни каталог, как оказалось
        # для "fonts") -- mount --bind на несуществующий путь падает
        # (status=32). mkdir -p безусловно, если ещё не каталог.
        if [ ! -d "$P" ]; then
            /usr/bin/mkdir -p "$P"
            echo "SHALLOWFIX mkdir status=$? for $P"
        fi
        /usr/bin/mount --bind "$REAL" "$P"
        echo "SHALLOWFIX mount status=$? for $P"
    else
        echo "SHALLOWFIX skip $P (REAL missing)"
    fi
done

# НАЙДЕНО 2026-07-19 (Находка 26): "${R}/system/build.prop" -- битый
# АБСОЛЮТНЫЙ симлинк на "/android/system/system/build.prop" (host-путь,
# внутри контейнера бессмысленный -- нет каталога "/android"). getprop
# для vendor-свойств (ro.zygote, ro.hardware) работает нормально (440
# свойств всего), а ВСЕ system-свойства (ro.build.version.release,
# .sdk, .known_codenames и т.д.) пустые -- system/build.prop реально не
# загружается property-сервисом. zygote падает на
# android.os.Build$VERSION.<clinit>()
# (ArrayIndexOutOfBoundsException при парсинге known_codenames).
# Убираем симлинк, ставим прямой bind на настоящий вложенный файл.
if [ -L "${R}/system/build.prop" ]; then
    /usr/bin/rm -f "${R}/system/build.prop"
fi
# НАЙДЕНО 2026-07-28 (в3): исходная проверка была "if -L" -- но на живом
# устройстве "${R}/system/build.prop" не существовал вообще НИ В КАКОМ
# виде (ни файл, ни симлинк) -- -L тест ложный, заглушка не создавалась,
# и mount --bind на несуществующий путь тихо проваливался (ошибка
# заглушена "2>/dev/null || true"). Делаем создание заглушки безусловным.
if [ ! -f "${R}/system/build.prop" ]; then
    : > "${R}/system/build.prop" 2>/dev/null || true
fi
{
    echo "DEBUG buildprop: -f real = $([ -f "${R}/system/system/build.prop" ] && echo YES || echo NO)"
    echo "DEBUG buildprop: -f target before mount = $([ -f "${R}/system/build.prop" ] && echo YES || echo NO)"
} >> /userdata/mount-sh-debug.log 2>&1
/usr/bin/mount --bind "${R}/system/system/build.prop" "${R}/system/build.prop"
echo "DEBUG buildprop: mount status=$?" >> /userdata/mount-sh-debug.log 2>&1

# НАЙДЕНО 2026-07-19 (Находка 22, продолжение): "${R}/etc" (компат-симлинк
# КОРНЯ на /system/etc, обычно есть на реальных system-as-root образах)
# у нас ВООБЩЕ ОТСУТСТВУЕТ (не файл, не симлинк -- просто нет), хотя
# "${R}/system/etc" уже корректно резолвится через SHALLOWFIX выше.
# init's SetupCgroups builtin читает ЖЁСТКО ПРОПИСАННЫЙ "/etc/cgroups.json"
# (не "/system/etc/cgroups.json") -- без "/etc" эта строка ВСЕГДА "No
# such file or directory", libprocessgroup остаётся без корректного
# RC-конфига и откатывается к дефолтному (legacy, недоступному в нашем
# окружении) поведению -- "Failed to make and chown /uid_X/pid_Y:
# Read-only file system" ДЛЯ АБСОЛЮТНО ЛЮБОГО createProcessGroup(),
# включая сам zygote. Добавляем "${R}/etc" -> bind на "${R}/system/etc".
mkdir -p "${R}/etc" 2>/dev/null || true
mount --bind "${R}/system/etc" "${R}/etc" 2>/dev/null || true

mknod -m 666 "${R}/dev/null"         c 1 3  2>/dev/null || true
mknod -m 600 "${R}/dev/kmsg"         c 1 11 2>/dev/null || true
mknod -m 666 "${R}/dev/random"       c 1 8  2>/dev/null || true
mknod -m 666 "${R}/dev/urandom"      c 1 9  2>/dev/null || true
mknod -m 660 "${R}/dev/loop-control" c 10 237 2>/dev/null || true
[ -f "${R}/proc/cmdline" ] && chmod 440 "${R}/proc/cmdline" || true

for SELINUX_PATH in \
    "${R}/system/lib64/libselinux.so" \
    "${R}/lib64/libselinux.so"; do
    [ -f "$SELINUX_PATH" ] && mount --bind /userdata/libselinux-stub.so "$SELINUX_PATH" 2>/dev/null || true
done

mount -t ext4 -o ro /dev/mapper/vendor  "${R}/vendor"  2>/dev/null || true

# НАЙДЕНО 2026-07-19: настоящая причина мгновенного exit(1) у zygote --
# "CANNOT LINK EXECUTABLE /system/bin/app_process64: library
# libnativeloader.so not found" (поймано через nsenter+logcat).
# libnativeloader.so реально существует, но только внутри APEX
# com.android.art -- копируем напрямую в /system/lib64, тот же паттерн,
# что libnetd_updatable.so.
# ГЛАВНАЯ НАХОДКА (тот же день): "install"/"head"/"grep" ОТСУТСТВУЮТ в
# PATH этого хука в САМОМ НАЧАЛЕ его выполнения (подтверждено: "install:
# not found", exit 127) -- PATH стабилизируется только К ЭТОМУ моменту
# скрипта (сразу ПОСЛЕ первого успешного "mount -t ext4" выше, который
# уже РЕАЛЬНО работает -- см. следующую строку). "install -D"
# использовался в 9 местах по всему mount.sh и, видимо, молча
# проваливался РАНЬШЕ этой точки весь день (скрыто "|| true"). Заменили
# на mkdir -p + ": > file" (чистый POSIX/shell builtin, не внешняя
# команда) и разместили фикс ПОСЛЕ первого рабочего mount -- НЕ раньше.
# См. DROIDIAN-V2-SYSTEMD-FIX-HOWTO.md Находка 20.
# ЗАКОММЕНТИРОВАНО 2026-07-19 (эксперимент, Находка 28 продолжение):
# теперь, когда APEX реально активируется (Находка 21) и linkerconfig
# генерирует ПОЛНЫЙ ld.config.txt с рабочим com_android_art namespace,
# этот статический костыль (копия libnativeloader.so из ART APEX,
# подложенная в /system/lib64 в обход namespace-резолва) МОЖЕТ мешать
# ДИНАМИЧЕСКОМУ созданию classloader-namespace -- system_server падает
# с "UnsatisfiedLinkError: failed to create native namespace
# name:classloader-namespace". Пробуем убрать и положиться на
# нормальный APEX-путь.
#mkdir -p "${R}/system/lib64" 2>/dev/null || true
#mkdir -p "${R}/system/lib" 2>/dev/null || true
#: > "${R}/system/lib64/libnativeloader.so" 2>/dev/null || true
#: > "${R}/system/lib/libnativeloader.so" 2>/dev/null || true
#mount --bind /userdata/libnativeloader64.so "${R}/system/lib64/libnativeloader.so" 2>/dev/null || true
#mount --bind /userdata/libnativeloader32.so "${R}/system/lib/libnativeloader.so" 2>/dev/null || true
#chmod 644 "${R}/system/lib64/libnativeloader.so" "${R}/system/lib/libnativeloader.so" 2>/dev/null || true

# Single-arch zygote (ro.zygote=zygote64_32 -> zygote64). With the default
# dual zygote (64+32), system_server's finishBooting() notifies BOTH
# zygotes after boot_completed=1 -- if zygote_secondary (32-bit) isn't
# alive/stable at that exact moment, this throws a real
# "FATAL EXCEPTION IN SYSTEM" and kills system_server outright. Confirmed
# via live testing (an earlier part of this same overall session): with
# this fix, reached 212/213 services + sys.boot_completed=1, stable 10+s,
# and com.android.phone actually started once (died only as collateral
# when system_server itself later crashed from an UNRELATED cause -- not
# a phone-specific bug). We don't need 32-bit Android app support for
# telephony, so dropping zygote_secondary entirely is safe for our goals.
VENDOR_BUILD_PROP="${R}/vendor/build.prop"
VENDOR_BUILD_PROP_TMP="/run/halium-vendor-build.prop"
if [ -f "$VENDOR_BUILD_PROP" ]; then
    sed -e 's/^ro\.zygote=zygote64_32$/ro.zygote=zygote64/' -e 's/^ro\.apex\.updatable=true$/ro.apex.updatable=false/' -e 's/^ro\.vendor\.product\.cpu\.abilist32=.*$/ro.vendor.product.cpu.abilist32=/' -e 's/^ro\.vendor\.product\.cpu\.abilist=arm64-v8a,armeabi-v7a,armeabi$/ro.vendor.product.cpu.abilist=arm64-v8a/' "$VENDOR_BUILD_PROP" > "$VENDOR_BUILD_PROP_TMP" 2>/dev/null
    chmod 644 "$VENDOR_BUILD_PROP_TMP"
    mount --bind "$VENDOR_BUILD_PROP_TMP" "$VENDOR_BUILD_PROP" 2>/dev/null || true
fi

# НАЙДЕНО 2026-07-11: system_server падает с "*** FATAL EXCEPTION IN
# SYSTEM PROCESS" сразу после "ZygoteProcess: Failed to connect to
# Zygote through socket zygote_secondary" -- ro.zygote=zygote64 (фикс
# выше) НЕ ДОСТАТОЧЕН сам по себе: ZygoteProcess.java (framework)
# отдельно проверяет ro.product.cpu.abilist32 (НЕ ro.zygote) чтобы
# решить, нужно ли поддерживать соединение со вторичным zygote. Этот
# property резолвится из ro.system.product.cpu.abilist32 (system/build.prop,
# АВТОРИТЕТНЫЙ источник для Treble-резолва ro.product.*) -- мы патчили
# только vendor/build.prop, а system/build.prop не трогали вообще.
# Убираем 32-битный ABI отовсюду (system/vendor/odm) для консистентности.
SYSTEM_BUILD_PROP="${R}/system/build.prop"
SYSTEM_BUILD_PROP_TMP="/run/halium-system-build.prop"
if [ -f "$SYSTEM_BUILD_PROP" ]; then
    # НАЙДЕНО 2026-07-12 через strace -f реального форка system_server:
    # перед смертью процесс делает НЕ сигнал/краш, а ЧИСТЫЙ exit_group(0)
    # после СОТЕН mprotect(READ)/(READ|WRITE) переключений на ОДНОЙ
    # 4KB-странице -- классический паттерн записи ART JIT-профиля
    # (guarded mprotect при записи) в рамках Runtime shutdown. Раньше
    # (07-10, в25) была эта же гипотеза с dalvik.vm.usejitprofiles=false,
    # но патчилась в несуществующий /system/etc/prop.default (мёртвый
    # код) -- НЕ ro.*, поэтому патчим напрямую здесь, в реальном
    # авторитетном /system/build.prop.
    sed -e 's/^ro\.system\.product\.cpu\.abilist32=.*$/ro.system.product.cpu.abilist32=/' -e 's/^ro\.system\.product\.cpu\.abilist=arm64-v8a,armeabi-v7a,armeabi$/ro.system.product.cpu.abilist=arm64-v8a/' -e 's/^dalvik\.vm\.usejitprofiles=true$/dalvik.vm.usejitprofiles=false/' "$SYSTEM_BUILD_PROP" > "$SYSTEM_BUILD_PROP_TMP" 2>/dev/null
    chmod 644 "$SYSTEM_BUILD_PROP_TMP"
    mount --bind "$SYSTEM_BUILD_PROP_TMP" "$SYSTEM_BUILD_PROP" 2>/dev/null || true
fi
ODM_BUILD_PROP="${R}/vendor/odm/etc/build.prop"
ODM_BUILD_PROP_TMP="/run/halium-odm-build.prop"
if [ -f "$ODM_BUILD_PROP" ]; then
    sed -e 's/^ro\.odm\.product\.cpu\.abilist32=.*$/ro.odm.product.cpu.abilist32=/' -e 's/^ro\.odm\.product\.cpu\.abilist=arm64-v8a,armeabi-v7a,armeabi$/ro.odm.product.cpu.abilist=arm64-v8a/' "$ODM_BUILD_PROP" > "$ODM_BUILD_PROP_TMP" 2>/dev/null
    chmod 644 "$ODM_BUILD_PROP_TMP"
    mount --bind "$ODM_BUILD_PROP_TMP" "$ODM_BUILD_PROP" 2>/dev/null || true
fi
# НАЙДЕНО: /odm -- ОТДЕЛЬНЫЙ реальный раздел (не симлинк на /vendor/odm,
# своя lost+found) -- ЭТО настоящий источник резолва ro.product.cpu.abilist32
# (live-проверка: /vendor/odm/etc/build.prop патчился успешно, но
# getprop ro.product.cpu.abilist32 не менялся, пока не нашли ЭТОТ файл).
ODM2_BUILD_PROP="${R}/odm/etc/build.prop"
ODM2_BUILD_PROP_TMP="/run/halium-odm2-build.prop"
if [ -f "$ODM2_BUILD_PROP" ]; then
    sed -e 's/^ro\.odm\.product\.cpu\.abilist32=.*$/ro.odm.product.cpu.abilist32=/' -e 's/^ro\.odm\.product\.cpu\.abilist=arm64-v8a,armeabi-v7a,armeabi$/ro.odm.product.cpu.abilist=arm64-v8a/' "$ODM2_BUILD_PROP" > "$ODM2_BUILD_PROP_TMP" 2>/dev/null
    chmod 644 "$ODM2_BUILD_PROP_TMP"
    mount --bind "$ODM2_BUILD_PROP_TMP" "$ODM2_BUILD_PROP" 2>/dev/null || true
fi

# ro.zygote=zygote64 makes init.rc import init.zygote64.rc instead of
# init.zygote64_32.rc -- confirmed this system.img only ships the combined
# init.zygote64_32.rc (no separate init.zygote64.rc), so we synthesize one
# (single-arch zygote service only, no zygote_secondary block at all).
# ИСПРАВЛЕНО 2026-07-11: раньше тут был отдельный nested overlay-mount
# поверх ${R}/system/etc/init/hw -- ненадёжно (эта директория уже часть
# self-referential overlay, который pre-start.sh накладывает на весь
# /system, чтобы сделать его временно писабельным -- подтверждено живьём,
# что rm -f на /system/framework/arm64/*.oat реально срабатывает).
# Раз /system УЖЕ писабельный, просто пишем файл напрямую, без ещё одного
# overlay поверх overlay.
ZYGOTE64_RC_DIR="${R}/system/etc/init/hw"
cp /userdata/init.zygote64.rc "${ZYGOTE64_RC_DIR}/init.zygote64.rc" 2>/dev/null || true
chmod 644 "${ZYGOTE64_RC_DIR}/init.zygote64.rc" 2>/dev/null || true

# Halium vndservicemanager (built from patched Access.cpp - SELinux checks disabled)
mount --bind /userdata/vndservicemanager-halium "${R}/vendor/bin/vndservicemanager" 2>/dev/null || true
mount --bind /userdata/init-halium-nolimits "${R}/system/bin/init" 2>/dev/null || true

# ШАГ 1 (v28, поэтапное восстановление из v25): framework.jar пропатчен
# напрямую -- SystemServiceRegistry.<clinit> без try/catch падает
# NoClassDefFoundError на ПЕРВОМ APEX-only классе в статическом блоке
# (registerService(TETHERING_SERVICE, TetheringManager.class, ...)) -- вся
# верификация класса рвётся, zygote крашится в цикле. framework-patched-
# tethering-fix.jar пропатчен байткодом (try/catch вокруг этого блока) --
# при недоступности TetheringManager просто продолжает регистрацию
# остальных сервисов вместо падения всего zygote. С этим фиксом javalib-
# only tethering classpath mount (было раньше) БОЛЬШЕ НЕ НУЖЕН -- убран.
mount --bind /userdata/framework-patched-teth.jar "${R}/system/framework/framework.jar" 2>/dev/null || true

# НАЙДЕНО 2026-07-12: com.android.phone (TeleService.apk) падал в цикле
# на PhoneGlobals.onCreate -> PhoneFactory.makeDefaultPhones ->
# GsmCdmaPhone.<init> -> DeviceStateMonitor.<init> ->
# ConnectivityManager.registerNetworkCallback() на null объекте (тот же
# класс бага, что весь день чинили в services.jar, но здесь он живёт в
# ОТДЕЛЬНОМ jar'е telephony-common.jar, часть BOOTCLASSPATH). Найдено и
# пропатчено try/catch(Throwable) ещё 8 незащищённых вызовов
# ConnectivityManager в том же jar'е (NetworkFactoryImpl/LegacyImpl --
# ТРЕТЬЯ независимая копия этих классов после services.jar и jarjar'нутой
# wifi-копии, CarrierSignalAgent x2, CellularNetworkValidator,
# LinkBandwidthEstimator, PhoneSwitcher, ImsPhoneCallTracker).
# boot-telephony-common.{oat,art,vdex} уже принудительно удаляются циклом
# выше (ART считает "отсутствует", без пересборки dex2oat) -- просто
# подмена jar'а безопасна.
mount --bind /userdata/telephony-common-patched.jar "${R}/system/framework/telephony-common.jar" 2>/dev/null || true

# НАЙДЕНО 2026-07-11 (продолжение system_server FATAL EXCEPTION):
# SystemServer.java (services.jar) на строке ~2925 делает
# context.getSystemService("connectivity") + check-cast на
# ConnectivityManager СОВЕРШЕННО НЕЗАЩИЩЁННО (без try/catch) -- если
# "connectivity" сервис не зарегистрировался в SystemServiceRegistry
# (наш ЖЕ swallow-патч framework.jar делает это молча, без исключения
# наружу -- см. выше), getSystemService() либо возвращает null (не
# страшно) ЛИБО лениво создавая ConnectivityManager триггерит ТУ ЖЕ
# hard-verification ошибку (NoClassDefFoundError, unresolvable ссылки
# на скрытый com.android.tethering apex), НО уже здесь, БЕЗ защиты --
# ровно вписывается в весь дневной паттерн проекта. Обёрнуто в
# try/catch(Throwable), при провале v6 (ConnectivityManager) = null.

# NetdEventListenerService.<init>(ConnectivityManager) вызывает
# cm.registerNetworkCallback(...) БЕЗ null-проверки -- теперь, когда
# ConnectivityManager реально резолвится (framework-connectivity-built.jar,
# см. ФИКСЫ_ДЛЯ_В30.txt п.18), getSystemService(ConnectivityManager.class)
# возвращает null (сервис "connectivity" не публикуется -- у нас только
# клиентский класс, не реальный ConnectivityService), и вызов метода на
# null валит IpConnectivityMetrics.onBootPhase() -> весь system_server
# фатально (RuntimeException: Failed to boot service ...IpConnectivityMetrics:
# onBootPhase threw an exception during phase 500, Caused by:
# NullPointerException в registerNetworkCallback). Обёрнуто в
# try/catch(Throwable) (baksmali/smali пересобраны из
# external/smali с патчем VersionMap для поддержки dex 040 -- см. п.18/19
# ФИКСЫ_ДЛЯ_В30.txt).

# ЕЩЁ 3 незащищённых вызова на ConnectivityManager (null, т.к. сервис
# "connectivity" не публикуется -- см. предыдущий комментарий):
# NetworkFactoryImpl.registerNetworkProvider() (используется WifiAwareService
# и др.), NetworkFactoryLegacyImpl.register/unregisterNetworkProvider(),
# Vpn.registerNetworkProvider() -- ВСЕ обёрнуты в try/catch(Throwable) по
# той же схеме. (Ещё один unregisterNetworkProvider() в Vpn.smali УЖЕ был
# защищён родным .catchall -- не трогали).
# v3 (2026-07-12): GnssNetworkConnectivityHandler -- ВСЕ 7 мест использования
# mConnMgr (null ConnectivityManager) обёрнуты в try/catch(Throwable):
# registerNetworkCallbacks, 2x unregisterNetworkCallback (handleReleaseSuplConnection,
# handleRequestSuplConnection), handleSuplConnectionAvailable (getNetworkInfo, весь метод),
# setRouting (requestRouteToHostAddress, весь метод), updateTrackedNetworksState
# (getNetworkInfo), isDataNetworkConnected (getActiveNetworkInfo, весь метод).
# Причина патча: system_server падал в крашлупе на registerNetworkCallbacks
# (вызывается из GnssLocationProvider.handleInitialize при старте) -- это
# останавливало респавн zygote64/system_server после нескольких попыток init.
mount --bind /userdata/services-patched-v8.jar "${R}/system/framework/services.jar" 2>/dev/null || true
# v4 (2026-07-12): + NetworkPolicyManagerService.updateNetworkRulesNL()
# (getAllNetworkStateSnapshots) и isUidCurrentlyDisallowedByPolicy() --
# оба тоже падали на null ConnectivityManager, найдены УЖЕ ПОСЛЕ того как
# linkerconfig-фикс (см. ниже) наконец пропустил boot дальше GNSS-стадии.
#
# Telecom.apk (com.android.server.telecom.TelecomSystem.<init>) падал на
# null BluetoothManager.getAdapter() -- BluetoothManager у нас не
# резолвится через getSystemService в этом окружении. Обёрнут в
# try/catch(Throwable), BluetoothDeviceManager получает null adapter
# вместо краша system_server. Патч применён напрямую к classes.dex
# внутри Telecom.apk (META-INF подпись НЕ пересобрана -- живой тест
# покажет, важно ли это для system-partition APK в этом окружении).
mount --bind /userdata/Telecom-patched.apk "${R}/system/priv-app/Telecom/Telecom.apk" 2>/dev/null || true

# НАЙДЕНО 2026-07-11 (иеративно, через отслеживание "Error preloading X"
# по одному): несколько классов в /system/etc/preloaded-classes ФАТАЛЬНО
# роняют весь zygote при попытке принудительной преинициализации на
# старте (в отличие от сотен других классов в этом же списке, чей провал
# преинициализации -- просто WARNING "Class not found for preloading").
# Убираем именно эти -- они всё равно будут лениво загружены при первом
# реальном использовании, просто не на старте zygote. Это дало ПЕРВЫЙ
# ЗА ВСЮ ИСТОРИЮ ПРОЕКТА полностью стабильный zygote (подтверждено
# живым тестом, 30+ секунд без падений, несколько zygote64-процессов
# в USAP pool).
mount --bind /userdata/preloaded-classes-patched "${R}/system/etc/preloaded-classes" 2>/dev/null || true

# BatteryStatsService.noteBluetoothControllerActivity(BluetoothActivityEnergyInfo)
# overrides IBatteryStats -- ART hard-fails verification этого сервиса, если
# BluetoothActivityEnergyInfo/UidTraffic не резолвятся вообще, роняя
# ActivityManagerService и весь system_server. Собственноручно
# скомпилированные из исходников packages/modules/Bluetooth (только
# Parcelable data-классы, реального BT-стека не нужно).
install -D -m 644 /dev/null "${R}/system/framework/framework-bluetooth-stub.jar" 2>/dev/null || true
mount --bind /userdata/framework-bluetooth-stub.jar "${R}/system/framework/framework-bluetooth-stub.jar" 2>/dev/null || true

# android.net.ConnectivityManager (и весь пакет android.net.* из
# packages/modules/Connectivity/framework) физически ОТСУТСТВУЕТ в любом
# jar образа -- модуль Connectivity/Tethering целиком исключён из сборки
# (см. feedback_no_tethering_resolv_apex). ЛЮБОЙ класс, ссылающийся на этот
# тип (например SystemServer.startOtherServices() -- лямбда-параметр в
# lambda$startOtherServices$6), не проходит верификацию ART: "NoClassDefFoundError:
# Class not found using the boot class loader; no stack trace available" --
# ТА САМАЯ ошибка, преследовавшая проект с самого начала (см. ФИКСЫ_ДЛЯ_В30.txt
# п.17). Собран вручную (javac --patch-module java.base=core-for-system-modules.jar
# + d8) из packages/modules/Connectivity/framework/src (только клиентские
# классы, без реального сервиса тетеринга/коннективности -- WifiInfo застаблен
# минимально, реальный BT/Wifi-стек не нужен, только чтобы типы резолвились).
install -D -m 644 /dev/null "${R}/system/framework/framework-connectivity-built.jar" 2>/dev/null || true
mount --bind /userdata/framework-connectivity-built.jar "${R}/system/framework/framework-connectivity-built.jar" 2>/dev/null || true

# JNI-библиотеки для framework-connectivity-built.jar -- static-блоки в
# TrafficStats/NetworkUtils делают System.loadLibrary("framework-connectivity-
# tiramisu-jni")/("framework-connectivity-jni"), без них -- UnsatisfiedLinkError
# при первой попытке system_server реально использовать класс (следующий шаг
# после того как ConnectivityManager стал резолвиться). Собраны тем же
# Soong-таргетом (m libframework-connectivity-tiramisu-jni
# libframework-connectivity-jni), arm64, out/.../lib64/*.so.
install -D -m 644 /dev/null "${R}/system/lib64/libframework-connectivity-tiramisu-jni.so" 2>/dev/null || true
mount --bind /userdata/libframework-connectivity-tiramisu-jni.so "${R}/system/lib64/libframework-connectivity-tiramisu-jni.so" 2>/dev/null || true
install -D -m 644 /dev/null "${R}/system/lib64/libframework-connectivity-jni.so" 2>/dev/null || true
mount --bind /userdata/libframework-connectivity-jni.so "${R}/system/lib64/libframework-connectivity-jni.so" 2>/dev/null || true

# Так как framework.jar пропатчен (изменился dex checksum), штатный
# /system/framework/arm64/boot-framework.oat/.art/.vdex больше не совпадает --
# ART пытается фоново перекомпилировать через dex2oat, но это не успевает до
# health-check init'а (>4 "падения" = убивает весь zygote process group).
# -Xnoimage-dex2oat отключает эту попытку регенерации целиком (интерпретатор/
# JIT без boot image, медленнее холодный старт, зато не крашится). Теперь
# флаг уже встроен прямо в /userdata/init.zygote64.rc (см. выше в этом
# файле) -- runtime sed больше не нужен.

# Остальные boot-image extension'ы (компилируются ПОСЛЕ framework.jar в
# BOOTCLASSPATH) тоже мисматчатся -- дальше без dex2oat они бы остались в
# "present but invalid" состоянии, что ART трактует как permanently
# unresolvable. Удаление (не просто оставление мисматча) заставляет ART
# считать их отсутствующими -- fallback на чтение dex напрямую, без попытки
# перекомпиляции и без краша.
for f in boot-ext boot-framework-graphics boot-telephony-common \
         boot-voip-common boot-ims-common boot-core-icu4j; do
    rm -f "${R}/system/framework/arm64/${f}.oat" \
          "${R}/system/framework/arm64/${f}.art" \
          "${R}/system/framework/arm64/${f}.vdex"
done

# НАЙДЕНО 2026-07-11 (продолжение расследования system_server FATAL
# EXCEPTION): services.jar и org.lineageos.platform.jar датированы
# позже остальных файлов ROM'а (2026-07-09 против 2026-06-20) -- у них
# ЕСТЬ собственные precompiled services.odex/.art/.vdex и
# org.lineageos.platform.odex/.vdex (НЕ часть boot-image extension
# chain, отдельный per-jar ODEX механизм для SystemServerClasspath).
# ВАЖНО: живой тест показал что "rm -f" здесь (в отличие от boot-ext
# выше) НЕ persist'ится в финальный контейнер -- та же аномалия что и
# с /linkerconfig (команда успешно выполняется в staging chroot по
# mount-hook.log, но файл остаётся нетронутым после полного старта
# контейнера). ИСПОЛЬЗУЕМ ПРОВЕРЕННЫЙ bind-mount-пустого-файла паттерн
# (как boot-framework.* ниже) вместо rm -f -- этот механизм НАДЁЖНО
# persist'ится.
for f in services.odex services.art services.vdex \
         org.lineageos.platform.odex org.lineageos.platform.vdex; do
    DST="${R}/system/framework/oat/arm64/${f}"
    if [ -f "$DST" ]; then
        install -D -m 644 /dev/null /run/halium-empty-${f} 2>/dev/null || true
        mount --bind /run/halium-empty-${f} "$DST" 2>/dev/null || true
    fi
done

# ДИАГНОСТИЧЕСКИЙ ТЕСТ (2026-07-11) -- ПРОВЕРЕНО И ОПРОВЕРГНУТО: пустой
# org.lineageos.platform.jar даёт ИДЕНТИЧНЫЙ краш (тот же
# NoClassDefFoundError, тот же тайминг) -- значит содержимое ЭТОГО
# файла НЕ является причиной. Тест снят, реальный файл больше не
# перекрываем.

# НАЙДЕНО 2026-07-12: та же болезнь, что у services.odex/org.lineageos.
# platform.odex выше, но для STANDALONE_SYSTEM_SERVER_JARS/APEX --
# logcat поймал прямо перед NoClassDefFoundError:
#   "Dex checksum does not match for dex:
#    /apex/com.android.wifi/javalib/service-wifi.jar.
#    Expected: 43698138, actual: 4095439243"
# service-wifi.jar на устройстве -- уже пропатченная (в25-производная,
# md5 совпадает с в25-шным service-wifi-fixed.jar) версия, а
# precompiled odex/vdex под неё остались от СТАРОГО (стокового)
# service-wifi.jar -- отсюда checksum mismatch. Файлы имеют другое
# именование (apex@.../classes.odex, не просто service-wifi.odex) --
# найдены через find / -iname "service-wifi*":
#   /system/framework/oat/arm64/apex@com.android.wifi@javalib@service-wifi.jar@classes.odex
#   /system/framework/oat/arm64/apex@com.android.wifi@javalib@service-wifi.jar@classes.vdex
# Тот же проверенный bind-mount-пустого-файла паттерн.
for f in "apex@com.android.wifi@javalib@service-wifi.jar@classes.odex" \
         "apex@com.android.wifi@javalib@service-wifi.jar@classes.vdex"; do
    DST="${R}/system/framework/oat/arm64/${f}"
    if [ -f "$DST" ]; then
        install -D -m 644 /dev/null "/run/halium-empty-servicewifi-$(basename "$f")" 2>/dev/null || true
        mount --bind "/run/halium-empty-servicewifi-$(basename "$f")" "$DST" 2>/dev/null || true
    fi
done

# boot-framework.{art,vdex,oat} для arm64 -- реально скомпилированы офлайн
# (dex2oat64 --compiler-filter=verify) против ЭТОГО ЖЕ пропатченного
# framework.jar. Бинд-моунт read-only не даёт zygote'у удалить/перезаписать
# файл при своей собственной попытке regen (EROFS/EBUSY -> no-op).
mkdir -p "${R}/system/framework/arm64" 2>/dev/null
for f in boot-framework.art boot-framework.vdex boot-framework.oat; do
    SRC="/userdata/bootext/${f}"
    DST="${R}/system/framework/arm64/${f}"
    if [ -f "$SRC" ]; then
        install -D -m 644 /dev/null "$DST" 2>/dev/null || true
        mount --bind "$SRC" "$DST" 2>/dev/null || true
        mount -o remount,ro,bind "$DST" 2>/dev/null || true
    fi
done
# 32-битный компаньон (.art/.oat, .vdex общий с arm64 через симлинк) --
# boot.art требует ВСЕ заявленные ISA-компоненты присутствующими и
# согласованными, просто отсутствие (как для boot-ext/etc extensions выше)
# тут не работает.
for f in boot-framework.art boot-framework.oat; do
    SRC="/userdata/bootext_arm32/${f}"
    DST="${R}/system/framework/arm/${f}"
    if [ -f "$SRC" ] && [ -f "$DST" ]; then
        install -D -m 644 /dev/null "$DST" 2>/dev/null || true
        mount --bind "$SRC" "$DST" 2>/dev/null || true
        mount -o remount,ro,bind "$DST" 2>/dev/null || true
    fi
done
# firmware_mnt (sda23, vfat) содержит a660_zap.mdt/.b00-.b02 (реальный zap shader
# от Samsung!), но это ОТДЕЛЬНАЯ партиция от /dev/mapper/vendor и не монтируется
# автоматически внутрь contейнерного /vendor (наш Halium mount_all — фейковый).
mkdir -p "${R}/vendor/firmware_mnt" 2>/dev/null || true
mount -t vfat -o ro /dev/sda23 "${R}/vendor/firmware_mnt" 2>/dev/null || true

# НАЙДЕНО 2026-07-28 (в3): ядро ищет a660_zap.mdt строго по пути
# ${R}/vendor/firmware/a660_zap.mdt (прямой request_firmware lookup, без
# sysfs fallback для этого драйвера) -- монтирование firmware_mnt выше
# делает файл видимым только по ${R}/vendor/firmware_mnt/image/, что не
# совпадает с путём поиска. Копируем реальные байты zap-шейдера поверх
# ${R}/vendor/firmware через tmpfs bind-mount (не overlay -- overlay на
# vfat-lowerdir без xattr/SELinux меток раньше вызывал EACCES и хуже).
mkdir -p /tmp/halium-firmware-staging 2>/dev/null || true
mount -t tmpfs firmware-staging /tmp/halium-firmware-staging 2>/dev/null || true
cp -a "${R}/vendor/firmware/." /tmp/halium-firmware-staging/ 2>/dev/null || true
for zf in a660_zap.mdt a660_zap.b00 a660_zap.b01 a660_zap.b02; do
    cp "${R}/vendor/firmware_mnt/image/${zf}" /tmp/halium-firmware-staging/ 2>/dev/null || true
    chmod 644 "/tmp/halium-firmware-staging/${zf}" 2>/dev/null || true
done
mount --bind /tmp/halium-firmware-staging "${R}/vendor/firmware" 2>/dev/null || true

# Дополнительный путь прямого поиска ядра ("/firmware/image/a660_zap.mdt",
# третий из трёх путей, которые пробует request_firmware до sysfs-fallback) --
# заполняем и его теми же файлами, чтобы прямой lookup имел больше шансов
# отработать без гонки на sysfs-fallback (a660_zap.b02 стабильно проигрывал
# эту гонку -- ENODEV на sendfile, см. peripheral-loader.c request_firmware_into_buf).
mkdir -p "${R}/firmware/image" 2>/dev/null || true
for zf in a660_zap.mdt a660_zap.b00 a660_zap.b01 a660_zap.b02; do
    cp "${R}/vendor/firmware_mnt/image/${zf}" "${R}/firmware/image/" 2>/dev/null || true
    chmod 644 "${R}/firmware/image/${zf}" 2>/dev/null || true
done

# НАЙДЕНО 2026-07-28 (в3): контейнерный surfaceflinger -- собственный
# composer3-клиент Android -- конкурирует за GPU/composer HAL с host-side
# компоситором (то же самое противостояние, из-за которого существует
# halium-bounce-composer.sh, только ТАМ оно решается ПОСЛЕ загрузки
# контейнера остановкой через ctl.stop; здесь же контейнерный
# surfaceflinger падает НА a660_zap.b02 ЕЩЁ ДО того как bounce-composer
# успевает сработать, роняя всю систему через hardware watchdog).
# surfaceflinger хосту не нужен вообще (host-компоситор рендерит напрямую
# через hwcomposer HAL) -- глушим его ТОЛЬКО внутри контейнера
# (bind-mount, не трогая тот же физический файл в baseline/system.img,
# который сейчас стабильно работает без изменений) тем же паттерном,
# что audioserver_HYBRIS_DISABLED/cameraserver_HYBRIS_DISABLED в этом же
# init.rc -- заменяем на no-op шелл-скрипт.
# НАЙДЕНО 2026-07-29: `exit 0` сразу -- ПЛОХАЯ идея. surfaceflinger.rc
# содержит "onrestart restart --only-if-running zygote" -- КАЖДЫЙ раз,
# когда наш скрипт немедленно завершается, init видит это как
# "surfaceflinger перезапустился" и НАМЕРЕННО каскадно убивает/
# перезапускает zygote вместе с ним (штатное поведение AOSP: surfaceflinger
# и zygote тесно связаны). Это держало zygote в вечном цикле рестарта
# каждые ~5с, даже после того как все остальные баги (BOOTCLASSPATH,
# build.prop, com_android_art, LongScreen) были исправлены. Меняем на
# "спать вечно" вместо "выйти сразу" -- init видит процесс как реально
# запущенный/стабильный, restart-каскад на zygote никогда не срабатывает,
# GPU/zap всё ещё не трогается (просто sleep, не настоящий surfaceflinger).
mkdir -p /tmp/halium-noop-staging 2>/dev/null || true
mount -t tmpfs noop-staging /tmp/halium-noop-staging 2>/dev/null || true
printf '#!/system/bin/sh\nwhile true; do sleep 3600; done\n' > /tmp/halium-noop-staging/surfaceflinger-noop
chmod 755 /tmp/halium-noop-staging/surfaceflinger-noop
if [ -f "${R}/system/bin/surfaceflinger" ]; then
    mount --bind /tmp/halium-noop-staging/surfaceflinger-noop "${R}/system/bin/surfaceflinger" 2>/dev/null || true
fi

# НАЙДЕНО 2026-07-13: тот же класс бага, что firmware_mnt/wpss выше --
# /dev/block/by-name/modem (sda18, vfat) содержит ПОЛНУЮ прошивку модема
# (image/modem.mdt + image/modem.b00-.bNN, ~30+ сегментов) -- она РЕАЛЬНО
# ЕСТЬ на устройстве, просто никогда не монтируется в контейнер. Штатно
# (см. /vendor/etc/fstab.qcom) должна монтироваться в /vendor/firmware-modem
# -- именно этот путь subsys-pil-tz ищет и не находит ("Failed to locate
# modem.mdt(rc:-2)", "pil_boot failed for modem" -- subsys3 навсегда
# OFFLINING). Это ПОСЛЕДНЕЕ звено цепочки: modem-PIL-драйвер включён в
# ядре (CONFIG_MSM_PIL_MSS_QDSP6V5=y, см. defconfig-фикс) + rmtfs/tqftpserv
# подняты (см. halium-extras) -- не хватало только реального файла
# прошивки на ожидаемом пути.
mkdir -p "${R}/vendor/firmware-modem" 2>/dev/null || true
mount -t vfat -o ro /dev/sda18 "${R}/vendor/firmware-modem" 2>/dev/null || true
# wpss rev7 firmware (m526br, bootloader rev7) from TheMuppets vendor blob repo
for wf in wpss.b00 wpss.b01 wpss.b02 wpss.b03 wpss.b04 wpss.b05 wpss.b06 wpss.b07 wpss.mdt; do
    mount --bind "/userdata/wpss-rev7/${wf}" "${R}/vendor/firmware/${wf}" 2>/dev/null || true
done
mount -t ext4 -o ro /dev/mapper/product "${R}/product" 2>/dev/null || true

# НАЙДЕНО 2026-07-19: /system/etc/cgroups.json требует legacy cgroup v1
# controller-specific точки монтирования (/dev/cpuset, /dev/cpuctl,
# /dev/blkio, /dev/memcg) -- unified cgroup2 (/sys/fs/cgroup, добавлен в
# lxc-конфиг Находка 18) используется в ЭТОМ конфиге ТОЛЬКО для freezer.
# Хост уже полностью на cgroup2 (systemd сам использует cpuset/cpu/memory
# там же) -- параллельно смонтировать v1-иерархию для тех же контроллеров
# невозможно (ядро не даёт одному контроллеру одновременно жить в v1 и
# v2). Вместо попытки построить настоящую v1-иерархию просто убираем
# требование целиком -- urезанный cgroups.json без "Cgroups" (v1) секции,
# оставляя только freezer/cgroup2. Постоянные "cpuset cgroup controller
# is not mounted!" / "Controller cpuset is not found" пропадают, zygote
# перестаёт спотыкаться на task_profiles setup. См.
# DROIDIAN-V2-SYSTEMD-FIX-HOWTO.md Находка 18.
CGROUPS_JSON="${R}/system/etc/cgroups.json"
if [ -f "$CGROUPS_JSON" ]; then
    mount --bind /userdata/cgroups-minimal.json "$CGROUPS_JSON" 2>/dev/null || true
fi

APEX_MOUNT="${R}/apex"
APEX_SRC="${R}/system/apex"

mount -t tmpfs android_apex "${APEX_MOUNT}" 2>/dev/null || true

# ОТКАЧЕНО ЖИВЬЁМ 2026-07-19 (после реального теста на устройстве):
# полное размаскирование com.android.tethering/resolv ПОДТВЕРЖДЁННО
# (живым тестом, 3-й раз считая 2026-07-13 x2) роняет SSH -- netd,
# получив реальные offload BPF-программы из
# /apex/com.android.tethering/etc/bpf/, переконфигурирует usb0. НО
# полностью пустая маскировка (как было ДО этого) ломает ДРУГОЕ:
# apexd-bootstrap прерывает ВЕСЬ скан "/system/apex" на первой же
# ENOENT (Находка 21) -- без активации runtime/art/i18n/vndk.current
# ничего не работает вообще. Средний вариант: source-каталог
# по-прежнему маскируем пустым tmpfs (никакого реального lib64/etc/bpf
# контента), но кладём ТУДА ЖЕ настоящий apex_manifest.pb (снят живьём
# с партиции) -- apexd's access()-проверка проходит, скан НЕ
# прерывается, но активировать tethering/resolv ему нечем (директория
# пустая кроме manifest) -- netd не получает offload BPF, SSH не рвётся.
for MASK_NAME in tethering resolv; do
    MASK_DIR="${APEX_SRC}/com.android.${MASK_NAME}"
    mkdir -p "$MASK_DIR" 2>/dev/null || true
    mount -t tmpfs "android_apex_src_${MASK_NAME}_hide" "$MASK_DIR" 2>/dev/null || true
    mount --bind "/userdata/apex-${MASK_NAME}-manifest.pb" "${MASK_DIR}/apex_manifest.pb" 2>/dev/null || true
done

for apex_name in com.android.runtime com.android.art com.android.i18n com.android.media com.android.wifi com.android.os.statsd com.android.sdkext com.android.adbd com.android.conscrypt com.android.extservices com.android.btservices com.android.ipsec com.android.adservices com.android.appsearch com.android.mediaprovider com.android.ondevicepersonalization com.android.permission com.android.scheduling com.android.uwb; do
    if [ -d "${APEX_SRC}/${apex_name}" ]; then
        mkdir -p "${APEX_MOUNT}/${apex_name}"
        mount -o bind "${APEX_SRC}/${apex_name}" "${APEX_MOUNT}/${apex_name}" 2>/dev/null || true
    fi
done

# ШАГ 2b (v28, восстановление из v25, без всего что касается tethering):
mount --bind /userdata/NetworkStack-fixed.apk "${R}/system/priv-app/NetworkStack/NetworkStack.apk" 2>/dev/null || true
# SystemUI.apk: DisplayLayout.set() кидал NPE на null-аргументе (source
# display layout отсутствует в нашем headless окружении), что валило
# КАЖДЫЙ новый процесс через CustomizationProvider.attachInfo() ->
# SystemUIInitializer.init() -> ... -> DisplayLayout.<init>() -- system_server
# уходил в непрерывный краш-цикл. Пропатчен null-check в начале set()
# (classes.dex, baksmali/smali -a 33), см. ФИКСЫ_ДЛЯ_В32.txt п.5.
if [ -f /userdata/SystemUI-patched.apk ]; then
    mount --bind /userdata/SystemUI-patched.apk "${R}/system/system_ext/priv-app/SystemUI/SystemUI.apk" 2>/dev/null || true
fi
# НАЙДЕНО 2026-07-19 (Находка 34): LineageSettings$NameValueCache.
# getStringForUser() не null-проверяет IContentProvider (получаемый
# через ContentProviderHolder.getProvider()), прежде чем вызывать
# .call()/.query() на нём -- если провайдер "lineagesettings" ещё не
# доступен (user 0 не разблокирован), сразу NullPointerException.
# LongScreen$SettingsObserver.update() (device-specific LineageOS
# фича "длинного экрана" для m52xq) дёргает LineageSettings ОЧЕНЬ
# рано, при ActivityTaskManagerService.installSystemProviders() ->
# LineageActivityManager.<init>() -- крашит ВЕСЬ system_server.
# Пропатчен null-check сразу после getProvider() (classes.dex внутри
# org.lineageos.platform.jar, baksmali/smali -a 33) -- при null
# провайдере просто возвращает null вместо краша, как и должно быть.
if [ -f /userdata/org.lineageos.platform-patched.jar ]; then
    mount --bind /userdata/org.lineageos.platform-patched.jar "${R}/system/framework/org.lineageos.platform.jar" 2>/dev/null || true
fi
# НАЙДЕНО 2026-07-19 (Находка 35, окончательный фикс): даже с
# отключённым vendor.sensors-hal-multihal сервисом
# SensorService.onBootPhase() (services.jar, classes2.dex) ВСЁ РАВНО
# блокирует ГЛАВНЫЙ ПОТОК system_server навсегда через
# ConcurrentUtils.waitForFutureNoInterrupt(mSensorServiceStart, ...) --
# подтверждено многократными ANR (Subject: Blocked in handler on main
# thread) и периодическим watchdog-рестартом ВСЕГО контейнера каждые
# ~90-100с (два живых теста по 240с, ни разу sys.boot_completed).
# Убран сам блокирующий вызов из onBootPhase() (baksmali/smali -a 33,
# результат вызова всё равно не использовался) -- реальная поддержка
# сенсоров для m52xq всё ещё требует отдельной работы на уровне
# ADSP-драйвера ядра (см. предыдущий фикс), но теперь их отсутствие
# больше не блокирует остальную загрузку.
if [ -f /userdata/services-patched.jar ]; then
    mount --bind /userdata/services-patched.jar "${R}/system/framework/services.jar" 2>/dev/null || true
fi
# НАЙДЕНО 2026-07-20 (Находка 42): android.provider.Settings$NameValueCache
# ->getProvider() может вернуть null, если ContentProvider (SettingsProvider)
# ещё не готов на момент вызова -- гонка при загрузке, persistent-процессы
# вроде com.android.phone стартуют раньше готовности провайдера. Без
# null-check это NPE валит вызывающее приложение (FATAL EXCEPTION: main),
# и персистентный процесс никогда не стабилизируется, что мешает
# sys.boot_completed. framework-patched.jar = framework-patched-teth.jar
# (Находка от 2026-07-12, TetheringManager try/catch) + этот null-check
# в classes3.dex -- ОБА фикса нужны, framework-patched.jar собран поверх
# framework-patched-teth.jar, а не поверх чистого оригинала.
if [ -f /userdata/framework-patched.jar ]; then
    mount --bind /userdata/framework-patched.jar "${R}/system/framework/framework.jar" 2>/dev/null || true
fi
mount --bind /userdata/libgui-v7.so "${R}/system/lib64/libgui.so" 2>/dev/null || true
mount --bind /userdata/libandroid_runtime-v1.so "${R}/system/lib64/libandroid_runtime.so" 2>/dev/null || true
# netd не мог даже слинковаться (CANNOT LINK EXECUTABLE ... library
# "libnetd_updatable.so" not found) -- обе либы обычно живут в APEX
# com.android.tethering/resolv, но т.к. эти APEX у нас не в системе.img
# контейнера, кладём их напрямую в system/lib64 (снято живьём с реального
# устройства 2026-07-13: /android/system/system/apex/com.android.tethering/
# lib64/libnetd_updatable.so и .../com.android.resolv/lib64/libnetd_resolv.so).
install -D -m 644 /dev/null "${R}/system/lib64/libnetd_updatable.so" 2>/dev/null || true
install -D -m 644 /dev/null "${R}/system/lib64/libnetd_resolv.so" 2>/dev/null || true
mount --bind /userdata/libnetd_updatable.so "${R}/system/lib64/libnetd_updatable.so" 2>/dev/null || true
mount --bind /userdata/libnetd_resolv.so "${R}/system/lib64/libnetd_resolv.so" 2>/dev/null || true
chmod 644 "${R}/system/lib64/libnetd_updatable.so" "${R}/system/lib64/libnetd_resolv.so" 2>/dev/null || true

# НАЙДЕНО 2026-07-19 (Находка 35, продолжение): найден ИСТИННЫЙ корень
# зависания boot_completed -- НЕ краш, а ВЕЧНОЕ ожидание.
# SensorService.onBootPhase() (com.android.server.sensors.SensorService.
# java:78) синхронно блокирует ГЛАВНЫЙ ПОТОК system_server через
# FutureTask.get() в ожидании инициализации sensors HAL -- а vendor HAL
# бинарь (android.hardware.sensors-service.samsung-multihal) никогда не
# может стартовать: "CANNOT LINK EXECUTABLE ... library
# android.hardware.sensors-V1-ndk.so not found: needed by main
# executable". Библиотека РЕАЛЬНО существует внутри
# com.android.vndk.current APEX, но vendor-неймспейс её не видит.
# Кладём копию напрямую в /vendor/lib64 (тот же паттерн, что уже
# использовался для libnetd_updatable.so) -- подтверждено живым ANR-
# дампом (/data/anr/anr_*), стек главного потока system_server
# буквально указывает на этот вызов.
install -D -m 644 /dev/null "${R}/vendor/lib64/android.hardware.sensors-V1-ndk.so" 2>/dev/null || true
mount --bind /userdata/android.hardware.sensors-V1-ndk.so "${R}/vendor/lib64/android.hardware.sensors-V1-ndk.so" 2>/dev/null || true
chmod 644 "${R}/vendor/lib64/android.hardware.sensors-V1-ndk.so" 2>/dev/null || true
# (libnativeloader.so fix -- см. Находка 20 -- перемещён МНОГО РАНЬШЕ в
# этом скрипте, сразу после SELINUX_PATH stub-блока, т.к. запись сюда,
# в этой точке скрипта, молча проваливалась каждый раз.)
if [ -f /userdata/service-wifi-fixed.jar ] && [ -d "${APEX_MOUNT}/com.android.wifi/javalib" ]; then
    mount -o bind /userdata/service-wifi-fixed.jar "${APEX_MOUNT}/com.android.wifi/javalib/service-wifi.jar" 2>/dev/null || true
fi


# ИСПРАВЛЕНО (перенесено из v25, 2026-07-07): раньше VNDK бинд делался ПОСЛЕ
# linkerconfig, из предположения что VNDK крашит linkerconfig -- оказалось
# ложным (реальная причина того давнего краша была банальным отсутствием
# mkdir целевой директории, не связана с VNDK вообще). Без VNDK на момент
# вызова linkerconfig генерирует УПРОЩЁННЫЙ конфиг без под-неймспейсов на
# каждый APEX -- вероятная причина "no namespace called com_android_art".
if [ -d "${APEX_SRC}/com.android.vndk.current" ]; then
    mkdir -p "${APEX_MOUNT}/com.android.vndk.current" "${APEX_MOUNT}/com.android.vndk.v33"
    mount -o bind "${APEX_SRC}/com.android.vndk.current" "${APEX_MOUNT}/com.android.vndk.current" 2>/dev/null || true
    mount -o bind "${APEX_SRC}/com.android.vndk.current" "${APEX_MOUNT}/com.android.vndk.v33" 2>/dev/null || true
fi

# НАЙДЕНО 2026-07-11 (объясняет "случайно не применяется" баг фикса
# visible=true ниже): подтверждено живым логом, что sed ВСЕГДА успешно
# применяется ВНУТРИ самого выполнения mount.sh (staging chroot,
# ${R}=/usr/lib/aarch64-linux-gnu/lxc) -- но когда LXC переходит в
# ФИНАЛЬНЫЙ mount namespace запущенного контейнера, отдельный tmpfs,
# который мы создавали здесь ("mount -t tmpfs android_linkerconfig"),
# НЕ переносится туда надёжно (в отличие от bind-mount'ов ОТДЕЛЬНЫХ
# ФАЙЛОВ типа framework.jar, которые переносятся 100% надёжно каждый
# раз -- разница в том, что tmpfs это НОВАЯ независимая точка монтирования
# вне управления LXC, а bind file -- просто VFS-подмена внутри уже
# существующего дерева). УБРАН весь tmpfs для /linkerconfig -- пусть
# linkerconfig пишет прямо в РЕАЛЬНЫЙ путь на staging-rootfs (уже
# писабельный через self-referential overlay pre-start.sh, та же
# причина по которой framework.jar bind работает).

# apexd никогда по-настоящему не запускается в этом проекте (вместо него —
# ручные bind mount'ы APEX выше), а именно apexd в реальном Android после
# активации APEX вызывает ПОЛНЫЙ linkerconfig (не тот ранний "bootstrap" из
# init.rc). Без этого /linkerconfig/default навсегда остаётся на bootstrap-
# конфиге, который не знает про библиотеки ART APEX (libnativeloader.so и
# т.д.) -> zygote падает на линковке при КАЖДОМ старте, без сигнала в kernel
# log (найдено 2026-07-06 через chroot-симуляцию в TWRP). Генерируем
# apex-info-list.xml сами и прогоняем настоящий linkerconfig прямо здесь.
cat > "${APEX_MOUNT}/apex-info-list.xml" <<XMLEOF
<?xml version="1.0" encoding="utf-8"?>
<apex-info-list>
  <apex-info moduleName="com.android.runtime" modulePath="/system/apex/com.android.runtime" preinstalledModulePath="/system/apex/com.android.runtime" versionCode="1" versionName="1" isFactory="true" isActive="true" provideSharedApexLibs="false"/>
  <apex-info moduleName="com.android.art" modulePath="/system/apex/com.android.art" preinstalledModulePath="/system/apex/com.android.art" versionCode="1" versionName="1" isFactory="true" isActive="true" provideSharedApexLibs="true"/>
  <apex-info moduleName="com.android.i18n" modulePath="/system/apex/com.android.i18n" preinstalledModulePath="/system/apex/com.android.i18n" versionCode="1" versionName="1" isFactory="true" isActive="true" provideSharedApexLibs="false"/>
  <apex-info moduleName="com.android.media" modulePath="/system/apex/com.android.media" preinstalledModulePath="/system/apex/com.android.media" versionCode="1" versionName="1" isFactory="true" isActive="true" provideSharedApexLibs="false"/>
  <apex-info moduleName="com.android.wifi" modulePath="/system/apex/com.android.wifi" preinstalledModulePath="/system/apex/com.android.wifi" versionCode="1" versionName="1" isFactory="true" isActive="true" provideSharedApexLibs="false"/>
  <apex-info moduleName="com.android.os.statsd" modulePath="/system/apex/com.android.os.statsd" preinstalledModulePath="/system/apex/com.android.os.statsd" versionCode="1" versionName="1" isFactory="true" isActive="true" provideSharedApexLibs="false"/>
  <apex-info moduleName="com.android.sdkext" modulePath="/system/apex/com.android.sdkext" preinstalledModulePath="/system/apex/com.android.sdkext" versionCode="1" versionName="1" isFactory="true" isActive="true" provideSharedApexLibs="false"/>
  <apex-info moduleName="com.android.adbd" modulePath="/system/apex/com.android.adbd" preinstalledModulePath="/system/apex/com.android.adbd" versionCode="1" versionName="1" isFactory="true" isActive="true" provideSharedApexLibs="false"/>
  <apex-info moduleName="com.android.conscrypt" modulePath="/system/apex/com.android.conscrypt" preinstalledModulePath="/system/apex/com.android.conscrypt" versionCode="1" versionName="1" isFactory="true" isActive="true" provideSharedApexLibs="false"/>
  <apex-info moduleName="com.android.extservices" modulePath="/system/apex/com.android.extservices" preinstalledModulePath="/system/apex/com.android.extservices" versionCode="1" versionName="1" isFactory="true" isActive="true" provideSharedApexLibs="false"/>
  <apex-info moduleName="com.android.btservices" modulePath="/system/apex/com.android.btservices" preinstalledModulePath="/system/apex/com.android.btservices" versionCode="1" versionName="1" isFactory="true" isActive="true" provideSharedApexLibs="false"/>
  <apex-info moduleName="com.android.vndk.v33" modulePath="/system/apex/com.android.vndk.current" preinstalledModulePath="/system/apex/com.android.vndk.current" versionCode="1" versionName="1" isFactory="true" isActive="true" provideSharedApexLibs="false"/>
  <apex-info moduleName="com.android.ipsec" modulePath="/system/apex/com.android.ipsec" preinstalledModulePath="/system/apex/com.android.ipsec" versionCode="1" versionName="1" isFactory="true" isActive="true" provideSharedApexLibs="false"/>
  <apex-info moduleName="com.android.adservices" modulePath="/system/apex/com.android.adservices" preinstalledModulePath="/system/apex/com.android.adservices" versionCode="1" versionName="1" isFactory="true" isActive="true" provideSharedApexLibs="false"/>
  <apex-info moduleName="com.android.appsearch" modulePath="/system/apex/com.android.appsearch" preinstalledModulePath="/system/apex/com.android.appsearch" versionCode="1" versionName="1" isFactory="true" isActive="true" provideSharedApexLibs="false"/>
  <apex-info moduleName="com.android.mediaprovider" modulePath="/system/apex/com.android.mediaprovider" preinstalledModulePath="/system/apex/com.android.mediaprovider" versionCode="1" versionName="1" isFactory="true" isActive="true" provideSharedApexLibs="false"/>
  <apex-info moduleName="com.android.ondevicepersonalization" modulePath="/system/apex/com.android.ondevicepersonalization" preinstalledModulePath="/system/apex/com.android.ondevicepersonalization" versionCode="1" versionName="1" isFactory="true" isActive="true" provideSharedApexLibs="false"/>
  <apex-info moduleName="com.android.permission" modulePath="/system/apex/com.android.permission" preinstalledModulePath="/system/apex/com.android.permission" versionCode="1" versionName="1" isFactory="true" isActive="true" provideSharedApexLibs="false"/>
  <apex-info moduleName="com.android.scheduling" modulePath="/system/apex/com.android.scheduling" preinstalledModulePath="/system/apex/com.android.scheduling" versionCode="1" versionName="1" isFactory="true" isActive="true" provideSharedApexLibs="false"/>
  <apex-info moduleName="com.android.uwb" modulePath="/system/apex/com.android.uwb" preinstalledModulePath="/system/apex/com.android.uwb" versionCode="1" versionName="1" isFactory="true" isActive="true" provideSharedApexLibs="false"/>
</apex-info-list>
XMLEOF
# Зовём напрямую бинарь через НАШ ЖЕ bind mount APEX выше
# (${APEX_MOUNT}/com.android.runtime/bin/linkerconfig), а не через
# /system/bin/... или /system/system/bin/... -- оба этих пути на staging-
# точке (где выполняется сам mount.sh, ДО pivot_root) на практике не
# резолвятся (проверено 2026-07-06 живыми перезагрузками: "No such file or
# directory" для обоих). Наш собственный apex-bind гарантированно существует,
# т.к. мы его только что сами примонтировали циклом выше.
ls -la "${APEX_MOUNT}/com.android.runtime/bin/linkerconfig" 2>&1
chroot "${R}" /apex/com.android.runtime/bin/linkerconfig --target /linkerconfig 2>&1
chmod 644 "${R}/linkerconfig/ld.config.txt" 2>/dev/null || true
rm -f "${APEX_MOUNT}/apex-info-list.xml"

# КРИТИЧЕСКИЙ ФИКС (2026-07-11, найдено через strace+AOSP source diving):
# настоящий /apex/com.android.art/etc/linker.config.pb (штатный, не наш) НЕ
# ставит поле visible=true -- поэтому linkerconfig создаёт namespace
# com_android_art (со всеми search/permitted paths и links), но НЕ помечает
# его "visible", а именно через android_get_exported_namespace("com_android_art")
# (вызывается из libnativeloader.so::OpenNativeLibrary при
# art::Runtime::InitNativeMethods()) ART ищет этот namespace в САМОМ начале
# жизни zygote -- находит "не экспортирован" и падает Runtime::Abort()
# "no namespace called com_android_art" (SIGABRT, до всякого Java-кода).
# На настоящих устройствах это, видимо, резолвится другим путём (namespace
# вызывающей библиотеки, а не exported-lookup) -- у нас этот путь почему-то
# не срабатывает (вероятно из-за того что apexd никогда по-настоящему не
# активирует com.android.art). Форсируем visible=true вручную во ВСЕХ
# секциях, где встречается namespace.com_android_art -- подтверждено живым
# тестом: "no namespace called com_android_art" полностью исчезает.
# НАЙДЕНО 2026-07-11: даже правильный порядок (tmpfs ДО генерации, sed
# ПОСЛЕ) не гарантирует применение -- живьём подтверждено, что sed иногда
# всё равно "не держится" по неясной причине (возможно staging-неймспейс
# mount.sh расходится с финальным неймспейсом контейнера именно для этого
# пути). Не полагаемся на однократное исполнение -- проверяем результат и
# повторяем при необходимости (до 10 попыток, короткие паузы).
{
    echo "DEBUG visfix: ld.config.txt exists = $([ -f "${R}/linkerconfig/ld.config.txt" ] && echo YES || echo NO)"
    echo "DEBUG visfix: ld.config.txt size = $(wc -c < "${R}/linkerconfig/ld.config.txt" 2>/dev/null)"
    echo "DEBUG visfix: isolated-line matches = $(grep -c '^namespace\.com_android_art\.isolated = true$' "${R}/linkerconfig/ld.config.txt" 2>/dev/null)"
} >> /userdata/mount-sh-debug.log 2>&1
VISFIX_TRIES=0
while [ "$VISFIX_TRIES" -lt 10 ]; do
    sed -i "s/^namespace\.com_android_art\.isolated = true\$/namespace.com_android_art.isolated = true\nnamespace.com_android_art.visible = true/" "${R}/linkerconfig/ld.config.txt" 2>/dev/null || true
    if grep -q "^namespace\.com_android_art\.visible = true\$" "${R}/linkerconfig/ld.config.txt" 2>/dev/null; then
        break
    fi
    VISFIX_TRIES=$((VISFIX_TRIES + 1))
    sleep 0.2
done
echo "visfix tries used: ${VISFIX_TRIES}, result: $(grep -c 'com_android_art.visible' "${R}/linkerconfig/ld.config.txt" 2>/dev/null)" >> /userdata/mount-sh-debug.log 2>&1

# НАЙДЕНО 2026-07-12: "onrestart update_linker_config" в init.zygote64.rc
# (добавлен ранее для фикса гонки на самом первом старте zygote) на КАЖДЫЙ
# последующий краш zygote (по ЛЮБОЙ причине) заново гоняет реальный
# linkerconfig-бинарь БЕЗ повторного применения visible=true фикса выше
# (тот sed выполняется здесь, в mount.sh, ТОЛЬКО ОДИН РАЗ при старте
# контейнера) -- каждый onrestart-регенерированный ld.config.txt снова
# теряет visible=true и УБИВАЕТ zygote НАВСЕГДА зацикленным "no namespace
# called com_android_art" при первом же краше после старта (живой тест:
# 296+ падений подряд, интервал ровно 5с, без сходимости). Заменено на
# скрипт fix-linkerconfig-visibility.sh, который гоняет linkerconfig И
# сразу же переприменяет sed -- см. init.zygote64.rc (onrestart exec).
# ВАЖНО: НЕ /system/bin/ -- та же грабля, что уже задокументирована выше
# для APEX-бинарей ("на staging-точке ДО pivot_root не резолвится").
# Живой тест 2026-07-12 подтвердил: touch+mount --bind в ${R}/system/bin/
# молча ничего не создаёт (init потом видит "No such file or directory").
# /system/framework/ используется ниже по ТОЧНО ТОЙ ЖЕ схеме, что и
# framework-connectivity-built.jar (проверено рабочим много раз) -- взят
# этот путь вместо /system/bin/.
install -D -m 644 /dev/null "${R}/system/framework/fix-linkerconfig-visibility.sh" 2>/dev/null || true
mount --bind /userdata/fix-linkerconfig-visibility.sh "${R}/system/framework/fix-linkerconfig-visibility.sh" 2>/dev/null || true
chmod 755 "${R}/system/framework/fix-linkerconfig-visibility.sh" 2>/dev/null || true

mount -t tmpfs android_mnt          "${R}/mnt"          2>/dev/null || true
# mount.sh только что перекрыл /mnt пустым tmpfs, но хост УЖЕ монтировал сюда
# реальный persist (/dev/sda5) в /mnt/vendor/persist ДО этого — ADSP не видит
# реестр калибровки сенсоров (/mnt/vendor/persist/sensors/registry/registry)
# и падает с SNS_REG_TASK assert. Возвращаем persist поверх свежего tmpfs.
mkdir -p "${R}/mnt/vendor/persist" 2>/dev/null || true
mount --bind /var/lib/lxc/android/rootfs/mnt/vendor/persist "${R}/mnt/vendor/persist" 2>/dev/null || true

# НАЙДЕНО 2026-07-19 (Находка 27, продолжение): маскировка /mnt выше
# (android_mnt tmpfs) заодно скрыла /mnt/user/0 -- в реальном Android
# его создаёт vold динамически на старте (per-user storage staging), у
# нас vold толком не функционирует. system_server форкается (!), но
# сразу падает: "Failed to mount /mnt/user/0 to /storage: No such file
# or directory" (com_android_internal_os_Zygote.cpp:792). Просто
# создаём пустой каталог -- ровно то, с чего начинает реальный vold.
mkdir -p "${R}/mnt/user/0" 2>/dev/null || true

# НАЙДЕНО 2026-07-19 (Находка 27, продолжение): "/storage" (цель того
# же mount()) ВООБЩЕ отсутствовал -- lxc.rootfs.path
# (/var/lib/lxc/android/rootfs) САМ ПО СЕБЕ пустой tmpfs (не бинд
# реальной партиции целиком!), заполняются только явно перечисленные
# systemd unit'ами подкаталоги (system, cache, data, odm, metadata,
# mnt/vendor/*) -- "storage" нигде не создаётся. В реальном Android
# это тоже просто пустой mountpoint-заглушка (реальные точки монтирования
# накладываются позже через FUSE/vold).
mkdir -p "${R}/storage" 2>/dev/null || true

mkdir -p "${R}/metadata/apex/sessions" 2>/dev/null || true
mount -t tmpfs android_metadata "${R}/metadata" 2>/dev/null || true
mkdir -p "${R}/metadata/apex/sessions" 2>/dev/null || true

# НАЙДЕНО 2026-07-12 (полное сравнение с в25-mount.sh): у нас не хватало
# dalvik.vm.usejitprofiles=false и ro.apex.updatable=false здесь. Первое --
# отключает попытки ART читать/использовать JIT-профили (.prof/.bprof,
# видели их в стоковой прошивке рядом с services.jar) при загрузке
# классов -- если эти профили устарели относительно наших пересобранных
# сегодня jar'ов, это потенциальный источник верификационного краша.
# Второе -- ro.* (write-once, первый писатель побеждает), prop.default
# грузится ДО vendor/build.prop, так что дублируем здесь на случай, если
# наш VENDOR_BUILD_PROP патч ниже применяется ненадёжно/позже.
PROP_ORIG="${R}/system/etc/prop.default"
if [ -f "$PROP_ORIG" ]; then
    PROP_TMP="/run/halium-prop.default"
    cat "$PROP_ORIG" > "$PROP_TMP"
    printf "\nro.crypto.state=unsupported\nro.crypto.type=none\ndalvik.vm.usejitprofiles=false\nro.apex.updatable=false\n" >> "$PROP_TMP"
    chmod 644 "$PROP_TMP"
    mount -o bind "$PROP_TMP" "$PROP_ORIG" 2>/dev/null || true
fi

patch_rc() {
    SRC="$1"; shift
    TMP="/run/halium-rc-$(echo "$SRC" | tr "/" "-")"
    sed "$@" "$SRC" > "$TMP" 2>/dev/null && \
        chmod 644 "$TMP" && \
        mount --bind "$TMP" "$SRC" 2>/dev/null || true
}

# boringssl self-test: нестабильный (иногда падает, иногда нет), reboot_on_failure
# вызывает НАСТОЯЩИЙ trigger_shutdown() -> init внутри контейнера зацикленно
# перезапускается каждые ~2-3с. Убираем reboot_on_failure, чтобы при провале
# init просто логировал ошибку и шёл дальше (как и остальные патчи ниже).
BSSL_RC="${R}/vendor/etc/init/boringssl_self_test.rc"
[ -f "$BSSL_RC" ] && patch_rc "$BSSL_RC" "/reboot_on_failure/d"
{
    echo "DEBUG $(date +%s.%N): R=${R}"
    echo "DEBUG: ls -la \${R} ="
    ls -la "${R}" 2>&1
    echo "DEBUG: ls -la \${R}/system ="
    ls -la "${R}/system" 2>&1
    echo "DEBUG: test -f \${R}/system/etc/init/hw/init.rc -> $([ -f "${R}/system/etc/init/hw/init.rc" ] && echo YES || echo NO)"
} >> /userdata/mount-sh-debug.log 2>&1
BSSL_SYS_RC="${R}/system/etc/init/hw/init.rc"
# Также вырезаем "mount none /linkerconfig/bootstrap /linkerconfig bind rec" —
# иначе контейнерный init позже перемонтирует /linkerconfig обратно на
# минимальный bootstrap-конфиг, затирая тот полный ld.config.txt, который мы
# только что сгенерировали выше (см. комментарий про apexd/apex-info-list.xml).
#
# НАЙДЕНО 2026-07-12 (из истории проекта, сессия в25 -- см. память
# project_halium_runtime_boot): у нас (в отличие от в25) НЕТ явного
# принудительного BOOTCLASSPATH/SYSTEMSERVERCLASSPATH -- мы полностью
# полагаемся на автоматический derive_classpath (apexd никогда реально
# не активирует наши APEX-модули, поэтому derive_classpath вычисляет
# classpath на основе того, что видит В apex-info-list.xml/каждого APEX
# linker-конфига -- потенциально неполно/неконсистентно, особенно после
# сегодняшнего расширения apex-info-list.xml с 11 до 19 модулей).
# в25 ДОБИЛСЯ первого в истории проекта реального старта com.android.phone
# именно с этим ЯВНЫМ, курируемым EXPORT_BLOCK (проверено живым тестом
# 2026-07-10). Восстанавливаем их проверенный механизм: инъекция export
# СРАЗУ ПОСЛЕ строки "load_exports /data/system/environ/classpath" в
# init.rc (чтобы наше значение побеждало штатный derive_classpath,
# который иначе перезаписывает allowed classpath позже) + отдельный
# bind-mount /data/system/environ/classpath (некоторые компоненты типа
# PackageManagerService читают этот файл НАПРЯМУЮ, а не через env).
# ВАЖНО: объединено в ОДИН mount --bind на init.rc вместе с sed-вырезкой
# reboot_on_failure/bootstrap-строки -- ДВА последовательных bind-mount'а
# на один и тот же путь внутри staging-выполнения mount.sh НЕ переживают
# переход в финальный контейнер (та же аномалия что и с /linkerconfig) --
# только ПЕРВЫЙ bind-mount доходит до реального init, второй теряется.
if [ -f "$BSSL_SYS_RC" ]; then
    EXPORT_BLOCK="/run/halium-rc-init-export-block"
    printf '    export BOOTCLASSPATH /apex/com.android.art/javalib/core-oj.jar:/apex/com.android.art/javalib/core-libart.jar:/apex/com.android.art/javalib/okhttp.jar:/apex/com.android.art/javalib/bouncycastle.jar:/apex/com.android.art/javalib/apache-xml.jar:/system/framework/framework.jar:/system/framework/framework-graphics.jar:/system/framework/ext.jar:/system/framework/telephony-common.jar:/system/framework/voip-common.jar:/system/framework/ims-common.jar:/apex/com.android.i18n/javalib/core-icu4j.jar:/apex/com.android.conscrypt/javalib/conscrypt.jar:/apex/com.android.media/javalib/updatable-media.jar:/apex/com.android.os.statsd/javalib/framework-statsd.jar:/apex/com.android.sdkext/javalib/framework-sdkextensions.jar:/apex/com.android.wifi/javalib/framework-wifi.jar:/apex/com.android.btservices/javalib/framework-bluetooth.jar:/system/apex/com.android.permission/javalib/framework-permission.jar:/system/apex/com.android.permission/javalib/framework-permission-s.jar:/system/framework/framework-connectivity-built.jar\n    export DEX2OATBOOTCLASSPATH /apex/com.android.art/javalib/core-oj.jar:/apex/com.android.art/javalib/core-libart.jar:/apex/com.android.art/javalib/okhttp.jar:/apex/com.android.art/javalib/bouncycastle.jar:/apex/com.android.art/javalib/apache-xml.jar:/system/framework/framework.jar:/system/framework/framework-graphics.jar:/system/framework/ext.jar:/system/framework/telephony-common.jar:/system/framework/voip-common.jar:/system/framework/ims-common.jar:/apex/com.android.i18n/javalib/core-icu4j.jar\n    export SYSTEMSERVERCLASSPATH /system/framework/com.android.location.provider.jar:/system/framework/services.jar:/system/framework/org.lineageos.platform.jar:/apex/com.android.art/javalib/service-art.jar:/apex/com.android.media/javalib/service-media-s.jar:/system/apex/com.android.permission/javalib/service-permission.jar\n    export STANDALONE_SYSTEMSERVER_JARS /apex/com.android.os.statsd/javalib/service-statsd.jar:/apex/com.android.wifi/javalib/service-wifi.jar\n' > "$EXPORT_BLOCK" 2>/dev/null
    TMP_INIT_FILTERED="/run/halium-rc-init-filtered-classpath"
    TMP_INIT_RC="/run/halium-rc-init-full-classpath"
    # НАЙДЕНО 2026-07-19: builtin-действие "wait_for_coldboot_done" (early-init)
    # блокирует весь init НАВСЕГДА -- оно ждёт property ro.cold_boot_done=1,
    # а установка ЛЮБОГО property падает с "SELinux permission check failed"
    # (нет загруженной sepolicy -- загружать её напрямую через
    # /sys/fs/selinux/load ОПАСНО, см. feedback_no_sepolicy_load: уронило всё
    # устройство). Файл-маркер /dev/.coldboot_done РЕАЛЬНО создаётся ueventd
    # (подтверждено живым тестом, kill -STOP + /proc/PID/root), coldboot
    # физически завершается за ~0.6с -- сам wait тут просто лишний, раз мы
    # ЗНАЕМ что coldboot уже закончился к этому моменту. Убираем саму
    # команду -- это НЕ builtin-название trigger'а (нельзя удалить через
    # обычный action-header), а команда ВНУТРИ action-блока, поэтому просто
    # sed-строка, как и остальные вырезки здесь. См.
    # DROIDIAN-V2-SYSTEMD-FIX-HOWTO.md Находка 17.
    # НАЙДЕНО 2026-07-19: "wait_for_prop apexd.status activated" вешает
    # весь дальнейший boot НАВСЕГДА -- наш apexd (постоянный сервис) не
    # может стартовать (createProcessGroup / cgroup2 "Read-only file
    # system", см. Находка 22) и НИКОГДА не выставляет apexd.status --
    # zygote и всё, что после, просто не запускается, без единой
    # диагностической строки в логе (тихое зависание). apexd-bootstrap
    # УЖЕ активировал нужные нам APEX (Находка 21) -- сам apexd для
    # достижения zygote/system_server не нужен, убираем сам wait.
    sed -e "/reboot_on_failure/d" -e "\#mount none /linkerconfig/bootstrap /linkerconfig bind rec#d" -e "/^[[:space:]]*wait_for_coldboot_done[[:space:]]*$/d" -e "/^[[:space:]]*wait_for_prop apexd\.status activated[[:space:]]*$/d" "$BSSL_SYS_RC" > "$TMP_INIT_FILTERED" 2>/dev/null
    LOAD_EXPORTS_LINE=$(grep -n "load_exports /data/system/environ/classpath" "$TMP_INIT_FILTERED" 2>/dev/null | head -1 | cut -d: -f1)
    {
        if [ -n "$LOAD_EXPORTS_LINE" ]; then
            sed -n "1,${LOAD_EXPORTS_LINE}p" "$TMP_INIT_FILTERED"
            cat "$EXPORT_BLOCK"
            NEXT_LINE=$((LOAD_EXPORTS_LINE + 1))
            sed -n "${NEXT_LINE},\$p" "$TMP_INIT_FILTERED"
        else
            printf 'on early-init\n'
            cat "$EXPORT_BLOCK"
            printf '\n'
            cat "$TMP_INIT_FILTERED"
        fi
    } > "$TMP_INIT_RC" 2>/dev/null
    chmod 644 "$TMP_INIT_RC" 2>/dev/null
    mount --bind "$TMP_INIT_RC" "$BSSL_SYS_RC" 2>/dev/null || true
    {
        echo "DEBUG: entered export-block branch, LOAD_EXPORTS_LINE=${LOAD_EXPORTS_LINE}"
        echo "DEBUG: TMP_INIT_RC size = $(wc -c < "$TMP_INIT_RC" 2>/dev/null)"
        echo "DEBUG: grep BOOTCLASSPATH in TMP_INIT_RC: $(grep -c BOOTCLASSPATH "$TMP_INIT_RC" 2>/dev/null)"
        echo "DEBUG: post-mount grep BOOTCLASSPATH in \$BSSL_SYS_RC: $(grep -c BOOTCLASSPATH "$BSSL_SYS_RC" 2>/dev/null)"
    } >> /userdata/mount-sh-debug.log 2>&1

    CLASSPATH_FILE="${R}/data/system/environ/classpath"
    CLASSPATH_TMP="/run/halium-rc-classpath-file"
    sed 's/^    //' "$EXPORT_BLOCK" > "$CLASSPATH_TMP" 2>/dev/null
    chmod 644 "$CLASSPATH_TMP" 2>/dev/null
    if [ -f "$CLASSPATH_FILE" ]; then
        mount --bind "$CLASSPATH_TMP" "$CLASSPATH_FILE" 2>/dev/null || true
        mount -o remount,ro,bind "$CLASSPATH_FILE" 2>/dev/null || true
    fi
fi

VOLD_RC="${R}/system/etc/init/vold.rc"
[ -f "$VOLD_RC" ] && patch_rc "$VOLD_RC" "/reboot_on_failure/d"

# НАЙДЕНО 2026-07-19: apexd (постоянный сервис, не -bootstrap) падает с
# "createProcessGroup(0, PID) failed" (cgroup-проблема, см. Находка 18) --
# у него reboot_on_failure reboot,apexd-failed, что через LXC
# reboot-interception (Находка 13) вызывает тугой цикл респавна ВСЕГО
# /init. apexd-bootstrap уже успешно активирует нужные APEX (Находка 21,
# SHALLOWFIX для apex/) -- сам сервис apexd для нашей цели (дожить до
# zygote/system_server) не критичен, убираем reboot_on_failure чтобы
# сбой просто логировался и boot шёл дальше.
APEXD_RC="${R}/system/etc/init/apexd.rc"
[ -f "$APEXD_RC" ] && patch_rc "$APEXD_RC" "/reboot_on_failure/d"

# НАЙДЕНО 2026-07-19: та же cgroup2 "Read-only file system" история
# (Находка 22) валит createProcessGroup ДЛЯ ЛЮБОГО сервиса -- bpfloader
# следующий в очереди с reboot_on_failure после apexd (whack-a-mole).
BPFLOADER_RC="${R}/system/etc/init/bpfloader.rc"
[ -f "$BPFLOADER_RC" ] && patch_rc "$BPFLOADER_RC" "/reboot_on_failure/d"

NETD_RC="${R}/system/etc/init/netd.rc"
[ -f "$NETD_RC" ] && patch_rc "$NETD_RC" \
    -e "/reboot_on_failure/d" \
    -e "/onrestart restart zygote/d" \
    -e "s/^\(\s*\)class main/\1class disabled/" \
    -e "s/^\(\s*\)critical$/\1# critical (disabled for Ubuntu Touch)/"

# НАЙДЕНО 2026-07-19 (Находка 35, продолжение): даже после фикса
# линковки android.hardware.sensors-V1-ndk.so сам HAL-процесс
# (vendor.sensors-hal-multihal) тихо exit(1) -- упирается в
# нефункциональный ADSP/sensor-hub на уровне ядра (sscrpcd
# бесконечно ловит "No such device"). SensorService.onBootPhase()
# синхронно блокирует ГЛАВНЫЙ ПОТОК system_server, ожидая ответа от
# этого HAL -- подтверждено многократными ANR-дампами (/data/anr/) и
# периодическим watchdog-рестартом ВСЕГО контейнера каждые ~90-100с
# (живой тест 240с: ни разу sys.boot_completed). Отключаем сам сервис
# целиком (class hal -> disabled) -- SensorService должен сразу
# определить "сенсоров нет" вместо бесконечного ожидания медленного/
# неотвечающего HAL. Настоящая поддержка сенсоров для m52xq требует
# отдельной работы на уровне ADSP-драйвера ядра, вне сегодняшнего
# объёма.
SENSORS_HAL_RC="${R}/vendor/etc/init/android.hardware.sensors-service.samsung-multihal.rc"
[ -f "$SENSORS_HAL_RC" ] && patch_rc "$SENSORS_HAL_RC" \
    -e "s/^\(\s*\)class hal/\1class disabled/"

for RC in \
    "${R}/vendor/etc/init/android.hardware.health@2.1.rc" \
    "${R}/vendor/etc/init/android.hardware.health@2.0.rc" \
    "${R}/system/etc/init/healthd.rc"; do
    [ -f "$RC" ] && patch_rc "$RC" \
        -e "/reboot_on_failure/d" \
        -e "s/^\(\s*\)critical$/\1# critical (disabled)/" \
        -e "s/^\(\s*\)class main/\1class disabled/"
done

for RC in \
    "${R}/system/etc/init/zygote.rc" \
    "${R}/system/etc/init/zygote64.rc" \
    "${R}/system/etc/init/zygote_secondary.rc"; do
    [ -f "$RC" ] && patch_rc "$RC" \
        -e "/reboot_on_failure/d" \
        -e "s/^\(\s*\)critical$/\1# critical (disabled)/"
done

for RC in \
    "${R}/vendor/etc/init/android.hardware.wifi.supplicant-service.rc" \
    "${R}/vendor/etc/init/wpa_supplicant*.rc"; do
    [ -f "$RC" ] && patch_rc "$RC" \
        -e "/reboot_on_failure/d" \
        -e "s/^\(\s*\)class main/\1class disabled/"
done

for RC in \
    "${R}/system/etc/init/rild.rc" \
    "${R}/vendor/etc/init/rild*.rc"; do
    [ -f "$RC" ] && patch_rc "$RC" \
        -e "/reboot_on_failure/d" \
        -e "s/^\(\s*\)class main/\1class disabled/" \
        -e "s/^\(\s*\)critical$/\1# critical (disabled)/"
done

USB_STUB="/run/halium-stub-usb.rc"
printf "# USB gadget managed by Ubuntu Touch (usb-moded). Android disabled.\n" > "$USB_STUB"
chmod 644 "$USB_STUB"
for USB_RC in \
    "${R}/system/etc/init/hw/init.usb.rc" \
    "${R}/system/etc/init/hw/init.usb.configfs.rc" \
    "${R}/vendor/etc/init/hw/init.qcom.usb.rc" \
    "${R}/vendor/etc/init/android.hardware.usb@1.3-service-qti.rc"; do
    [ -f "$USB_RC" ] && mount --bind "$USB_STUB" "$USB_RC" 2>/dev/null || true
done

# НАЙДЕНО 2026-07-18: exec "/init" ловит ELOOP на самом финальном шаге
# lxc-start, уже ПОСЛЕ того как этот hook (mount.sh) полностью
# отработал -- диагностика прямо здесь, в ТОМ ЖЕ mount namespace,
# который увидит exec().
TB="$R/system/bin/toybox"
chk() {
    p="$1"
    if [ -L "$p" ]; then
        echo "$p : SYMLINK"
    elif [ -d "$p" ]; then
        echo "$p : DIRECTORY"
    elif [ -f "$p" ]; then
        echo "$p : FILE"
    elif [ -e "$p" ]; then
        echo "$p : EXISTS (other type)"
    else
        echo "$p : DOES NOT EXIST"
    fi
}
{
    echo "=== init-eloop-diag PID=$$ ==="
    echo "R=$R"
    echo "TB=$TB toybox_exists=$([ -x "$TB" ] && echo yes || echo no)"
    chk "$R/init"
    chk "$R/system"
    chk "$R/system/system"
    chk "$R/system/system/bin"
    chk "$R/system/system/bin/init"
    chk "$R/system/bin"
    chk "$R/system/bin/init"
    echo "--- toybox readlink -f \$R/init ---"
    [ -x "$TB" ] && "$TB" readlink -f "$R/init" 2>&1
    echo "--- toybox ls -la \$R/system ---"
    [ -x "$TB" ] && "$TB" ls -la "$R/system" 2>&1
    echo "--- toybox ls -la \$R/system/system ---"
    [ -x "$TB" ] && "$TB" ls -la "$R/system/system" 2>&1
    echo "=== END init-eloop-diag ==="
}

exit 0
