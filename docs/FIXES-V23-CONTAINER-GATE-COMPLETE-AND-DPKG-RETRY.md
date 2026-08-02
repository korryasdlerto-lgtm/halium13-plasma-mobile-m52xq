# v23: полное перекрытие всех путей запуска контейнера + фикс dpkg-порядка (2026-07-27)

## Контекст
Первый живой тест v22 (гейт `PHOSH_FIRST_BOOT_OK` + 55с-таймер + PATH-фикс
для chroot) показал две проблемы.

## Проблема 1: гейт контейнера покрывал не все пути

Диагностика зависшей первой загрузки v22 (TWRP, pstore) показала, что
Android-контейнер всё равно стартовал ДО срабатывания 55с-таймера
(`/userdata/PHOSH_FIRST_BOOT_OK` не существовал, но `init` контейнера уже
работал в pstore-логе).

**Причина**: гейт из v22 был реализован ТОЛЬКО в `halium-restore-
state.sh`, который создаёт (или не создаёт) юниты `halium-start-
container-delayed.service`/`.timer`. Но как минимум **9 других юнитов**
самостоятельно объявляют `Wants=`/`Requires=lxc-android-config.service`
в СВОИХ СОБСТВЕННЫХ `[Unit]`-секциях (все enabled по умолчанию через
`multi-user.target.wants`):
- halium-sensor-bridge-watchdog.service
- halium-fix-backlight-perm.service
- halium-fix-torch-perm.service
- halium-install-sensor-bridge.service
- halium-stop-fps-spam.service
- halium-start-adbd.service
- halium-fix-crashdump-storm.service
- halium-fix-flash-perm.service
- (9-й, найден через `grep -l` count, не выписан поимённо)

Любой из них, стартуя на раннем этапе загрузки, тянул за собой
`lxc-android-config.service` независимо от моего таймера -- гейт
покрывал только ОДИН из множества путей.

**Исправление**: вместо патчинга каждого из 9+ юнитов по отдельности --
единая точка контроля прямо на самом `lxc-android-config.service`:

`halium-extras/rootfs-files/etc/systemd/system/lxc-android-config.
service.d/00-first-boot-gate.conf`:
```ini
[Unit]
ConditionPathExists=/userdata/PHOSH_FIRST_BOOT_OK
```

`ConditionPathExists` проверяется systemd'ом заново при КАЖДОЙ попытке
запуска юнита (не кэшируется) -- независимо от того, кто и как его
запрашивает (явный `systemctl start`, `Wants=`, `Requires=`, таймер).
Пока файла нет, systemd просто пропускает юнит (считает "successfully
skipped", не ошибкой) при любой попытке. Как только 55с-таймер создаёт
маркер -- следующая ЛЮБАЯ попытка запуска (в том же боте или в любом
следующем) проходит нормально. Ограничение действует строго один раз,
на первую загрузку после переflash-а -- ни один из юнитов НЕ требует
отдельного патчинга.

Проверено: конфликтов с уже существующими дроп-инами в этой же папке
(`98-restart-on-failure.conf`, `99-wait-for-ssh.conf`, `override.conf`)
нет -- ни один из них не трогает `Condition*=`.

(По пути также проверены и признаны тупиковыми: `halium-kickstart-
lxc.sh` -- существует, но нигде реально не вызывается ни одним
enabled-юнитом; `halium-lxc-uptime-restart.service` -- его enable-
строка в `update-binary` закомментирована.)

## Проблема 2: dpkg pre-dependency ordering в chroot-установке

См. `FIXES-V22...` -- нет, отдельно задокументировано здесь: PATH-фикс
из v22 сработал (`exit 127` -> `exit 1`), но обнажил вторую проблему --
`libexpat1:armhf` pre-depends на `libc6 (>= 2.38)`, но `libc6:armhf` к
моменту установки `libexpat1` был "unpacked, but has never been
configured" (единственный проход `dpkg -i *.deb` без топологической
сортировки). Каскад: `libexpat1` отклонён целиком -> `fontconfig` ->
`cairo` -> `pango` -> `gdk-pixbuf` -> `pulseaudio-modules-droid` ->
`pulseaudio` -> `gnome-settings-daemon` -> `gnome-control-center` -- все
"leaving unconfigured".

**Исправление** (в `update-binary` и в live-fallback `halium-install-
audio-fix.sh`): повторный проход `dpkg -i --force-confold .../*.deb`
СРАЗУ ПОСЛЕ первого `dpkg --configure -a`, до дополнительных configure:
```sh
dpkg -i --force-confold /usr/local/lib/halium-audio-fix-debs/*.deb 2>&1
dpkg --configure -a 2>&1
dpkg -i --force-confold /usr/local/lib/halium-audio-fix-debs/*.deb 2>&1
dpkg --configure -a 2>&1
dpkg --configure -a 2>&1
```
На втором проходе `libc6:armhf` уже сконфигурирован (первым
`--configure -a`), ранее отклонённые пакеты встают нормально.

## Статус
Оба фикса синтаксически проверены (`sh -n` для shell-скриптов; .conf --
проверен визуально + отсутствие конфликтов с соседними дроп-инами).
**НЕ протестировано живьём** -- следующий flash v23 будет первым тестом
разом всех трёх фиксов (chroot-PATH из v22 + dpkg-retry + полный
container-gate).
