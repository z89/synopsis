import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Core

// the opaque wallpaper that hides the real windows while the overview is up.
// it lives on the top layer, sorted beneath the dms bar by the synopsis-backdrop
// layer rule, so the bar and notifications stay visible between it and the scrim
PanelWindow { // qmllint disable uncreatable-type
    id: win

    required property var modelData

    visible: Overview.active
    exclusionMode: ExclusionMode.Ignore
    screen: win.modelData
    color: "transparent"

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "synopsis-backdrop"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    Image {
        anchors.fill: parent
        source: Theme.wallpaperPath.length ? "file://" + Theme.wallpaperPath : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        // transparent only while preparing, when the thumbs sit exactly over the
        // real windows. opaque for every other state, including the whole of
        // closing: a tile click reaches progress 0 while the exposé slide is
        // still running, and the real windows must not show under moving thumbs
        visible: Overview.active && Overview.state !== "preparing"
    }
}
