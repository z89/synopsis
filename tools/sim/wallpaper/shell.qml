// simulator only: a background layer with the same wallpaper the overview's
// backdrop paints, so the nested desktop looks like the real one and the
// backdrop mapping is not a hard cut in the recording. SIM_WALLPAPER is the
// image path (run.sh reads it from DankMaterialShell's session.json).

import QtQuick
import Quickshell
import Quickshell.Wayland

ShellRoot {
    Variants {
        model: Quickshell.screens

        PanelWindow {
            required property var modelData
            screen: modelData
            color: "#1a1a1a"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Background
            WlrLayershell.namespace: "synopsis-sim-wallpaper"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            anchors { top: true; bottom: true; left: true; right: true }

            Image {
                anchors.fill: parent
                source: Quickshell.env("SIM_WALLPAPER").length ? "file://" + Quickshell.env("SIM_WALLPAPER") : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: false
            }
        }
    }
}
