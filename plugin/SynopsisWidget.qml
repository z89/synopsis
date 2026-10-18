import QtQuick
import Quickshell
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

// Bar trigger only. The overview itself is a separate quickshell process
// (qs -c synopsis, see ../docs/brief.md) with its own IpcHandler; this
// plugin just calls it, the same way bin/synopsis toggle does.
PluginComponent {
    id: root

    pillClickAction: () => Quickshell.execDetached(["qs", "-c", "synopsis", "ipc", "call", "overview", "toggle"])

    horizontalBarPill: Component {
        DankIcon {
            name: "workspaces"
            size: root.iconSize
            color: Theme.widgetIconColor
        }
    }

    verticalBarPill: Component {
        DankIcon {
            name: "workspaces"
            size: root.iconSize
            color: Theme.widgetIconColor
        }
    }
}
