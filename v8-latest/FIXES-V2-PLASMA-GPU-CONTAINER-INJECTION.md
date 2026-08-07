# Фиксы в2 (2026-07-29): перенос из в3 + инъекция plasma-mobile-wf в update-binary

Контекст: в3 использовался для живой отладки zygote/system_server/GPU-цепочки
(см. FIXES-V3-ZYGOTE-SYSTEM-SERVER-CHAIN.md), но по пути потерял несколько
уже готовых фиксов из в1/в2 (seatd-пакет, аудио-стек, зрелый гейт контейнера
CONTAINER_ENABLED). в2 взят как база (аудио + гейт уже рабочие), в3-находки
перенесены точечно.

## 1. mount-patched-v3.sh / var/lib/lxc/android/mount.sh — заменены целиком

Живая версия стянута прямо с устройства через adb pull /data/mount-patched-v3.sh
(в TWRP), а не взята из исходников в3 -- собственная копия mount.sh в3
на хосте оказалась ХУЖЕ живой версии на устройстве (там жили ещё правки,
никогда не сохранённые обратно в git/исходники). Отличия от прежней в2
версии:

- **Продвинутый a660_zap-фикс** (было: простой overlay с lowerdir, стало:
  tmpfs-staging + прямая подстановка байт из firmware_mnt + ТРЕТИЙ путь
  поиска ядра `${R}/firmware/image/a660_zap.*`, обходящий гонку с sysfs
  fallback, на которой стабильно проигрывал a660_zap.b02).
- **Заглушка контейнерного surfaceflinger** (`while true; do sleep 3600;
  done` вместо реального бинаря) -- контейнерный surfaceflinger падал на
  a660_zap.b02 ДО того, как успевал сработать halium-bounce-composer.sh,
  роняя всю систему через hardware watchdog. `exit 0` вместо sleep-loop
  НЕ подходит -- surfaceflinger.rc триггерит `onrestart restart
  --only-if-running zygote`, каскадно убивая zygote при каждом "быстром"
  завершении скрипта.
- Безусловное создание заглушки `${R}/system/build.prop` (было: только
  если существующий файл -- симлинк; live-тест показал что файла может
  не быть вообще, ни в каком виде).

`var/lib/lxc/android/mount.sh` получил тот же live-контент ПЛЮС отдельный
блок "on nonencrypted" (реальное удаление триггера mount_all/on
nonencrypted из init.rc), которого нет в mount-patched-v3.sh -- это
устоявшееся расхождение между двумя копиями файла, сохранено как было.

## 2. halium-gpu-bridge-setup.sh — добавлен host-side a660_zap фикс

wayfire (хостовый компоситор plasma-mobile-wf) триггерит РЕАЛЬНУЮ
загрузку a660_zap-прошивки ядром на хостовой стороне (то же самое, что
делает контейнерный surfaceflinger) -- контейнерный фикс из mount.sh
невидим хосту (namespace-local tmpfs). Добавлен тот же паттерн для
хоста: overlay tmpfs на `/vendor/firmware` с реальными байтами
+ третий путь `/firmware/image/`, с ожиданием готовности
`/android/system/vendor/firmware_mnt/image` (гонка с контейнерным mount
hook на холодном старте).

## 3. update-binary — инъекция фиксов plasma-mobile-wf.service.d

plasma-mobile-wf.service и его дропины зашиты прямо в общий (шаренный
между в1/в2/в3 через симлинк) rootfs.img, а не в halium-extras/
rootfs-files -- поэтому единственное место, где можно зашить фикс без
правки самого мастер-образа -- inject прямо в update-binary, в момент
когда rootfs.img уже смонтирован как $ROOTFS_MNT (rw, реальный ext4, до
упаковки чанками).

Три фикса, найденные живьём 2026-07-29 (см. память проекта
project_plasma_mobile_wf_gpu_compositor):

1. **HYBRIS_LD_LIBRARY_PATH/LD_LIBRARY_PATH/ANDROID_ROOT + ExecStartPre=
   halium-gpu-bridge-setup.sh** -- без этого wayfire мгновенно
   segfault'ится (`library "libhwc2_compat_layer.so" not found`).
2. **Отключение `50-chvt.conf`** (`ExecStartPost=+chvt 7`) -- гонка с
   systemd'овским TTYVHangup/TTYReset на TTYPath убивает только что
   запущенный процесс SIGHUP'ом за ~100-150мс, ДО единой строчки
   вывода. phosh.service (тот же TTYPath-конфиг) вообще не имеет
   chvt-дропина -- systemd сам активирует VT через TTYPath.
3. **Ослабление `40-droid-wait.conf`** (`BindsTo=android-service@
   hwcomposer.service` убран, оставлены только Requires+After) --
   BindsTo слишком жёсткий: любое кратковременное мигание hwcomposer
   (контейнер сам иногда нестабилен) тут же валит plasma-mobile-wf
   вслед за собой. Пустой `BindsTo=` оверрайд в отдельном дропине НЕ
   сработал живьём (осталась причина неясна) -- реально сработало
   только физическое перемещение исходного файла в сторону
   (`.disabled`) с заменой на новый файл без BindsTo. В update-binary
   сделано так же: `mv` оригинальных 50-chvt.conf/40-droid-wait.conf
   на `.disabled` внутри примонтированного $ROOTFS_MNT, новые файлы --
   в $ROOTFS_MNT/etc/systemd/system/plasma-mobile-wf.service.d/.

Проверено вручную на устройстве (не в архиве, live-патчами) 2026-07-29:
с этими тремя фиксами + seatd wayfire реально доходит до `GL renderer:
Adreno (TM) 642L`, реального HWCOMPOSER-1 output 1080x2400, полной
сессии plasma-mobile (feedbackd, evolution-data-server, gnome-calls,
KDE ActivityManager). Не решено (открыто для следующей сессии):
`plasmashell` не рисует видимого окна конкретно под этим systemd-юнитом
(процесс живой, не падает, но нет видимого surface в логе wayfire) --
Qt/QML-специфичная проблема, ещё не диагностирована до конца.

## 4. firmware/boot.img — исправлен битый симлинк

`Дроидиан/v23/firmware/boot.img` (шарится между в1 и в2) указывал
неверным относительным путём (`../../droidian-boot-v13-watchdog-
timeout.img`, метил мимо реального файла). Файл этот -- экспериментальный
boot с увеличенным watchdog-таймаутом (отдельная незавершённая задача,
не для этой прошивки). Переуказан на `../../droidian-boot-v12-
nosafesetid.img` -- тот же boot, что уже проверенно работает в в3.zip
(размер совпадает: 49860608 байт).

## Контейнер по-прежнему выключен по умолчанию

Никаких изменений в CONTAINER_ENABLED-гейте не делалось -- он и так уже
сбрасывается на каждой прошивке (`rm -f /data/CONTAINER_ENABLED` в
update-binary). Единственный ручной шаг после прошивки --
`halium-enable-container.sh`, всё остальное (включая GPU/plasma-фиксы
выше) должно быть готово сразу.
