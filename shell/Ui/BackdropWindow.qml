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
        // transparent while preparing (thumbs not yet at the real rects), opaque for the whole flight
        visible: Overview.progress > 0 || Overview.state === "opening" || Overview.state === "open"
    }
}
