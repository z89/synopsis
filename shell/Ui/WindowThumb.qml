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
    // where inside the thumb the pointer grabbed, in thumb coordinates. it is both
    // the drag hot spot and the origin of the shrink, so the cursor stays on the
    // same content point for the whole drag. the hot spot used to be the thumb
    // centre, which on an exposé thumb put the drop point 400-540 px below the
    // cursor: no tile ever saw it and no drop ever resolved
    property real grabX: 0
    property real grabY: 0
    // a press is not yet a drag: the thumb only shrinks, logs and takes drop
    // targets once the mouse area has crossed its threshold
    readonly property bool dragMoving: root.dragging && mouse.drag.active
    // the size this window will have inside a strip tile. shrinking to it leaves
    // the strip and its drop highlight visible under the dragged thumb
    readonly property real dropScale: (Overview.dropTileScale > 0 && root.thumbScale > 0) ? Math.max(0.1, Math.min(1, Overview.dropTileScale / root.thumbScale)) : 1
    property real dragShrink: root.dragMoving ? root.dropScale : 1

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

    Behavior on dragShrink {
        NumberAnimation {
            duration: Theme.shortDuration
            easing.type: Theme.standardEasing
        }
    }

    // scaling about the grab point keeps that point fixed in the parent's
    // coordinates, which is exactly what Drag.hotSpot below is expressed in
    transform: Scale {
        origin.x: root.grabX
        origin.y: root.grabY
        xScale: root.dragShrink
        yScale: root.dragShrink
    }

    onDragMovingChanged: {
        if (root.dragMoving)
            Overview.beginDrag(root.address);
    }

    // the mouse area goes disabled with interactive, and that drops any grab it
    // held: a drag in flight is cancelled, not carried over. so the highlight goes
    // unconditionally, or a thumb hovered at that moment rides off screen lit up
    onInteractiveChanged: {
        if (!root.interactive) {
            root.hovered = false;
            root.abortReturn();
        }
    }

    // the row became a leaving row (a workspace switch landed): it is riding a
    // slide out now, and a return flight aiming at a slot it no longer has would
    // fight the slide and then snap
    onDemotedChanged: {
        if (root.demoted)
            root.abortReturn();
    }

    // the row was retargeted, or a slide is moving it: same reasoning. x is
    // unbound while the return runs, so the only way offsetX can move the thumb
    // again is to give the binding back
    onOffsetXChanged: root.abortReturn()

    function restoreGeometry() {
        root.x = Qt.binding(function () {
            return root.geoX + root.offsetX;
        });
        root.y = Qt.binding(function () {
            return root.geoY;
        });
    }

    // a failed drop or a cancel flies the thumb back to its slot (plan.md: "animates
    // it back"); a successful drop is left alone, the reflow moves it.
    //
    // a keybind switch mid-drag is the case that has to be caught here: the row
    // turns into a leaving row, the mouse area goes disabled, the grab drops and
    // onCanceled fires. there is no slot to return to then - the row is sliding
    // off screen - so the bindings go back immediately and the thumb rides the
    // slide out instead of animating toward a stale rect and snapping
    function returnToSlot() {
        returnFlight.stop();
        if (root.demoted || !root.interactive || !Overview.interactive || (root.x === root.geoX + root.offsetX && root.y === root.geoY)) {
            root.restoreGeometry();
            return;
        }
        returnFlight.start();
    }

    // give x and y back to their bindings, wherever the return had got to
    function abortReturn() {
        if (!returnFlight.running)
            return;
        returnFlight.stop();
        root.restoreGeometry();
    }

    ParallelAnimation {
        id: returnFlight

        NumberAnimation {
            target: root
            property: "x"
            to: root.geoX + root.offsetX
            duration: Theme.shortDuration
            easing.type: Theme.standardEasing
        }

        NumberAnimation {
            target: root
            property: "y"
            to: root.geoY
            duration: Theme.shortDuration
            easing.type: Theme.standardEasing
        }

        onFinished: root.restoreGeometry()
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
    Drag.hotSpot.x: root.grabX
    Drag.hotSpot.y: root.grabY

    MouseArea {
        id: mouse
        anchors.fill: parent
        // clicks stay live through the opening flight (Overview.clickable); dragging
        // needs the settled layout, so it waits for interactive
        enabled: root.interactive && Overview.clickable
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        drag.target: Overview.interactive ? root : null

        onEntered: root.hovered = true
        onExited: root.hovered = false

        onPressed: ev => {
            if (!Overview.interactive)
                return;
            returnFlight.stop();
            root.grabX = ev.x;
            root.grabY = ev.y;
            root.dragging = true;
        }

        // endDrag first: clearing dragging deactivates Drag, which delivers DragLeave
        // to the tile under the cursor synchronously and wipes the drop target
        onReleased: {
            if (!root.dragging)
                return;
            const moved = Overview.endDrag(root.address, root.workspaceId);
            root.dragging = false;
            if (moved)
                root.restoreGeometry();
            else
                root.returnToSlot();
        }

        onCanceled: {
            if (!root.dragging)
                return;
            Overview.endDrag("", root.workspaceId);
            root.dragging = false;
            root.returnToSlot();
        }

        // MouseArea suppresses clicked once the drag threshold was crossed
        onClicked: {
            if (!root.win)
                return;
            Overview.activateWindow(root.win.address, root.win.workspaceId, root.win.workspaceName, root.win.floating);
        }
    }
}
