# в12: реальный фикс звука (module-droid-card) + вачдог убран целиком

## Контекст
В12 стал возможен только благодаря живому root-доступу на в11 вечером
2026-09-07 (`su` с паролем `0000` — `sudo`/`ssh root@`/`systemctl` от
`phablet` не работали весь вечер, "Interactive authentication
required"). Через `su` наконец получилось не только диагностировать,
но и живьём протестировать фиксы, прежде чем закреплять их в файлах
образа.

## ВАЖНОЕ АРХИТЕКТУРНОЕ ОТКРЫТИЕ: `/` — это tmpfs-оверлей
`/` монтируется как `overlay (…,upperdir=/tmpmnt/rootfs-overlay,
workdir=/tmpmnt/rootfs-overlay-workdir)`. `/tmpmnt` — **tmpfs**
(оперативная память). Значит ЛЮБАЯ живая правка файла где-либо под
`/` (через `su`, `sed -i`, что угодно) переживает только до
СЛЕДУЮЩЕЙ перезагрузки — после ребута upper-слой снова девственно
пуст, все правки исчезают целиком, даже если сам ребут "чистый" и `/`
монтируется `rw` с самого начала. Подтверждено живьём: правки
`default.pa` и `zz-droid-modern-32bit.conf`, сделанные через `su` на
предыдущей загрузке, полностью откатились после того, как
crash-loop pulseaudio уронил систему и она сама перезагрузилась.
**Практический вывод на будущее**: любой "живой" SSH-фикс — это
ТОЛЬКО черновик для проверки гипотезы. Закрепить можно исключительно
через файлы в `halium-extras/rootfs-files/` (копируются
`update-binary` при флеше в постоянный `/halium-system`) — то, что
этот проект и так делал правильно с самого начала, просто сегодня
это было доказано на практике, а не предположено.

## Проблема 1 — звука реально не было: `module-droid-card` не грузился вообще
`pactl list modules short` не показывал `module-droid-card` ни разу —
пакеты `pulseaudio-modules-droid-modern`/`-hidl` были поставлены ещё
в в10, но саму строку `load-module module-droid-card` никто не добавил
в `/etc/pulse/default.pa` (стоковый Debian-файл этого пакета никогда
не патчился под droid). PulseAudio исправно работал, но всегда падал
на `module-always-sink`'s `auto_null` — заглушку.

### Что сделано
Новый overlay-файл `halium-extras/rootfs-files/etc/pulse/default.pa` —
полная копия стокового файла + одна добавленная строка в самом низу:
```
load-module module-droid-card config=/etc/pulse/halium-overrides/audio_policy_configuration.xml
```
Аргумент `config=` обязателен явно (не через переменную
`PULSE_MODULES_DROID_EXTRA_CARD_ARGS`, см. Проблему 2) — иначе
модуль читает непатченый `/vendor/etc/audio_policy_configuration.xml`
и падает с "We only support audioPolicyConfiguration version 1.0"
(см. `FIXES-V21-AUDIO.md` — уже была известная причина, просто
обходной путь для неё не был реально подключён).

## Проблема 2 — НОВАЯ, найдена только сегодня: `zz-droid-modern-32bit.conf` перезаписывал правильный конфиг
Первая попытка добавить `load-module module-droid-card` (без явного
`config=`) заканчивалась мгновенным `SIGSEGV` на каждом старте
pulseaudio (счётчик рестартов рос бесконечно, `Start request repeated
too quickly` в итоге). Причина в логе: `"/system/lib/libhardware.so"
is 32-bit instead of 64-bit`.

Файл `zz-droid-modern-32bit.conf` (под
`etc/systemd/user/pulseaudio.service.d/`) скопирован с Droidian
verbatim ещё в в10 и содержал 4 строки `Environment=`, конфликтующие
с правильными значениями из `ubuntu-touch.conf` (под
`usr/lib/systemd/user/pulseaudio.service.d/`). Systemd применяет
дропины по алфавиту вне зависимости от директории-источника —
`ubuntu-touch.conf` (u) раньше `zz-droid-modern-32bit.conf` (z),
значит именно `zz-...` выигрывал:
- `HYBRIS_LD_LIBRARY_PATH=/system/lib/bootstrap:/system/lib:/vendor/lib`
  — droidian-путь (сырые 32-битные Android-либы), а не путь моста
  этого проекта (`/opt/halium-lxc-bridge/system-lib64:/opt/halium-lxc-
  bridge/vendor-lib64` из `ubuntu-touch.conf`) — отсюда 32/64-битный
  конфликт и `SIGSEGV`.
- `LD_PRELOAD=` (пусто) — затирал `LD_PRELOAD=libtls-padding.so`.
- `PULSE_MODULES_DROID_EXTRA_CARD_ARGS=` (пусто) — затирал
  `config=/etc/pulse/halium-overrides/audio_policy_configuration.xml`
  — вторая, независимая причина падения (см. Проблему 1).

### Что сделано
Все 4 конфликтующие строки `Environment=` удалены из
`zz-droid-modern-32bit.conf` — остались только легитимные
хардненинг-снятия (`Type=simple`, `LockPersonality=no` и т.п.), ничем
не перекрывающие `ubuntu-touch.conf`.

### Дополнительно выяснено (не фиксилось, просто зафиксировано)
`PULSE_MODULES_DROID_EXTRA_CARD_ARGS` в этом Debian-рутфс — мёртвая
переменная в принципе: её механизм подстановки в оригинальном Ubuntu
Touch (`PULSE_SCRIPT=/etc/pulse/touch.pa` +
`ExecStartPre=.../get_pa_modules_droid_extra_args`) сознательно не
портирован при переходе на Debian+Phosh (см. собственный комментарий
в `ubuntu-touch.conf` от 2026-07-17). Поэтому `config=` аргумент
прописан в в12 прямо в `default.pa`, а не через переменную.

## Проблема 3 — вачдог `halium-plasma-shell-watchdog` УБРАН ЦЕЛИКОМ
Живой инцидент вечером 2026-09-07: даже с добавленным в в11
грейс-периодом (25с) вачдог всё равно поймал легитимный, ещё не
завершившийся старт shell (`wayfire` возраст 26с — на секунду больше
грейс-периода) и убил только что появившийся рабочий стол. По прямому
запросу пользователя вачдог убран из проекта целиком, а не
перенастроен на большее число:
- удалены `halium-extras/libexec/halium-plasma-shell-watchdog.sh`,
  `halium-extras/units/halium-plasma-shell-watchdog.{timer,service}`;
- убран блок в `update-binary`, который включал таймер
  (`ln -sf .../halium-plasma-shell-watchdog.timer .../timers.target.wants/`).

Живьём на в11 отключение вачдога (`systemctl disable` +
`rm .../timers.target.wants/...`) сразу дало стабильный,
незакрывающийся сам собой рабочий стол — `plasma-mobile-wf.service`
и так имеет `Restart=always`/`RestartSec=5s` на случай РЕАЛЬНОГО
краша, отдельный вачдог поверх него оказался источником проблем
чаще, чем решением.

**Не убраны** (не относятся к сегодняшнему инциденту, не трогались):
`halium-fix-plasmashell-icons` (другой, гоночный баг Kirigami.Icon,
раньше найденный) и `halium-phosh-watchdog` (мёртвый код, ищет
несуществующие в этом проекте `/usr/bin/phoc`/`/usr/libexec/phosh`,
безвредный no-op).

## Из в11 без изменений
ro-root авто-фикс в `halium-container-autostart.sh` — работает,
подтверждён живьём несколько раз за вечер (`/` поднимается `rw` либо
чинится автоматически). Не трогался.

## НЕ проверено живьём после закрепления в файлах
Обе правки (`default.pa`, `zz-droid-modern-32bit.conf`) протестированы
ТОЛЬКО как живые SSH-правки на в11 (звук через `pactl` не успели
довести до конца до того, как pulseaudio ушёл в CPU-прожорливый
рестарт-цикл при добавлении первой, ещё сырой версии фикса — после
исправления конфликта в `zz-`-файле pulseaudio перестал падать, но
затем случился РЕАЛЬНЫЙ ребут устройства по независимой причине
раньше, чем успели пере проверить `pactl list sinks` с обоими
фиксами одновременно). Нужно подтвердить на реальной прошивке в12:
`pactl list sinks short` должен показать `droid`-синк вместо
`auto_null`, и реальный тестовый звук через диктофон/плеер.

## Следующий шаг
Собрать и прошить в12, проверить на первой же загрузке:
1. `pactl list sinks/sources short` — должен быть `droid`, не только
   `auto_null`;
2. `systemctl --user status pulseaudio` — не должен падать/рестартовать
   в цикле;
3. рабочий стол не должен исчезать сам по себе (вачдога больше нет).
