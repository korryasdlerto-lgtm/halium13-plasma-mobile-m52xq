# План следующих шагов (в9)

## Шаг 1 (в процессе): чистая пересборка Plasma в текущем rootfs
Удаление накопившегося GNOME-стека (gnome-session, gnome-control-center,
evolution-data-server, nautilus, rygel, tecla, gnome-keyring,
xdg-desktop-portal-gtk, megapixels и т.д. — почти 100 пакетов), который
достался в наследство от базового Droidian/Phosh rootfs и никогда не
удалялся. PipeWire-стек (pipewire/pipewire-audio/pipewire-alsa/
wireplumber) явно защищён от автоудаления (`apt-mark manual`) — он
единственный источник звука на этом образе, PulseAudio-демона тут нет.

## Шаг 2 (СЛЕДУЮЩИЙ, после проверки шага 1): звук не работает — портировать фикс из Droidian
На этом rootfs звук физически не идёт (то же самое, что было у
Droidian до v21). Причина та же: реальный Android audio HAL
(`audio.primary.lahaina.so`) существует только в **32-битной** сборке,
64-битный `/vendor/lib64/hw/audio.primary.default.so` — пустышка
(AOSP stub, сегфолтится). PipeWire сам по себе с этим не работает.

Droidian-фикс (см. `/home/sasha/Templates/Дроидиан/v38!!!!!/`, история
"v21: PulseAudio (не PipeWire) + 32-битный armhf audio bridge" в README
droidian-phosh-m52xq): полный переход на **PulseAudio** (не PipeWire) +
`pulseaudio-modules-droid-modern` в **armhf** через мультиарх, ~296
`.deb`-пакетов (armhf+arm64) уже собраны и лежат в
`halium-extras/rootfs-files/usr/local/lib/halium-audio-fix-debs/` —
можно переиспользовать напрямую, не пересобирать заново.

Важные детали оттуда, которые придётся повторить и здесь:
- `HYBRIS_LD_LIBRARY_PATH` для 32-битного процесса должен указывать на
  `/system/lib/bootstrap:/system/lib:/vendor/lib` (НЕ 64-битные пути
  моста).
- `pulseaudio.service`'s `SystemCallArchitectures=native` убивает
  32-битные ARM-процессы на aarch64 мгновенным SIGSYS — снимать
  дропином вместе с прочим systemd-sandboxing
  (`NoNewPrivileges`/`LockPersonality`/`MemoryDenyWriteExecute`/
  `RestrictNamespaces`).
- `Type=notify` у `pulseaudio.service` не получает `sd_notify` на этой
  сборке -- менять на `Type=simple`.
- Здесь придётся ДОПОЛНИТЕЛЬНО убрать/замаскировать весь PipeWire
  (`pipewire-pulse.socket` особенно — занимает тот же нативный сокет),
  раз этот rootfs (в отличие от чистого Droidian) начинал именно с
  PipeWire, а не с чистого листа.
- Пакеты ставить ТОЛЬКО через chroot до создания overlay (не через
  `dpkg -i` на уже загруженной overlayfs-системе) -- иначе повторится
  "overlayfs whiteout corruption" баг, найденный в Droidian v21.

**Делать отдельно от шага 1**, не одновременно — чтобы при поломке
понимать, какое именно изменение виновато.
