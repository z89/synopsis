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

    Variants {
        model: Quickshell.screens

        delegate: BackdropWindow {}
    }

    // the primary trigger: hl.dsp.event("synopsis", "toggle") on socket2, no process spawn
    Connections {
        target: Hyprland

        function onRawEvent(event) {
            if (Config.frameLog && /^(workspacev2|focusedmonv2|activewindowv2|closelayer|openlayer)$/.test(event.name))
                console.warn("[synopsis] " + Date.now() + " event " + event.name + " " + event.data);
            if (("" + event.name).indexOf("custom") !== 0)
                return;
            const data = "" + event.data;
            if (data.indexOf("synopsis:") !== 0)
                return;
            // synopsis:<verb>[:<arg>[:<arg>]]; the verbs beyond toggle/open/close
            // exist so the headless test harness can drive the same code paths
            // a click takes (tools/sim), through hyprland's own event socket
            const parts = data.substring(9).split(":");
            const action = parts[0];
            if (action === "toggle")
                Overview.toggle();
            else if (action === "open")
                Overview.open();
            else if (action === "close")
                Overview.close();
            else if (action === "confirm")
                Overview.confirm();
            else if (action === "activate-workspace")
                Overview.activateWorkspaceById(parseInt(parts[1], 10));
            else if (action === "activate-window")
                Overview.activateWindowByAddress(parts[1] || "");
            else if (action === "move-window")
                Overview.moveWindowByAddress(parts[1] || "", parseInt(parts[2], 10));
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

