# в11 — ПЛАН

Базируется на в10 (полная копия `halium-extras`/`META-INF`/
`mount-patched-v3.sh`, симлинки на неизменные большие ассеты как и
раньше). См. `../v10/DROIDIAN-V10-PLAN.md` за полной историей задач
1-9 (место под приложения/overlay, задержка контейнера, RW-память,
polkit, звук, фонарик, мобильная связь, NTP/часы, оптимизация) — этот
документ описывает только НОВОЕ поверх в10.

## ЗАДАЧА 7 (из в10 плана): мобильная связь — начата, НЕ завершена

Симптом: кнопки набора номера в звонилке потушены/неактивны --
`org.ofono.Manager.GetModems` возвращает 0 модемов.

**Два реальных бага найдены и исправлены (2026-07-23, живьём, ещё НЕ
в исходниках v11)**:

1. `/usr/libexec/lxc-android-config/ofonod-wrapper` выбирает между
   `ril`/`binder` плагином через `` `device-info get OfonoPlugin` ``,
   но утилита `device-info` в системе отсутствует
   (`device-info: not found`). Пустой результат ≠ "binder", поэтому
   скрипт ВСЕГДА уходил в ветку "отключить binder, использовать ril" --
   а `ril` тут не настроен и не работает вообще. Это ровно то же
   семейство проблемы, что "oFono binder plugin SOLVED" в другом
   (Ubuntu Touch) проекте, просто с другим триггером. **Фикс**:
   захардкожен выбор `binder` напрямую, в обход сломанной проверки
   (файл сохранён: `/tmp/claude-.../scratchpad/ofonod-wrapper-fixed`
   на компе, задеплоен на `/usr/libexec/lxc-android-config/
   ofonod-wrapper` на телефоне).
2. После фикса №1 всплыла `Invalid user 'radio'` -- в этой Debian-
   системе нет системного пользователя `radio` (Android жёстко ждёт
   `AID_RADIO`/UID 1001). **Фикс**: добавлена строка вручную в
   `/etc/passwd`+`/etc/shadow`+`/etc/group` (`useradd`/`adduser` в
   системе отсутствуют вообще, добавлялось руками).

**После обоих фиксов -- всё ещё 0 модемов, без явной ошибки в логе.**
Дополнительно пробовал поправить `/etc/ofono/binder.conf`: у него было
`path = /ril_0`/`/ril_1` (легаси socket-путь как имя HIDL-инстанса),
поменял на `path = slot1`/`slot2` (имя, которое реально видели у
`android.hardware.radio@1.0::IRadio/slot1` на живом LineageOS того же
устройства) -- **не подтверждено, что помогло**, но и не хуже
оригинала (тот тоже давал 0). Оригинал сохранён:
`/userdata/binder.conf.orig-backup` на телефоне.

**Следующий шаг**: включить debug/verbose лог `ofonod` (обычно через
`-d` флаг или `OFONO_DEBUG` в конфиге) чтобы увидеть, где именно
binder-плагин спотыкается при попытке подключиться к `hwbinder`-
сервису `IRadio` внутри контейнера -- сейчас лог просто молчит после
"Excluding RIL modem driver", без единой строки про сам binder.
Возможно, дело в правах на `/dev/hwbinder` для процесса `ofonod`
(запущен НЕ от `radio`, просто от `root` -- реальный Android radio
процесс имеет UID `radio` при обращении к hwbinder, у нас только
сам ЮЗЕР создан, но `ofonod` не переключается на его UID).

**НЕ перенесено в исходники в11** -- всё пока live-only на телефоне
(кроме уже отдельно задокументированных polkit/journald/fstab фиксов,
которые перенесены). Нужно перенести `ofonod-wrapper` фикс и создание
`radio`-пользователя (через `update-binary`, аналогично тому, как
уже добавлялись `.writable_image`-маркеры) в исходники, когда сама
связь реально заработает -- нет смысла тащить в архив частичный,
неподтверждённый фикс.

## ЗАДАЧА (будущее, не начато): запуск Android-приложений (APK) в Phosh

Идея (2026-07-23): у нас уже есть полноценный Android-контейнер с
реально работающим GPU-рендерингом через hwcomposer (см.
`project_droidian_gpu_touch_solved` в памяти) -- `zygote64`,
`com.android.phone`, PackageManager внутри контейнера физически живы.
Архитектурно это близко к тому, как устроен Waydroid (тоже
облегчённый Android-контейнер для запуска APK поверх Wayland-хоста).

**Это НЕ означает, что можно уже сейчас поставить и запустить APK.**
Установка пакета (`pm install`) отдельно от вывода его окна на экран
-- чтобы реально ПОКАЗАТЬ приложение в Phosh, нужно прокинуть вывод
Android'овского SurfaceFlinger в Wayland-поверхность, примерно как
это делает отдельный протокол/мост Waydroid. Это отдельная, крупная
инженерная задача (не пробовалась и не тестировалась в этом проекте),
не тривиальная правка. Отложено на будущее, не в объёме в11.

## ЗАДАЧА (будущее, не начато): аппаратное декодирование видео в Firefox

Найдено (2026-07-23): YouTube/видео в `firefox-esr` тормозит и жрёт
CPU (главный процесс ~130%, `RDD Process` ~41%, вкладка ~41%,
`load average` доходит до ~10 на восьмиядерном SoC). Проверено живьём
через `/proc/<pid>/environ` -- GPU-мост наследуется ПРАВИЛЬНО
(`EGL_PLATFORM=hwcomposer`, `WLR_BACKENDS=hwcomposer,libinput`, точно
как у `phoc`), так что дело не в отсутствии GPU-переменных для
композитинга/интерфейса.

Причина тормозов -- **отдельно от EGL/рендеринга** аппаратное
ДЕКОДИРОВАНИЕ видео (обычно через VA-API/V4L2, завязано на конкретный
видео-кодек Adreno) в системе вообще не сконфигурировано -- Firefox
декодирует видео чисто софтварно на CPU. Это отдельный мост к
видео-кодеку, по объёму сопоставимый с сегодняшней работой над звуком
(Задача "звук — ядро починено, юзерспейс ещё нет" выше) -- не быстрая
правка, не начиналось.

**Следующий шаг**: разобраться, какой драйвер/HAL реально предоставляет
video decode на этом SoC (Adreno/Venus), есть ли для него
VA-API-обёртка в mainline/Debian экосистеме (`libva-v4l2-request` или
аналог), и можно ли прокинуть его через тот же
`/opt/halium-lxc-bridge` механизм, что уже используется для GPU/audio
HAL.

## Статус на момент создания (2026-07-22)

в10 был собран и прошит на полностью стёртый (`wipe`) `/data`. Первая
загрузка зависла (SSH/сеть не поднялись за 10+ минут). Диагностика
через TWRP (`adb`, `console-ramoops`, прямой loop-mount `rootfs.img`)
не показала признаков паники ядра — Android-контейнер работал
нормально минимум 400 секунд (обычный, безвредный
`audioserver`/`cameraserver`-спам). Причина зависания НЕ подтверждена
окончательно.

## Главная находка сессии: настоящий источник RO-корня

`/etc/fstab` — НЕ статичный файл, а bind-mount на `/run/image.fstab`,
генерируемый С НУЛЯ каждую загрузку функцией `process_bind_mounts()`
в initrd (`scripts/halium`). Эта функция безусловно пишет первой
строкой `echo "/dev/root / rootfs defaults,ro 0 0" >>$FSTAB` — до
всякого чтения `writable-paths`, независимо от
`.writable_image`/`.writable_image_overlay` маркеров.

Из-за этого ДВЕ предыдущих попытки фикса в в10 были бесполезны:
- живой `sed -i /etc/fstab` (не пережил перезагрузку — fstab
  генерируется заново),
- `sed` внутри `rootfs.img` через `update-binary` (правил статичную
  заглушку `# UNCONFIGURED FSTAB FOR BASE SYSTEM`, которую initrd
  всё равно игнорирует и перезаписывает).

**Настоящий фикс** — прямо в initrd, поменять `ro` на `rw` в этой
строке. Пересобран как
`/home/sasha/Templates/Дроидиан/droidian-boot-v5-fstabfix.img`,
`firmware/boot.img` в в10 (и здесь, в в11) уже переключён на него.

**СТАТУС: ещё не прошит и не протестирован.** Это задача №1 для в11 —
проверить (через `fastboot flash boot` для быстрого теста без
пересборки всего архива, либо через полную переустановку) действительно
ли этот фикс даёт стабильный первый boot после чистой прошивки.

## Задача 1 (в11): протестировать droidian-boot-v5-fstabfix.img

- Прошить (`fastboot flash boot` — быстрее, не требует wipe `/data`
  заново) и дождаться реальной загрузки.
- Подтвердить: `mount | grep " / "` показывает `rw` СРАЗУ и остаётся
  `rw` после нескольких перезагрузок подряд (не только одной).
- Подтвердить: `apt-get update`/`mkdir` под `/var/lib/dpkg` больше не
  падают с "Read-only file system"/EROFS.
- Подтвердить: место под `/` действительно ~98ГБ (`df -h /`), не 5ГБ.
- Если ok — перепроверить яркость/часы (Задача 3 из в10 плана) уже в
  штатных условиях (rw с первой секунды, не деградировавшее
  live-состояние).

## Задача 2 (в11, если время будет): разобраться, что реально держало
## загрузку в10 без SSH 10+ минут

Не обязательно тот же самый RO-баг (Android-контейнер работал
нормально по pstore) — возможно, отдельная причина, специфичная
именно для ПЕРВОЙ загрузки после полного wipe (генерация machine-id,
dconf, все dpkg-триггеры с нуля, что-то из нового overlay-механизма).
Стоит перепроверить ПОСЛЕ фикса fstab — если v5 boot загрузится
нормально, вопрос снимается сам собой; если нет — нужна более глубокая
диагностика (например, серийная консоля/UART, если физически
доступна, раз USB/pstore видимости оказалось недостаточно в этот раз).

## Известные из в10 находки, актуальные и здесь

- `rootfs.img` требовал recovery журнала при loop-mount (`EXT4-fs:
  recovery complete`) после того, как `update-binary` монтировал его
  `rw` для инъекции юнитов. **ИСПРАВЛЕНО**: добавлен явный `sync` перед
  `umount "$ROOTFS_MNT"` в `update-binary`.
- Все остальные фиксы в10 (звук/`CONFIG_QCOM_APR`, sscrpcd, 20с
  задержка, kernel-modules-fixed, save/restore-state механизм с
  часами/яркостью/NTP) остаются как есть, не трогались.

## ЗАДАЧА 1 ЗАКРЫТА (2026-07-23, живой тест): рабочая комбинация найдена

Полный цикл: `fstab`-фикс (rw с первой секунды) + описанная ниже
находка про `journald` + задержка контейнера 80с → **первая настоящая
загрузка до рабочего стола Phosh на чистом `/data` за всю историю
сессии**. SSH поднялся, `phoc`/`phosh`/`gnome-session` живы.

**Вторая находка (важнее самого fstab)**: `systemd-journald.service.d/
00-wait-for-rw.conf` требовал (`Requires=`) завершения
`halium-early-remount-rw.service` перед стартом `journald`. Если этот
юнит подвисает/не завершается на чистой прошивке -- `journald` **никогда
не стартует**, а раз почти все юниты в systemd неявно зависят от
`journald.socket`, это тянет за собой зависание значительной части
загрузки (SSH, usb-moded). Подтверждено экспериментом: с полностью
замаскированным `lxc-android-config.service` (Android-контейнер
принудительно выключен) systemd всё равно доходил только до определённой
точки без наших фиксов -- а сняв `journald`-блокировку, загрузка
дошла до `phoc`/`phosh` даже с контейнером ВКЛЮЧЁННЫМ. **Дроп-ин
удалён** (`systemd-journald.service.d/00-wait-for-rw.conf` больше нет
в `rootfs-files`).

Итоговая рабочая конфигурация (уже в `halium-extras`):
- `halium-wait-network-before-lxc.sh`: `sleep 80` (не изолировано до
  минимума, есть вероятно избыточный запас).
- `systemd-journald.service.d/00-wait-for-rw.conf` -- удалён.
- `usb-moded` developer-mode фикс -- без изменений, уже работал.

**Не до конца понятое**: наш собственный
`halium-early-remount-rw.service` теперь избыточен (fstab уже даёт
`rw` с первой секунды) -- НЕ удалён, просто больше ничего от него не
зависит. Можно убрать в следующий раз для чистоты, не мешает работе.

## ЗАДАЧА: звук — ядро полностью починено, юзерспейс ещё нет

**Ядро подтверждено рабочим на 100%**: `/proc/asound/cards` показывает
реальную карту (`lahaina-yupikidp-snd-card`), вся цепочка модулей
(`apr_dlkm`, `q6_dlkm`, `wcd9xxx_dlkm`, `wcd938x_dlkm`,
`bolero_cdc_dlkm`, `machine_dlkm`, rx/tx/va_macro) загружена, НИ ОДНОГО
`apr_send_pkt exported twice` в dmesg. Фикс `CONFIG_QCOM_APR` (см.
план в10, Задача 5) работает полностью так, как задумано.

**Юзерспейс (WirePlumber/PipeWire) — не подхватывает карту**:
`wpctl status` видит `Built-in Audio [alsa]` как устройство, но не
создаёт из него реальный sink -- все потоки уходят в фиктивный `Dummy
Output`. Причина: у карты `lahaina-yupikidp` нет ALSA UCM2-профиля
(`/usr/share/alsa/ucm2/Qualcomm/*` содержит только mainline-профили --
`sdm845`, `sm8250`, `sm8550` и т.д. -- у нас же родная Android/LPASS-
архитектура с `MultiMedia1-32` PCM-устройствами и APR/AFE/ADM
маршрутизацией через DSP, структурно другая). Прямой `aplay`/`amixer`
(после установки `alsa-utils`) тоже не завёлся с базовыми параметрами
("Unable to install hw params") -- карта требует специфичного
конфигурирования маршрута ПЕРЕД открытием PCM-устройства.

**Материалы для продолжения** (сохранены в
`v11/audio-investigation/`, вытащены как с живого устройства через
TWRP `/dev/block/mapper/vendor`, так и из локального стокового образа
`/home/sasha/Загрузки/m52stok/vendor.img` -- идентичны, сверено
`diff`):
- `mixer_paths.xml` (145КБ) -- путь `speaker`→`spk` в файле ПУСТОЙ
  (нет `<ctl>` записей), т.е. реальная маршрутизация speaker'а не
  сводится к простому набору mixer-контролов в одном месте.
- `audio_platform_info.xml`, `audio_policy_configuration.xml` --
  описывают доступные PCM-устройства/бэкенды для policy-слоя Android
  audio HAL.
- `adsp_avs_config.acdb` (240 байт) -- нашёлся в `/vendor/etc/acdbdata/`
  на стоковом образе, но это оказался просто реестр кодек-модулей
  (aptX и т.п.), НЕ полная калибровочная база. Полная ACDB-калибровка
  (обычно несколько МБ на реальных QCOM-устройствах) физически не
  найдена ни в `/vendor`, ни в первом приближении -- вероятно, отдельный
  `/persist`-раздел или device-специфичный путь, не проверено.

**Следующий шаг**: найти реальный источник калибровки/маршрутизации
(либо через `audio_platform_info.xml`'s описание backend'ов + ручной
подбор `<ctl>` последовательности через `amixer` для конкретного
PCM-устройства типа `MultiMedia1`, либо через поиск полного ACDB на
`/persist` живого устройства).

**ГЛАВНАЯ НАХОДКА (2026-07-23, живой тест)**: звук РЕАЛЬНО работал
живьём 2026-07-15 (см. заголовок `halium-load-audio-modules.sh`) через
`pulseaudio-modules-droid-24` + `halium-fix-audio-hal.sh` (HIDL-compat
bind-mount на `audio.primary.default.so`). Этот bind-mount **до сих
пор исправно срабатывает** (подтверждено: `mountpoint` -- да) -- но
использовать его сейчас НЕКОМУ, потому что где-то между 15-17 июля и
сейчас стек аудио-сервера сменился на **PipeWire** (голый ALSA-бэкенд,
не понимает Android HAL), а `pulseaudio-modules-droid-24` **пропал из
установленных пакетов** (только клиентские либы `libpulse0` остались).
Дроп-ин `/usr/lib/systemd/user/pulseaudio.service.d/ubuntu-touch.conf`
с проработанными обходами (HYBRIS_LD_LIBRARY_PATH, урезанный
`audio_policy_configuration.xml` из-за несовместимой схемы) всё ещё
на месте, просто простаивает.

**Установка `apt install pulseaudio pulseaudio-modules-droid-24`
УПЁРЛАСЬ В КОНФЛИКТ ЗАВИСИМОСТЕЙ**: пакет тянет `libhardware2`, который
требует `libhybris-common1 >= 0.1.0+git20250630...`, а сейчас стоит
другой, project-специфичный форк
(`0.0.5.53-1+droidian1+...+lindroid.drm`), на который завязаны
ТЕКУЩИЕ рабочие GPU/touch. Форсировать апгрейд `libhybris` живьём на
единственной сегодня стабильной, дошедшей до рабочего стола системе --
слишком рискованно (можно сломать GPU/touch, которые чинили ОЧЕНЬ
долго в прошлых сессиях). **НЕ форсировалось, оставлено как есть.**

**Следующий шаг (главный кандидат)**: разобраться, совместим ли
конкретно `pulseaudio-modules-droid-24` с ТЕКУЩИМ `lindroid.drm`
форком `libhybris`, или нужна версия `pulseaudio-modules-droid`,
собранная под этот же форк (возможно, `-modern`/`-hidl` варианты пакета
подойдут лучше, не проверено) -- пробовать строго в изоляции/на
отдельном тесте, не на живой стабильной системе с наскока.

## ЗАДАЧА: polkit "запрос пароля при выключении" — РЕШЕНО ОКОНЧАТЕЛЬНО

Настоящий `action id`, пойманный живьём через `busctl monitor
org.freedesktop.PolicyKit1` в момент реального нажатия кнопки в UI:
**`org.freedesktop.login1.reboot-ignore-inhibit`** (не просто `.reboot`,
как предполагалось в в10-доке) -- что-то держит shutdown-inhibitor-лок,
и для перезагрузки "в обход" него нужна отдельная, более высокая
авторизация.

Дополнительно найден и настоящий баг, из-за которого пароль `0000`
никогда бы не сработал в принципе, даже если бы диалог был правильно
настроен: `polkit-agent-helper-1` (бинарь, реально сверяющий пароль
через PAM) был **без бита `setuid root`** -- в журнале на каждую
попытку ввода: `polkit-agent-helper-1: needs to be setuid root`.

**Оба фикса внесены в `update-binary`** (в блоке инъекции в
`rootfs.img`, сразу после `cp -a rootfs-files`):
- `/etc/polkit-1/rules.d/49-nopasswd-power.rules` (новый файл в
  `rootfs-files`) -- `polkit.addRule` с YES для
  `reboot`/`power-off`/`suspend` (+ `-multiple-sessions`/
  `-ignore-inhibit` варианты) для пользователя `phablet`.
- `chmod 755` на `/etc/polkit-1` и `/etc/polkit-1/rules.d` (старая
  находка про права -- polkitd не может даже прочитать 700-каталог).
- `chmod u+s` на `polkit-agent-helper-1` (на случай, если для
  какого-то ДРУГОГО action понадобится настоящая аутентификация).

Подтверждено живым тестом: диалог авторизации больше не появляется
при Reboot/Power Off из UI.

## ЗАДАЧА 10: SSH/systemd не поднимался вообще после чистой прошивки v11 -- 4 наложенных бага, все найдены и исправлены (2026-07-23)

**Симптом**: после чистой прошивки v11 (с чистым `/data`) systemd
стабильно доходил только до `basic.target` и намертво стоял -- ни SSH,
ни phosh, overlay почти пустой. Диагностика заняла много часов и
несколько ложных следов (контейнер/lxc-android-config, usb-moded
rescue-режим -- оба проверены и НЕ являются причиной, см. ниже).

**Метод диагностики**: обычный pstore/dmesg оказался бесполезен --
кольцевой буфер (256КБ) успевает затереться потоком андроид-контейнерного
шума за секунды. Решение -- добавить файловое логирование поверх kmsg:
1. Патч `tell_kmsg()` в `scripts/halium` (initrd) -- дублирует каждую
   строку в `/tmpmnt/initrd-debug-vNN.log` (и второй раз в
   `$rootmnt/userdata/...` после того как `/tmpmnt` перемонтируется).
2. Аналогичные метки-таймстемпы прямо в `/init` (jumpercable).
3. Четыре systemd oneshot-юнита-трейсера (`zz-trace-{sysinit,basic,
   multi-user,graphical}.service`, `WantedBy=` + `After=` на каждый
   таргет), пишущие в `/data/systemd-boot-trace.log` -- показывают,
   до какого именно таргета реально доходит загрузка.
4. `journald`: `Storage=persistent` + `ForwardToKMsg=yes` (drop-in
   `journald.conf.d/zz-persistent.conf`) -- чтобы после любой
   перезагрузки можно было вытащить `/var/log/journal/.../system.journal`
   через TWRP и прочитать через `journalctl --file=...` (родная
   версия journalctl из `rootfs.img` через chroot+qemu-aarch64-static
   на десктопе -- версии journalctl должны совпадать, бинарный формат
   journal несовместим между сильно разными версиями systemd).

**Баг 1 -- `/init` (jumpercable) не выполнял свою настройку ВООБЩЕ,
всегда, на каждой загрузке.** Guard `if [ ! -e /proc/self/exe ]; then`
был всегда ложным (видимо `/proc` виден в этом mount namespace ещё до
явного монтирования -- unrelated ambient state, не гарантия "уже
выполнялось"). Из-за этого `mount_userdata()`/`process_bind_mounts()`
(генерация динамического `/etc/fstab` из `writable-paths`) пропускались
КАЖДЫЙ раз. **Фикс**: сменить guard на файл-маркер, который этот же
блок сам создаёт (`/dev/.halium_jumpercable`) -- self-consistent,
не зависит от постороннего mount-namespace state.
Вероятно, этот баг был всегда, но маскировался тем, что на диске
оставался рабочий `/etc/fstab` от предыдущей успешной загрузки (fstab
не является частью "synced" writable-paths, а генерируется живьём) --
проявился только сегодня, после полного вайпа `/data` в начале сессии.

**Баг 2 -- `/dev/null` монтировался с правами `root:root 0600`.**
Прямое следствие бага 1: `mount -t devtmpfs devtmpfs /dev` внутри
того самого пропускавшегося блока теперь реально выполняется каждую
загрузку, создавая СВЕЖИЙ devtmpfs с сырыми правами ядра. Классическая
гонка devtmpfs/udev, задокументирована с 2009 года (Arch/Debian форумы,
LKML) -- современные ядра обычно спецкейсят `/dev/null` и похожие узлы
в `0666` прямо при монтировании, но это Samsung/Qualcomm даунстрим-ядро
явно не содержит такого фикса. `udevd` в этот момент ещё не запущен
(systemd-управляемый демон, стартует позже) -- `udevadm trigger` тут
бесполезен (некому слушать). **Фикс**: прямой `chmod 666 /dev/null
/dev/zero /dev/full /dev/random /dev/urandom` сразу после монтирования
`/dev` в `/init`, пока скрипт ещё root (до сброса привилегий).

**Баг 3 -- пользователь `radio` отсутствовал в `/etc/passwd`/`/etc/shadow`.**
`/etc/dbus-1/system.d/ofono.conf` содержит `<policy user="radio">` --
без реального юзера весь `dbus-daemon` не мог распарсить конфиг и
падал целиком (не только ofono-часть). Группа `radio` (gid 1001) уже
была в образе, а сам юзер -- нет (более ранняя live-правка на телефоне
была потеряна при вайпе `/data`, `/etc/passwd` не персистентен).
**Фикс**: добавить `radio:x:1001:1001:radio:/nonexistent:/usr/sbin/nologin`
в `/etc/passwd` и соответствующую строку в `/etc/shadow` прямо в
`rootfs.img`.

**Баг 4 -- `AmbientCapabilities=CAP_AUDIT_WRITE` в `dbus.service` ломал
запуск на этом ядре.** Финальная ошибка после фиксов 1-3: `dbus-daemon:
Failed to start message bus: Failed to drop capabilities: Operation not
permitted`. Найден точный прецедент -- Red Hat Bugzilla #1115533,
идентичная ошибка в Docker-контейнерах: `dbus-daemon` внутри своего
кода (`capng_change_id()`) явно пытается ДОБАВИТЬ `CAP_AUDIT_WRITE` в
effective/permitted set, и это падает с `EPERM`, если ядро/окружение
не поддерживает выдачу этой capability (похоже, на этом Android-ядре
нет полноценной audit-подсистемы). `AmbientCapabilities=CAP_AUDIT_WRITE`
в базовом юните `dbus.service` -- именно то, что провоцирует эту
попытку. **Фикс**: drop-in `dbus.service.d/zz-no-ambient-cap.conf` с
`AmbientCapabilities=` (пусто, сбрасывает).

Также применён (возможно избыточно, не выделен как отдельно
необходимый) drop-in `zz-no-user-override.conf` с `User=`/`Group=`
пустыми -- сбрасывает наследуемые от базового юнита `User=messagebus`/
`Group=messagebus`, отдаёт `dbus-daemon` полный сброс привилегий на
откуп его собственному коду. Оставлен в конфигурации, так как убирать
его отдельно уже не тестировалось после того как нашёлся баг 4.

**LSM-cmdline**: по пути также пробовали урезать `lsm=` в boot.img
cmdline (`smack,tomoyo,integrity,safesetid` убраны, остались
`lockdown,yama,loadpin,selinux,apparmor`) -- решающим фиксом это НЕ
оказалось (баг 4 остался бы и с ними), но live-тест подтвердил
итоговую рабочую комбинацию именно с этим урезанным списком, так что
именно этот boot.img (`droidian-boot-v12-nosafesetid.img`) зашит в
v12 как проверенный. Технически `smack`/`tomoyo`/`integrity` не имеют
никакой userspace-конфигурации на Droidian (нет `/etc/smack/`,
`/etc/tomoyo/`) и, скорее всего, безопасно убраны навсегда;
`safesetid` без загруженного allowlist по умолчанию deny-by-default,
тоже, вероятно, ничего не защищал на Debian-стороне. `SELinux`
(permissive) и `AppArmor` (реально загружает профили) НЕ трогались.

**Итог**: SSH и systemd полностью поднимаются, `phosh.service`
стартует. Все 4 фикса внесены в v12 (`/init` в самом `rootfs.img`,
юзер `radio` в `rootfs.img`, оба `dbus.service.d/*.conf` через
`halium-extras/rootfs-files`, boot.img с урезанным LSM-списком).

## ЗАДАЧА 11: SSH умирал из-за bad liblxc-даунгрейда + гейтинг контейнера по SSH (2026-07-23/24)

**Симптом**: SSH/dbus вообще не поднимались на чистой прошивке v11→v12,
либо поднимались через много минут. `lxc-start` уходил в бесконечный
цикл (~10 попыток/сек, часами) с ошибкой
`Unsupported config key "lxc.seccomp"`, хотя сам конфиг контейнера
(`/var/lib/lxc/android/config`) НЕ содержит слова "seccomp" вообще.

**Корень**: `lxc-android-config.service` унаследован от
`systemd-udev-trigger.service` с `Before=systemd-udev-trigger.service
sysinit.target` -- это значит ВЕСЬ остальной boot (network/dbus/ssh,
всё что после `sysinit.target`) обязан ждать, пока этот юнит
(включая ExecStartPre-задержку И весь retry-шторм при падении)
завершится. Сам seccomp-баг оказался вызван тем, что где-то между
27 и 30 апреля пакеты `lxc`/`liblxc1` откатились с рабочей версии
`6.0.6-3` (trixie) на обычный Debian bookworm-security
`5.0.2-1+deb12u4`, который не умеет корректно резолвить дефолтный
seccomp-профиль контейнера.

**Фиксы**:
1. Переустановлен `liblxc1t64`/`liblxc-common`/`lxc` на `6.0.6-3` из
   кэша apt на устройстве (`dpkg --auto-deconfigure`, удалён старый
   `liblxc1`).
2. `lxc-android-config.service.d/99-wait-for-ssh.conf`: `Before=`
   (пусто, сброс) + `Before=systemd-udev-trigger.service` (без
   `sysinit.target`) + `After=`/`Wants=usb-moded-ssh.service`
   (реальный работающий SSH-сервис на этом устройстве -- НЕ
   `ssh.service`!) + `ExecStartPre=/bin/sleep 7`. Контейнер теперь не
   блокирует критический путь загрузки вообще.
3. Убран `halium-kickstart-lxc.service` (устаревший
   zygote-watchdog-обёртка, конфликтовал с новой схемой).
4. `--logpriority=DEBUG` → `ERROR` в `start-android-container`
   (старый DEBUG-уровень заполнял `lxc-debug.log` мегабайтами шума).
5. Замаскирован `halium-audiopolicy-crashloop-watchdog.service` --
   его собственный `logcat`-цикл диагностики зависал и грузил CPU на
   99%.
6. Пробовали `halium-lxc-auto-stop.service` (безусловный останов
   контейнера через 60с после старта) как защиту от перегрева -- **не
   прижилось**, ломает рабочий стол (phoc держит hwcomposer-соединение
   с контейнером постоянно, не только на старте). Убрано полностью.

## ЗАДАЧА 12: zygote бесконечно падал -- "no namespace called com_android_art" (2026-07-24)

**Симптом**: `zygote64` падал каждые ~5с с
`Abort message: 'Error finding namespace of apex: no namespace called
com_android_art'` (SIGABRT в `art::Runtime::InitNativeMethods ->
LoadNativeLibrary -> OpenNativeLibrary`). Процесс `main` (uid 9999,
`nice -20`, VIRT ~13-14GB) непрерывно респаунился, грузил CPU до
200%+ и грел телефон; несколько раз это провоцировало спонтанные
полные перезагрузки устройства (похоже на встроенную в Android init
защиту от bootloop для "critical"-сервисов).

**Это УЖЕ известный баг** (см. комментарии в `mount.sh`/
`mount-patched-v3.sh`, "живой тест: 296+ падений подряд, интервал
ровно 5с, без сходимости", 2026-07-12) -- уже был написан
`fix-linkerconfig-visibility.sh`, который перегенерирует
`/linkerconfig/ld.config.txt` и sed'ом добавляет `visible = true` в
секцию `namespace.com_android_art`. Скрипт триггерится через
`init.zygote64.rc` (`onrestart exec`), то есть переприменяется при
каждом падении zygote.

**Настоящий корень (не был найден раньше)**: этот sed чинит ТОЛЬКО
верхнеуровневый `/linkerconfig/ld.config.txt`. Но у самого APEX-модуля
ART есть СВОЙ отдельный конфиг `/linkerconfig/com.android.art/
ld.config.txt`, где его собственный namespace называется `default`
(не `com_android_art`!) -- и у него `visible = true` не было
никогда. Именно на этот namespace натыкается резолвер при попытке
загрузить нативную библиотеку изнутри самого ART.

**Фикс**: вторая sed-команда в `fix-linkerconfig-visibility.sh`,
патчащая `namespace.default.isolated = true` →
`+ namespace.default.visible = true` в
`/linkerconfig/com.android.art/ld.config.txt`. Живо подтверждено:
`init.svc.zygote` переходит в `running` (реальная работа
`system_server`) вместо бесконечного цикла падений.

**Деплой**: этот скрипт живёт на userdata-разделе
(`/userdata/fix-linkerconfig-visibility.sh`), не внутри `rootfs.img`
-- бинд-маунтится в контейнер через `mount.sh`. Раньше существовал
ТОЛЬКО как живое состояние устройства, нигде не отслеживался в
репозитории -- на чистой прошивке (wipe data) фикса просто не было
бы. Теперь явно деплоится через `update-binary`
(`halium-extras/rootfs-files/userdata/fix-linkerconfig-visibility.sh`
→ `/data/fix-linkerconfig-visibility.sh`).

## ЗАДАЧА 13: два независимых дерева файлов, второе тихо затирало фиксы из первого (2026-07-24)

**Симптом**: множество фиксов этой сессии (`99-wait-for-network.conf`
удалён, `halium-kickstart-lxc.service` удалён,
`fix-linkerconfig-visibility.sh` пропатчен) раз за разом "возвращались"
на свежепрошитом устройстве, будто прошивка их не подхватывала --
несмотря на то, что мастер-образ `rootfs-phosh-v4-apps.img`
(источник `data/rootfs-chunks/`) был отредактирован верно и это
подтверждалось прямым mount+chroot на хосте.

**Корень**: `update-binary` использует ДВА независимых источника
файловой системы:
1. `data/rootfs-chunks/*` -- собирается в `rootfs.img`, из него же
   собран весь `rootfs-phosh-v4-apps.img`, который редактировался всю
   сессию.
2. `halium-extras/rootfs-files/` -- ОТДЕЛЬНОЕ дерево файлов на диске
   (в каждой версии `vN/halium-extras/rootfs-files/`), которое
   `update-binary` копирует ПРЯМО ПОВЕРХ свежесобранного `rootfs.img`
   командой `cp -a "$EXTRAS"/rootfs-files/. "$ROOTFS_MNT/"` уже ПОСЛЕ
   пересборки из чанков. Если файл с тем же именем существует в ОБОИХ
   местах с разным содержимым -- на диске в итоге оказывается версия
   из `rootfs-files/`, а не из отредактированного образа.

   Плюс ТРЕТИЙ независимый путь: `halium-extras/units/*.service`
   копируются в `$UNITDIR` отдельным шагом и явно ВКЛЮЧАЮТСЯ через
   захардкоженный `for u in ...` список имён юнитов в самом
   `update-binary` -- эта директория тоже хранила устаревшую копию
   `halium-kickstart-lxc.service`, независимо от rootfs.img и от
   `rootfs-files/`.

   Плюс `data/userdata-overlay.tar.gz` (символьная ссылка на
   ДРЕВНИЙ снепшот от v5, ни разу не обновлялась) распаковывалась
   ПОСЛЕ точечных `/data`-деплоев конкретных скриптов -- тоже тихо
   затирала свежие версии `fix-linkerconfig-visibility.sh` и
   `halium-gpu-bridge-setup.sh` старыми из архива.

**Фиксы (все в v15)**:
1. `halium-extras/rootfs-files/etc/systemd/system/lxc-android-config.service.d/`:
   удалён `99-wait-for-network.conf`, добавлен `99-wait-for-ssh.conf`.
2. Добавлен `halium-extras/rootfs-files/etc/systemd/system/phosh.service.d/99-after-container.conf`.
3. Пропатчен rate-limit баг (отрицательный `/proc/uptime` после
   ребута) в `halium-extras/rootfs-files/usr/libexec/
   halium-fix-touch-and-unlock.sh`.
4. `--logpriority=DEBUG` → `ERROR` в
   `halium-extras/rootfs-files/usr/libexec/lxc-android-config/start-android-container`.
5. Удалён `halium-extras/units/halium-kickstart-lxc.service` + убран
   из хардкод-списка автозапуска в `update-binary`.
6. В `update-binary` блок распаковки `data/userdata-overlay.tar.gz`
   перенесён ВЫШЕ всех точечных `/data`-деплоев (было -- ниже).

**Важный урок на будущее**: при любой live-найденной правке в
`rootfs.img`/мастер-образе ОБЯЗАТЕЛЬНО сверять три места: (1)
`rootfs-chunks`/мастер-образ, (2) `halium-extras/rootfs-files/` для
того же самого пути, (3) `halium-extras/units/` + хардкод-список в
`update-binary`, если это `.service`-файл. Проверка "нашёл в
мастер-образе -- значит фикс есть" НЕ ДОСТАТОЧНА.

## ЗАДАЧА 14: контейнер не стартовал сам на v15 -- ненадёжный обратный Wants= (2026-07-24)

**Симптом**: на живой прошивке v15 SSH/phosh поднимались нормально, но
`lxc-android-config.service` оставался `inactive (dead)` до ручного
`systemctl start` -- `Wants=usb-moded-ssh.service` в
`99-wait-for-ssh.conf` его не подтягивал.

**Причина**: `usb-moded-ssh.service` -- "rescue"-юнит, стартует
аномально рано (напрямую через udev-триггер usb-moded, минуя обычную
очередь systemd-таргетов). `Wants=`-подтягивание срабатывает только в
МОМЕНТ перехода целевого юнита в `active` -- если этот переход
случился раньше, чем systemd успел загрузить наш дроп-ин с
`Wants=usb-moded-ssh.service`, событие безвозвратно упущено, обратная
связь не сработает задним числом.

**Фикс**: не полагаться только на обратный `Wants=`. Добавлен
надёжный явный симлинк `multi-user.target.wants/lxc-android-config.service`
(в `halium-extras/rootfs-files/etc/systemd/system/`) -- это гарантирует
запуск при достижении `multi-user.target` (которого система достигает
практически всегда), а `After=usb-moded-ssh.service` в
`99-wait-for-ssh.conf` (оставлен как есть) продолжает гарантировать
правильный ПОРЯДОК запуска относительно SSH, даже если оба механизма
сработают.

## ЗАДАЧА 15 (не решена, для следующей версии): SystemServer крашится на LineageSettings/LongScreen (2026-07-24)

**Симптом**: после фикса из ЗАДАЧИ 12 сам `zygote64` больше не падает
(`init.svc.zygote=running` стабильно), НО дочерний `SystemServer`
("main"-поток) падает в похожем цикле (~5с) с:
```
FATAL EXCEPTION IN SYSTEM PROCESS: main
java.lang.NullPointerException: Attempt to invoke interface method
'...IContentProvider.call(...)' on a null object reference
    at lineageos.providers.LineageSettings$NameValueCache.getStringForUser
    at lineageos.providers.LineageSettings$System.getStringForUser
    at org.lineageos.internal.applications.LongScreen$SettingsObserver.update
    at org.lineageos.internal.applications.LongScreen$SettingsObserver.observe
    at org.lineageos.internal.applications.LongScreen.<init>
    at org.lineageos.internal.applications.LineageActivityManager.<init>
    at com.android.server.wm.ActivityTaskManagerService.installSystemProviders
    at com.android.server.am.ContentProviderHelper.installSystemProviders
    at com.android.server.SystemServer.startOtherServices
```

**Рабочая гипотеза** (не проверена): `LongScreen` (LineageOS-фича для
notch/aspect-ratio совместимости приложений) обращается к
`LineageSettings`-content-provider'у ВНУТРИ `installSystemProviders()`
-- то есть до того, как сам `LineageSettings`-provider успевает
зарегистрироваться в системе. Гонка при инициализации, похожая по духу
на ЗАДАЧУ 12 (тоже "второй-stage запускается напрямую, минуя часть
обычной последовательности FirstStageMain"), но другой конкретный
компонент.

**Не исследовано**: можно ли отключить `LongScreen`/notch-фичу
LineageOS целиком (она специфична для LineageOS, не нужна для чистого
Droidian/Phosh опыта) вместо попытки почистить саму гонку -- вероятно,
самый быстрый практический путь, если фича не используется.

**Статус**: контейнер остановлен вручную при обнаружении (защита от
перегрева), фикс НЕ применён. Требует отдельного расследования.

## ЗАДАЧА 15 РЕШЕНА: LongScreen crash-loop пропатчен байткодом (2026-07-24)

**Инструменты**: скачаны заново (jadx 1.5.0, apktool 2.9.3, baksmali/smali
3.0.9 -- ВНИМАНИЕ: `JesusFreke/smali` больше не публикует релизы на
GitHub, актуальный репозиторий -- `baksmali/smali`, fat-jar'ы в
releases). Все три инструмента и вся предыдущая живая декомпиляция
(services.jar, org.lineageos.platform.jar) из более раннего момента
этой же сессии физически пропали -- `/tmp` не переживает
зависание/перезагрузку компьютера-хоста (не устройства). Урок: если
понадобится продолжить копать в эту сторону, тулинг придётся качать
заново каждый раз после любого зависания хоста.

**Диагностика**: декомпилированный `LongScreen.java`/`.smali`
подтвердил логику -- конструктор создаёт падающий `SettingsObserver`
ТОЛЬКО если `Resources.getBoolean(config_haveHigherAspectRatioScreen)`
возвращает `true`. НО статическая проверка ресурса (через `aapt2 dump
resources` на извлечённый `org.lineageos.platform-res.apk`) показала
`false` как единственное определение (без квалификаторов, без RRO-
оверлея где-либо в system.img). Причина расхождения между "ресурс
false" и "код всё равно падает" осталась НЕ найдена -- возможно,
что-то в убранном FirstStageMain-пути (снова та же категория багов, что
и ЗАДАЧА 12/16), возможно другой механизм резолва ресурса в этом
сборочном пайплайне. Не стали докапываться до первопричины -- патч
байткода работает независимо от неё.

**Патч**: в `LongScreen.smali`, конструктор `<init>` -- добавлен
безусловный `return-void` СРАЗУ после установки поля
`mLongScreenAvailable`, до проверки `if-nez p1, :cond_1c`. Ветка с
созданием `SettingsObserver` становится недостижимым мёртвым кодом
(валидно для dex-верификатора, падений верификации не было). Это
отключает всю функциональность "long screen app compat" (не
используется в Droidian/Phosh), но полностью убирает крашлуп.

**Пересборка jar (важный технический момент, тот же гоча, что уже был
задокументирован ранее в сессии)**: `zip -j` (update-режим) на этом
конкретном jar'е (нестандартная структура от `soong_zip`) МОЛЧА не
обновляет `classes.dex` внутри архива, хотя `unzip -t` не показывает
ошибок. Обязательна полная переупаковка: `unzip -o -d dir`, замена
`classes.dex`, затем `zip -r -X` С НУЛЯ из `dir`. Проверено сверкой
байт-в-байт размера `classes.dex` внутри нового jar против
самостоятельного файла.

**Живой тест подтвердил фикс**: `init.svc.zygote=running` стабильно,
0 совпадений `LongScreen` в crash-логе (было -- падение каждые ~5с
навсегда), никакого crash-loop процесса `main` в `top`, нагрузка
нормализовалась. Рабочий стол поднялся.

**КРИТИЧЕСКИ ВАЖНО -- нужно было ТАКЖЕ удалить `.odex`/`.vdex`**
(`org.lineageos.platform.odex`/`.vdex` в `system/framework/oat/arm64/`)
после замены jar -- иначе ART использует AOT-скомпилированный кэш от
СТАРОГО байткода, и патч в jar'е физически ничего не меняет в
рантайме, пока кэш не инвалидирован.

**Деплой в v16 (по явной просьбе -- НЕ трогать общий `system.img`-файл,
используемый через симлинк во множестве версий)**: патч применяется
как ИНЪЕКЦИЯ в `update-binary`, СРАЗУ после успешной записи
`system.img` на раздел (`dd if=$RAW_TMP of=$SYSTEM_DEV`), а не правкой
самого файла-источника:
1. Патченный jar лежит в архиве отдельным файлом:
   `halium-extras/system-patches/org.lineageos.platform.jar`.
2. `update-binary` монтирует СВЕЖЕЗАПИСАННЫЙ `$SYSTEM_DEV` (обычный
   `ext4`, не loop -- это уже реальный блочное устройство после `dd`),
   подкладывает патченный jar поверх `system/framework/
   org.lineageos.platform.jar`, удаляет старые `.odex`/`.vdex`,
   синкает и размонтирует.
3. Путь БЕЗ двойной вложенности `system/system/...` -- та вложенность
   (задокументированная раньше в проекте) существует только во
   ВНУТРЕННЕМ view контейнера через `/android/system`-биндмаунт, не в
   самом сыром разделе при прямом монтировании.
4. Если что-то в этой цепочке не сработает (нет `simg2img`, партиция
   не влезает, mount не удался) -- скрипt только предупреждает через
   `ui_print` и продолжает остальную прошивку, не абортит целиком.

## ЗАДАЧА 17 РЕШЕНА (частично): многомесячный баг "phoc теряет seat через ~20с"
## -- обойдён установкой seatd вместо logind-бэкенда (2026-07-24)

**Симптом**: `phosh.service` стабильно запускался, но через ~20 секунд
после старта `phoc` терял связь со своей logind-сессией --
`[libseat] Could not close device: Unknown object '/org/freedesktop/
login1/session/cN'` -- после чего тач и подсветка переставали
отвечать (`Setting backlight ... failed: ... Your session has no
seat, refusing`). Кнопка питания тоже переставала штатно
реагировать. Единственным рабочим лечением был `systemctl restart
phosh.service` -- временно, до следующего повторения бага.

**Расследование, гипотезы проверены и ИСКЛЮЧЕНЫ** (все живьём,
каждая по отдельности):
1. `su - phablet` (login-shell PAM-сессия) в
   `halium-fix-touch-and-unlock.sh`/`halium-disable-lockscreen.sh` --
   заменено на обычный `su` (лишний login-класс сессии убран, это
   правильная правка сама по себе), баг остался идентичным.
2. Нажатия кнопки питания -- один раз совпало по времени
   (`systemd-logind: Power key pressed short` перед разрывом), но
   баг воспроизводился и без единого нажатия.
3. `halium-activate-phosh-seat.sh` -- бесконечный (не ограниченный, в
   отличие от изначального дизайна из "Находки 5" в v2-HOWTO, где
   было 60 попыток по 0.3с) цикл `loginctl activate` 10 раз/сек --
   остановка сервиса не изменила поведение бага. Отдельно найдено:
   сам скрипт уже давно СЛОМАН -- ищет `tty7` в выводе `loginctl
   list-sessions` через `grep`, а этот вывод НЕ содержит колонку TTY
   вообще (только SESSION/UID/USER/SEAT) -- скрипт всё это время был
   no-op, ничего не активировал.
4. `IdleActionSec`/`IdleAction` в logind.conf -- 30 минут, `ignore`,
   не при делах.
5. `halium-watch-camera.sh` (свой собственный `sleep 20` внутри) --
   не срабатывал в окнах разрыва сессии, контейнер вообще не
   перезапускался (`NRestarts=0`).
6. `halium-phosh-watchdog.timer` (`OnUnitActiveSec=30s`) -- интервал
   не совпадает точно, да и сам скрипт не трогает logind/seat вообще
   (только `chmod`/`pgrep`/`ps`).

**Реальный обходной путь (не первопричина, но рабочий)**: `phoc`
всегда сначала пробует `seatd` (`Backend 'seatd' failed to open
seat, skipping` -- сокета `/run/seatd.sock` просто не было, пакет не
стоял) и только потом падает на `logind`. Установлен `seatd`
(0.9.3-1, из репозитория `releases.droidian.org`, та же версия что и
уже стоящий `libseat1` -- на устройстве нет интернета, `.deb`
скачан на хосте и залит через `scp`+`dpkg -i`). `phablet` уже
состоит в группе `video` (владелец `/run/seatd.sock`), доп. группы
не потребовалось. После установки и `systemctl start seatd.service`
+ перезапуска `phosh.service`: `[libseat] Seat opened with backend
'seatd'` -- **живёт больше минуты без единого разрыва**, тач и экран
подтверждены рабочими живьём.

**НЕ найдено**: почему сессия вообще теряет seat при использовании
logind-бэкенда -- это осталось нерешённой первопричиной (см. также
старую "Находку 5" в v2-HOWTO: `Seat=` у PAM-сессии `phosh.service`
пустой даже несмотря на `TTYPath=/dev/tty7` в юните -- то есть
systemd почему-то не прокидывает TTY-привязку в PAM/logind для
сервисов с `User=`+`PAMName=login`+`TTYPath=`, это тот же самый
многолетний баг). `seatd` просто обходит его стороной, не решая.

**Побочная регрессия от переключения на `seatd`**: сам `phosh`
(не `phoc`) регулирует яркость через прямой D-Bus вызов
`org.freedesktop.login1.Session.SetBrightness` -- в обход
`libseat`. Раз сессия больше не привязана к logind-сиденью,
этот вызов получает `NotYourDevice: Your session has no seat,
refusing`. Слайдер яркости в Phosh не работает. Ручной sysfs-write
подтверждён рабочим (`echo N > /sys/class/backlight/panel0-backlight/
brightness`, права уже `phablet:phablet`) -- воркэраунд для
пользователя на время, реальный фикс (либо чинить seat-assignment
для logind-сессии целиком, либо перехватывать вызов яркости) --
отдельная задача, не в этой сессии.

**Закреплено в v18**: реальные файлы пакета (не через `dpkg` при
прошивке -- на устройстве нет интернета, без сети пакет не
установится) -- `usr/sbin/seatd`, `usr/bin/seatd-launch`,
`usr/lib/systemd/system/seatd.service`, `etc/default/seatd` +
симлинк `etc/systemd/system/multi-user.target.wants/seatd.service`
в `halium-extras/rootfs-files/`. Архив ещё не пересобран с этим
изменением -- следующий шаг.
