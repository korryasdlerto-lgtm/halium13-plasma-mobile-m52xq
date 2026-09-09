# v21 — исправление звука

## Суть проблемы
PipeWire не мог получить звук, потому что реальный Qualcomm audio HAL
для этого чипа (`audio.primary.lahaina.so`, `/vendor/lib/hw/`) существует
**только в 32-битной сборке**. 64-битная версия в `/vendor/lib64/hw/` —
это `audio.primary.default.so`, пустая AOSP-заглушка, которая сегфолтит
при попытке реально открыть поток.

## Решение
Классическая для Halium/Droidian схема на таком железе: полный
droidian-родной **PulseAudio** (не PipeWire) + `pulseaudio-modules-droid-modern`
в **32-битной (armhf)** сборке, запускаемый параллельно с обычным
64-битным (arm64) хостом через Debian multiarch.

- Снесены `pipewire-audio`/`pipewire-alsa` (конфликтуют с pulseaudio на
  уровне apt). Побочный эффект: ушли `gnome-control-center` и
  `gnome-settings-daemon` (тянулись как зависимости) — возвращены отдельно
  (чистая установка, deps уже удовлетворены остальным стеком).
- Добавлена архитектура armhf, установлен полный transitive-closure
  droidian-стек (292 .deb: ядро arm64 + новый armhf +
  gnome-control-center/gnome-settings-daemon) —
  `halium-extras/rootfs-files/usr/local/lib/halium-audio-fix-debs/`.
- `HYBRIS_LD_LIBRARY_PATH` для 32-битного pulseaudio должен указывать на
  `/system/lib/bootstrap:/system/lib:/vendor/lib` — НЕ на
  `/opt/halium-lxc-bridge/*-lib64` (это 64-битные копии, для 32-битного
  процесса дают "is 64-bit instead of 32-bit"). `/system/lib/libc.so` сам
  по себе — битый symlink на APEX-путь, которого нет на хосте; реальная
  bootstrap-копия лежит в `/system/lib/bootstrap/libc.so`.
- `pulseaudio.service` по умолчанию имеет `SystemCallArchitectures=native`
  — это КИЛЛЕР для 32-битного ARM-процесса на aarch64 (SIGSYS сразу же,
  за 2мс). Дропин `zz-droid-modern-32bit.conf` сбрасывает это и прочую
  systemd-песочницу (`NoNewPrivileges`, `LockPersonality`,
  `MemoryDenyWriteExecute`, `RestrictNamespaces`), которая тоже мешает
  hybris-мосту.
- `/etc/pulse/default.pa`: добавлена строка `load-module module-droid-card`.
- Установка происходит один раз при первой загрузке через
  `/usr/libexec/halium-install-audio-fix.sh`, вызываемый из уже
  проверенного `halium-restore-state.sh` (идемпотентно, маркер
  `/var/lib/halium-audio-fix-done`).

## Подтверждено живьём
Пользователь услышал тестовый тон (440 Гц) через `sink.primary_output` и
`sink.fast`. `pulseaudio.service` стабильно `active (running)` через
штатный systemd (не костыль вручную).

## Авария после первой живой перезагрузки (2026-07-25) и что вскрылось

Массовая установка ~290 пакетов через `dpkg -i` НА УЖЕ ЗАГРУЖЕННОЙ
overlayfs-системе (upper=`/data/rootfs-overlay`, lower=`rootfs.img`)
превратила ~50 файлов (включая `libhybris-common.so.1`, `/etc/pulse/default.pa`,
собственный systemd drop-in) в overlayfs "whiteout" character-device-заглушки
или вовсе стёрла их. Итог — `getprop`/`bluebinder`/`phosh` не могли
загрузить общие библиотеки, бутлуп. Точная причина взаимодействия
dpkg+overlayfs не установлена, чинилось вручную через TWRP (loop-mount
`rootfs.img`, сверка с оригиналом, удаление whiteout-нод, восстановление
недостающих файлов из уже скачанных .deb).

**Исправлено в v21**: установка пакетов перенесена в `update-binary` —
CHROOT ПРЯМО В `rootfs.img` НА ЭТАПЕ ПРОШИВКИ, пока overlay ещё не
задействован (rootfs.img в этот момент обычный ext4). Это полностью
исключает overlayfs из уравнения. `halium-install-audio-fix.sh` (boot-time)
остаётся как fallback на случай, если TWRP не поддерживает chroot — но
в норме должен быть no-op, поскольку chroot-путь удаляет каталог с .deb
после успешной установки.

Также вскрылось и исправлено:
- `pulseaudio.service` с `Type=notify` (из юнита) никогда не получает
  sd_notify от этой сборки демона → systemd ждёт `TimeoutStartSec` (90с) и
  убивает УЖЕ РАБОЧИЙ процесс. Фикс: `Type=simple` в дропине.
- `pipewire-pulse.socket` (сам pipewire-pulse НЕ удалялся, только
  `-audio`/`-alsa`) слушает тот же путь `/run/user/1000/pulse/native` и
  включён по умолчанию — побеждает гонку за сокет, наш `pulseaudio.socket`
  никогда не триггерится. Фикс: маскируем pipewire-pulse юниты, явно
  enable'им pulseaudio.socket.
- `gnome-control-center`/`gnome-settings-daemon` зависят от pipewire-audio
  → `dpkg -r` без явного указания их первыми откажет. В chroot-скрипте
  явно сносятся вместе с pipewire-audio/-alsa, затем переустанавливаются
  вместе с остальным набором.

## TODO перед сборкой архива
- [ ] Прогнать v21 через РЕАЛЬНУЮ прошивку (Format Data → flash → первая
      загрузка) — chroot-путь установки НИ РАЗУ не тестировался живьём,
      только live dpkg-путь (который и вызвал аварию) был проверен на
      реальном устройстве.
- [ ] Разобраться с пропавшей регулировкой громкости в Phosh quick-settings
      (звук в приложениях работает, виджет громкости — нет; вероятно
      рассчитан на PipeWire/WirePlumber, а не на классический PulseAudio).
- [ ] Собирать архив только по отдельной явной команде (без автозапуска).
