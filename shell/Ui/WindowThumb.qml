// one window. the capture source is handed over by Overview's stagger timer,
// never bound directly (quickshell #1123).

import QtQuick
import Quickshell.Wayland
import Quickshell.Widgets
import qs.Core

Item {
    id: root

    property var win: null
    property bool attached: false
    property bool gated: false
    property bool wantLive: true
    property bool interactive: false
    property real thumbScale: 1

    property real geoX: 0
    property real geoY: 0
    property real geoW: 0
    property real geoH: 0

    readonly property string address: root.win ? root.win.address : ""
    readonly property int workspaceId: root.win ? root.win.workspaceId : 0
    readonly property var source: (root.win && root.win.toplevel) ? root.win.toplevel.wayland : null

    readonly property bool hasSource: view.captureSource !== null
    readonly property bool liveNow: view.live && view.captureSource !== null
    readonly property bool ready: view.captureSource === null || view.hasContent

    property bool hovered: false
    property bool dragging: false

    x: root.geoX
    y: root.geoY
    width: root.geoW
    height: root.geoH
    visible: root.geoW > 0 && root.geoH > 0
    z: root.dragging ? Overview.dragZ : (root.address.length && root.address === Overview.raisedAddress ? Overview.dragZ - 1 : 0)

    function restoreGeometry() {
        root.x = Qt.binding(function () {
            return root.geoX;
        });
        root.y = Qt.binding(function () {
            return root.geoY;
        });
    }

    function captureOnce() {
        if (view.captureSource !== null && !view.live)
            view.captureFrame();
    }

    Component.onCompleted: Overview.registerThumb(root)
    Component.onDestruction: Overview.unregisterThumb(root)

    // while preparing the thumb sits exactly over the real window, so nothing
    // may paint until the capture is in (a placeholder box or outline would
    // flash); windows without a texture only show once the backdrop is up
    readonly property bool shown: view.hasContent || Overview.progress > 0
    opacity: root.shown ? 1 : 0

    ClippingRectangle {
        id: clip
        anchors.fill: parent
        // the real window's rounding scaled with it, so the swap at rest is exact
        radius: Math.max(Theme.spacingXXS, Config.windowRounding * root.thumbScale)
        color: view.hasContent ? "transparent" : Theme.surfaceContainer

        ScreencopyView {
            id: view
            anchors.fill: parent
            captureSource: (root.attached && Overview.active) ? root.source : null
            live: root.wantLive && Overview.active
            paintCursor: false
        }

        // xwayland or unmapped: no texture, so show something identifiable
        Text {
            anchors.centerIn: parent
            visible: !view.hasContent
            width: parent.width - Theme.spacingM * 2
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            color: Theme.surfaceVariantText
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeMedium
            text: root.win ? root.win.cls : ""
        }
    }

    Rectangle {
        anchors.fill: parent
        visible: Overview.progress > 0
        color: "transparent"
        radius: clip.radius
        border.width: root.hovered || root.dragging ? Theme.spacingXXS : Theme.borderWidth
        border.color: root.hovered || root.dragging ? Theme.primary : Theme.outlineVariant
        opacity: root.interactive ? 1 : Config.dragOpacity

        Behavior on opacity {
            NumberAnimation {
                duration: Theme.shortDuration
                easing.type: Theme.standardEasing
            }
        }
    }

    Rectangle {
        id: label
        visible: root.interactive && root.hovered && root.win !== null
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Theme.spacingS
        width: Math.min(parent.width - Theme.spacingM, labelText.implicitWidth + Theme.spacingL)
        height: labelText.implicitHeight + Theme.spacingS
        radius: height / 2
        color: Theme.surfaceContainerHigh

        Text {
            id: labelText
            anchors.centerIn: parent
            width: parent.width - Theme.spacingM
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
            color: Theme.surfaceText
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeSmall
            text: root.win ? root.win.title : ""
        }
    }

    Drag.active: root.dragging
    Drag.source: root
    Drag.keys: ["synopsis-window"]
    Drag.hotSpot.x: root.width / 2
    Drag.hotSpot.y: root.height / 2

    MouseArea {
        id: mouse
        anchors.fill: parent
        enabled: root.interactive && Overview.interactive
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        drag.target: root.interactive ? root : null

        onEntered: root.hovered = true
        onExited: root.hovered = false

        onPressed: {
            root.dragging = true;
            Overview.beginDrag(root.address);
        }

        // endDrag first: clearing dragging deactivates Drag, which delivers DragLeave
        // to the tile under the cursor synchronously and wipes the drop target
        onReleased: {
            Overview.endDrag(root.address, root.workspaceId);
            root.dragging = false;
            root.restoreGeometry();
        }

        onCanceled: {
            Overview.endDrag("", root.workspaceId);
            root.dragging = false;
            root.restoreGeometry();
        }

        // MouseArea suppresses clicked once the drag threshold was crossed
        onClicked: {
            if (!root.win)
                return;
            Overview.activateWindow(root.win.address, root.win.workspaceId, root.win.workspaceName, root.win.floating);
        }
    }
}
