// phase 0 hello shell. shows nothing. logs the custom hyprland event and ipc calls
// so the trigger path and the qs cli can be checked before anything visible exists.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

ShellRoot {
    Component.onCompleted: {
        console.warn(`[synopsis] up shellDir=${Quickshell.shellDir} watchFiles=${Quickshell.watchFiles}`)
    }

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            // hyprland emits the dispatcher "event" as a custom line on socket2
            if (event.name.indexOf("custom") === 0)
                console.warn(`[synopsis] ${Date.now()} socket2 ${event.name} >> ${event.data}`)
        }
    }

    IpcHandler {
        target: "overview"
        function toggle() { console.warn(`[synopsis] ${Date.now()} ipc toggle`) }
        function ping() { return "pong" }
    }
}
