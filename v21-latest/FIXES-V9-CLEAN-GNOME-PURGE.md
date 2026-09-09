# в9: чистка накопившегося GNOME-хвоста из общего rootfs.img

## Проблема
Этот проект форкнут от Droidian/Phosh (общий базовый rootfs.img с
Droidian v23, см. `DROIDIAN-V23-PLAN.md` в каждой версии) — и весь
исходный GNOME-стек (`gnome-session`, `gnome-control-center`,
`evolution-data-server`, `nautilus`, `rygel`, `tecla`, `gnome-keyring`,
`xdg-desktop-portal-gtk`, `megapixels` и т.д. — 329 пакетов) так и
остался установленным рядом с Plasma все эти версии, никогда не
удалялся. Два потенциальных источника конфликтов оттуда:
`xdg-desktop-portal-gtk` конкурировал с `xdg-desktop-portal-kde` за
portal-бэкенд, `gnome-keyring` мог конфликтовать с `kwallet6` за
секрет-хранилище на этапе PAM-логина.

## Что сделано
Рабочая копия общего `rootfs.img` пересобрана заново из ЧИСТЫХ (не
scratch, актуальных) чанков `rootfs-chunks/`, смонтирована через
`losetup`+`chroot`+`qemu-aarch64-static` (методика та же, что и для
milou/plasma-dialer сборок в июле).

`apt-get purge --autoremove` на 39 явных пакетах + автоудаление их
хвостов = 329 пакетов итого. **Перед этим явно защищены** от
автоудаления (`apt-mark manual`) — весь PipeWire-стек
(`pipewire`/`pipewire-audio`/`pipewire-alsa`/`pipewire-pulse`/
`wireplumber`/`libpipewire-*`/`libspa-*`) — единственный источник
звука на этом образе (PulseAudio-демона тут нет вообще), рюгель тянул
их через Recommends и чуть не утащил автоудалением. Проверено
`dpkg --audit`+`apt-get check` после чистки — база пакетов целая, ничего
не сломано.

Отдельно (не через apt, эти два никогда не были настоящими deb-пакетами,
а копировались файлами напрямую в `halium-extras/rootfs-files/` в
июльской в5-сессии): удалены **Kalk** (калькулятор) и **Koko**
(галерея) — все их файлы (бинарники, .desktop, локали, иконки,
appdata) вычищены из `halium-extras/rootfs-files/` вручную.

**Оставлено намеренно:**
- `plasma-dialer` (телефония) — НЕ факультативный пакет, `org.kde.
  telephony` жёстко требуется `WayfireTweaks.qml` для домашнего
  экрана (см. `FIXES-V5-TELEPHONY-CALC-GALLERY-ROOTFS-REBUILD.md`),
  без него весь homescreen падает с QML-ошибкой.
- `plasma-mobile-wf` как есть, вместо стокового мета-пакета
  `plasma-mobile` — **проверено dry-run'ом**: установка стокового
  `plasma-mobile` УДАЛИЛА БЫ `plasma-mobile-wf`+
  `plasma-mobile-wf-config-hwcomposer`+`droidian-quirks-plamo-wf`, так
  как стоковый пакет тянет `plasma-nano` (обычный kwin-only шелл без
  wayfire). `plasma-mobile-wf` выбран изначально СПЕЦИАЛЬНО (см. README
  соседнего репо `halium13-plasma-mobile-m52xq`) — только у wayfire
  есть рабочий `hwcomposer`/hybris-EGL бэкенд для Android GPU-драйвера
  через мост; обычный KWin standalone так не умеет. Установка
  стокового пакета снесла бы всю GPU-акселерацию.
- `megapixels`/`libmegapixels1` ("камера пиксель") — удалены по прямому
  запросу; **важно**: родного KDE-приложения камеры не существует
  вообще, Megapixels — межDE-стандарт для этой ниши на всём мобильном
  Linux (postmarketOS, Droidian и т.д.). После этой чистки на устройстве
  нет камеры вообще никакой. Если понадобится обратно — только
  Megapixels, альтернативы нет.

## Результат
- 1861 пакет осталось (было 2195, минус 334 net с учётом каскада).
- `dpkg --audit` / `apt-get check` — чисто.
- Новый rootfs.img пересобран заново, разрезан на новые чанки:
  `../../rootfs-chunks-v9-clean/rootfs.img.part-{0,1,2}` (4ГБ каждый).
  **в9 больше НЕ делит общий rootfs.img с в1-в8** — `data/rootfs-chunks/`
  теперь указывает на эти новые чанки, а не на старые общие.
- Шрифты проверены отдельно (не источник проблемы): `fonts-noto` полный
  набор, `fc-match` резолвит корректно.

## НЕ проверено живьём
Эта чистка ещё не флешилась/не тестировалась на реальном устройстве —
это первый живой тест именно очищенного образа.

## Следующий шаг (см. `PLAN-NEXT-STEPS.md`)
Звук на этом образе не работает (тот же 32-бит HAL баг, что был у
Droidian до v21) — портировать PulseAudio+droid-modules-armhf фикс
отдельным шагом, не одновременно с этой правкой.
