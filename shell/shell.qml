// synopsis: a hyprland overview. one process, one overlay per screen, hidden at rest.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Core
import qs.Debug
import qs.Ui

ShellRoot {
    id: shellRoot

    Component.onCompleted: {
        console.warn("[synopsis] up shellDir=" + Quickshell.shellDir + " screens=" + Quickshell.screens.length);
    }

    Variants {
        model: Quickshell.screens

        delegate: OverlayWindow {}
    }

    // the primary trigger: hl.dsp.event("synopsis", "toggle") on socket2, no process spawn
    Connections {
        target: Hyprland

        function onRawEvent(event) {
            if (("" + event.name).indexOf("custom") !== 0)
                return;
            const data = "" + event.data;
            if (data.indexOf("synopsis:") !== 0)
                return;
            const action = data.substring(9);
            if (action === "toggle")
                Overview.toggle();
            else if (action === "open")
                Overview.open();
            else if (action === "close")
                Overview.close();
        }
    }

    IpcHandler {
        target: "overview"

        function toggle(): void {
            Overview.toggle();
        }
        function open(): void {
            Overview.open();
        }
        function close(): void {
            Overview.close();
        }
        function ping(): string {
            return "pong";
        }
        function stats(): string {
            return Overview.statsJson();
        }
    }

    FrameLog {
        logState: true
    }
}
