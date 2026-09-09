// SPDX-FileCopyrightText: 2022 Devin Lin <devin@kde.org>
// SPDX-License-Identifier: LGPL-2.0-or-later

import QtQuick 2.15

import org.kde.plasma.private.mobileshell.quicksettingsplugin as QS
import org.kde.plasma.private.mobileshell.state as MobileShellState
import org.kde.plasma.plasma5support as P5Support

QS.QuickSetting {
    text: i18n("Screenshot")
    status: i18n("Tap to screenshot")
    icon: "view-fullscreen-symbolic"
    enabled: true

    property bool screenshotRequested: false

    function toggle() {
        screenshotRequested = true;
        MobileShellState.ShellDBusClient.closeActionDrawer();
    }

    Connections {
        target: MobileShellState.ShellDBusClient

        function onIsActionDrawerOpenChanged(visible) {
            if (!visible && screenshotRequested) {
                screenshotRequested = false;
                timer.restart();
            }
        }
    }

    // НАЙДЕНО 2026-09-07: org.kde.KWin.ScreenShot2 (ScreenShotUtil) не
    // работает на этом устройстве -- kwin_wayland тут запущен во
    // вложенном режиме под wayfire, без обычной сессионной
    // интеграции, D-Bus сервис org.kde.KWin не регистрируется вообще
    // (подтверждено: "Service 'org.kde.KWin' does not exist"). Замена
    // -- grim (wlroots screencopy) через сокет ИМЕННО wayfire
    // (wayland-0), не вложенного kwin (wayland-1, не поддерживает
    // screencopy-протокол вообще, проверено живьём).
    P5Support.DataSource {
        id: grimExec
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            disconnectSource(sourceName);
        }
        function exec(cmd) {
            connectSource(cmd);
        }
    }

    // HACK: KWin's fade effect may have the window ending up being in the screenshot if taken too fast
    Timer {
        id: timer
        interval: 500
        onTriggered: grimExec.exec(
            "mkdir -p /home/phablet/Изображения && " +
            "env WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/1000 " +
            "grim \"/home/phablet/Изображения/Screenshot_$(date +%Y%m%d_%H%M%S).png\""
        )
    }
}
