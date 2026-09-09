# в2: перенос фиксов аудио и постоянной блокировки контейнера из v25 (2026-07-28)

## Контекст
`в2` — копия `в1` (первый живой тест Plasma Mobile, флеш прошёл успешно,
3 чанка по 4ГБ отработали без OOM). В `в2` перенесены два фикса,
параллельно найденные и обкатанные в основной Droidian-ветке (v25),
но ещё не примененные к Plasma-образу.

## Фикс 1: недостающий arm64-пакет pulseaudio-modules-droid-modern
`halium-extras/rootfs-files/usr/local/lib/halium-audio-fix-debs/`
изначально содержал только armhf-сборку этого пакета -- arm64-пакет
`pulseaudio-modules-droid-hidl` (arm64) не мог закрыть свою
OR-зависимость `pulseaudio-modules-droid-jb2q | pulseaudio-modules-
droid-modern`. Добавлена arm64-сборка той же версии (скачана и
сверена по SHA256 с releases.droidian.org). Также добавлен
`--force-overwrite` к `dpkg -i --force-confold` (и в update-binary, и
в live-fallback `halium-install-audio-fix.sh`) -- фикс конфликта
`libasound2-plugins:arm64`/`:armhf` (разное содержимое общего
`/etc/alsa/conf.d/99-pulseaudio-default.conf.example`).

## Фикс 2: постоянная блокировка автостарта контейнера
Контейнер (`lxc-android-config.service`) теперь НИКОГДА не стартует
сам -- ни по таймеру, ни по задержке:
- `lxc-android-config.service.d/00-first-boot-gate.conf`:
  `ConditionPathExists=/userdata/CONTAINER_ENABLED` (маркер никогда не
  создаётся автоматически).
- `halium-extras/libexec/halium-enable-container.sh` (новый): ручной
  запуск по ssh (`touch /userdata/CONTAINER_ENABLED && systemctl start
  lxc-android-config.service`).
- `halium-restore-state.sh`: убран весь if/else гейт по
  `PHOSH_FIRST_BOOT_OK` -- теперь безусловно создаёт обычный
  `halium-start-container-delayed.service/.timer` каждую загрузку.
  Удалён устаревший `halium-first-boot-container-start.sh`.
- `update-binary`: `ln -sf /dev/null` для `halium-start-container-
  delayed.service/.timer` прямо в образе (доп. защита, переживает
  перезапись со стороны restore-state.sh) + `rm -f /data/
  CONTAINER_ENABLED /data/PHOSH_FIRST_BOOT_OK /data/halium-first-boot-
  gate.log` при каждом флеше.

Подробности обоих фиксов и почему предыдущие попытки (v22/v23/v24)
не сработали -- см. `Дроидиан/v25/FIXES-V25-MISSING-DROID-MODERN-
ARM64.md`.

## Статус
Оба фикса синтаксически проверены (`sh -n`), символьных ссылок не
сломано (`find -xtype l` -- пусто). **НЕ протестировано живьём.**
