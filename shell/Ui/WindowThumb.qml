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
    // a thumb of a workspace that is sliding away: it stays below everything else
    property bool demoted: false
    property real thumbScale: 1

    // slides add to x here so nothing ever touches the geometry bindings
    property real offsetX: 0
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

    x: root.geoX + root.offsetX
    y: root.geoY
    width: root.geoW
    height: root.geoH
    visible: root.geoW > 0 && root.geoH > 0
    // a drag wins over everything, including a demotion that arrives mid-drag:
    // the thumb under the cursor stays on top for as long as the drag lasts. it
    // does not outlive a workspace switch: that drops interactive, the grab goes
    // with it, and the cancel that follows ends the drag a frame later
    z: root.dragging ? Overview.dragZ : (root.address.length && root.address === Overview.raisedAddress ? Overview.dragZ - 1 : (root.demoted ? -1 : 0))

    // the mouse area goes disabled with interactive, and that drops any grab it
    // held: a drag in flight is cancelled, not carried over. so the highlight goes
    // unconditionally, or a thumb hovered at that moment rides off screen lit up
    onInteractiveChanged: {
        if (!root.interactive)
            root.hovered = false;
    }

    function restoreGeometry() {
        root.x = Qt.binding(function () {
            return root.geoX + root.offsetX;
        });
        root.y = Qt.binding(function () {
            return root.geoY;
        });
    }

    function captureOnce() {
        if (view.captureSource !== null && !view.live)
            view.captureFrame();
    }

    // a thumb born into an already open overview (a new window, an incoming
    // workspace) must never paint a placeholder into a settled view: it stays
    // invisible until it has something real to show
    property bool bornOpen: false
    property bool placeholderDue: false

    Component.onCompleted: {
        root.bornOpen = Overview.state === "open";
        placeholderDelay.start();
        Overview.registerThumb(root);
    }
    Component.onDestruction: Overview.unregisterThumb(root)

    // the class name is the last resort: a window with no capture source at all
    // (xwayland, unmapped), and only once the wait for one is definitely over
    Timer {
        id: placeholderDelay
        interval: Config.hasContentTimeoutMs
        repeat: false
        onTriggered: root.placeholderDue = true
    }

    // an exposé thumb whose capture is late gets the same box: once the flight
    // is under way the backdrop hides the real window, and a labelled box is
    // better than a window that vanishes
    readonly property bool placeholder: !view.hasContent && root.placeholderDue && root.attached && (!root.hasSource || root.gated)

    // while preparing the thumb sits exactly over the real window, so nothing
    // may paint until the capture is in (a placeholder box or outline would
    // flash); windows without a texture only show once the backdrop is up
    readonly property bool shown: root.bornOpen ? (view.hasContent || root.placeholder) : (view.hasContent || Overview.progress > 0)
    opacity: root.shown ? 1 : 0

    ClippingRectangle {
        id: clip
        anchors.fill: parent
        // the real window's rounding scaled with it, so the swap at rest is exact
        radius: Math.max(Theme.spacingXXS, Config.windowRounding * root.thumbScale)
        color: root.placeholder ? Theme.surfaceContainer : "transparent"

        ScreencopyView {
            id: view
            anchors.fill: parent
            captureSource: (root.attached && Overview.active) ? root.source : null
            live: root.wantLive && Overview.active
            paintCursor: false

            onHasContentChanged: {
                if (Config.frameLog && Overview.state === "preparing")
                    console.warn("[synopsis] " + Date.now() + " content " + (view.hasContent ? "in" : "out") + " " + (root.win ? root.win.cls : "?") + " gated=" + root.gated);
            }
        }

        // xwayland or unmapped: no texture, so show something identifiable
        Text {
            anchors.centerIn: parent
            visible: root.placeholder
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
