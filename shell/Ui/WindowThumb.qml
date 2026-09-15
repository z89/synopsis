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

    // the real pointer hover, written only while the mouse area is enabled
    property bool pointerHovered: false
    // the thumb under the cursor at open is lit from the first overlay frame:
    // Overview hit-tests the cursor against the real window rects at prepare,
    // and the mouse area cannot report anything until opening enables it (and
    // Qt may never send an enter for a stationary cursor). the seed holds until
    // the mouse area reports a real hover change
    property bool seedReleased: false
    readonly property bool seeded: !root.seedReleased && root.address !== "" && Overview.hoverSeedAddress === root.address
    readonly property bool hovered: root.pointerHovered || root.seeded

    // true only when the overlay knows where the pointer is and it is not over
    // this thumb. no pointer event yet this open is not stale: a stationary
    // cursor may never produce one, and the seed has to survive it
    function pointerOutside(): bool {
        const w = Overview.pointerWindow;
        if (w === null)
            return false;
        if (w !== root.Window.window)
            return true;
        return !root.contains(root.mapFromItem(null, Overview.pointerX, Overview.pointerY));
    }

    function releaseSeed() {
        root.seedReleased = true;
        if (Overview.hoverSeedAddress === root.address)
            Overview.hoverSeedAddress = "";
    }

    // the pointer really moved over the overlay (not a thumb flying under a
    // still cursor): anywhere but this thumb ends the seed
    Connections {
        target: Overview
        enabled: root.seeded

        function onPointerMoved() {
            if (root.pointerOutside())
                root.releaseSeed();
        }
    }
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
    // the tiles this drag can land on, read once when it starts; their rects
    // are mapped live on every move (Overview.dragMove)
    property var dropTiles: []
    // written by Overview.dragMove on pointer moves only: 1 far from the strip,
    // exactly the window's size on the nearest tile once the pointer is in it
    property real dragShrink: 1
    // an accepted drop: the thumb stays where it was released, at the size it
    // was dropped at, and fades once the tile draws the window. x and y stay
    // unbound until the move is settled, so no frame shows the old slot
    property bool handingOff: false
    property real handoffOpacity: 1
    // hidden by a pending drop (strip tile previews)
    property bool suppressed: false
    readonly property bool contentIn: view.hasContent

    // hyprland's scale for this window's monitor: a whole logical pixel is a
    // whole physical pixel only at an integer scale
    readonly property real pixelScale: HyprState.scaleForWorkspace(root.workspaceId)

    // snapped to the physical grid only while nothing moves: the swap frames
    // (progress 0, scale 1: preparing and the close landing) and the settled
    // open exposé. a thumb at a fractional position has its capture resampled
    // across two pixels, the soft text a real window never shows; but snapping
    // every frame of a flight or slide wobbles the far edges by a pixel and
    // steps through the slow ease-out tail, so moving thumbs stay fractional.
    // edges are snapped, not sizes, so the right and bottom edge land exactly
    readonly property bool snapped: Overview.progress === 0 || (Overview.state === "open" && Overview.progress === 1 && root.offsetX === 0 && !root.demoted)

    function snap(v: real): real {
        return Math.round(v * root.pixelScale) / root.pixelScale;
    }

    function wholePhysical(v: real): bool {
        const p = v * root.pixelScale;
        return Math.abs(p - Math.round(p)) < 0.001;
    }

    // the arriving set of a tile switch close (Expose): the real window rect at
    // scale 1 for the whole slide, only offsetX moving. its size never changes,
    // so it is snapped on every frame without any edge wobble: x whole physical
    // pixels, the size fixed from the snapped rest edges, and the capture drawn
    // 1:1 like hyprland's own slide. at offset 0 this is the snapped rest rect
    property bool flat: false

    readonly property real restX: (root.snapped || root.flat) ? root.snap(root.geoX + root.offsetX) : root.geoX + root.offsetX
    readonly property real restY: (root.snapped || root.flat) ? root.snap(root.geoY) : root.geoY

    x: root.restX
    y: root.restY
    width: root.flat ? root.snap(root.geoX + root.geoW) - root.snap(root.geoX) : (root.snapped ? root.snap(root.geoX + root.offsetX + root.geoW) - root.restX : root.geoW)
    height: (root.snapped || root.flat) ? root.snap(root.geoY + root.geoH) - root.restY : root.geoH
    visible: root.geoW > 0 && root.geoH > 0
    // a drag wins over everything, including a demotion that arrives mid-drag:
    // the thumb under the cursor stays on top for as long as the drag lasts. it
    // does not outlive a workspace switch: that drops interactive, the grab goes
    // with it, and the cancel that follows ends the drag a frame later
    z: (root.dragging || root.handingOff) ? Overview.dragZ : (root.address.length && root.address === Overview.raisedAddress ? Overview.dragZ - 1 : (root.demoted ? -1 : 0))

    // scaling about the grab point keeps that point fixed in the parent's
    // coordinates, so the content under the cursor stays under it at any
    // shrink. it is only attached while a drag, its release animation or a
    // drop handoff runs: a Scale at 1 still multiplies the item matrix about a
    // fractional grab point (float round trip) and marks it as scaling, so a
    // thumb at rest must carry none (a pixel-sharp kitty needs that)
    readonly property Scale dragTransform: Scale {
        origin.x: root.grabX
        origin.y: root.grabY
        xScale: root.dragShrink
        yScale: root.dragShrink
    }
    readonly property bool shrinkActive: Overview.interactive && (root.dragging || root.handingOff || root.dragShrink !== 1)
    transform: root.shrinkActive ? [root.dragTransform] : []

    // a close (or anything else ending open) mid-drag: the grab cancel that
    // normally ends the drag is not guaranteed to arrive, and a drag left set
    // would keep the thumb on top and scaled through the landing. nothing is
    // dispatched. a handoff in progress stays hidden: its row shows a window
    // that is no longer where the close flight would put it
    function dropDrag() {
        if (root.dragging) {
            Overview.cancelDrag("cancel");
            root.dragging = false;
            returnFlight.stop();
            root.restoreGeometry();
        } else if (root.handingOff) {
            handoffFade.stop();
            handoffFallback.stop();
            root.handoffOpacity = 0;
            root.restoreGeometry();
        } else {
            root.abortReturn();
        }
    }

    onDragMovingChanged: {
        if (root.dragMoving)
            root.dropTiles = Overview.beginDrag(root);
    }

    // the mouse area goes disabled with interactive, and that drops any grab it
    // held: a drag in flight is cancelled, not carried over. so the highlight goes
    // unconditionally, or a thumb hovered at that moment rides off screen lit up
    onInteractiveChanged: {
        if (!root.interactive) {
            root.pointerHovered = false;
            root.seedReleased = true;
            root.abortReturn();
        }
    }

    // a new open starts from the seed, not from whatever the last close left lit
    Connections {
        target: Overview
        function onStateChanged() {
            if (Overview.state === "preparing") {
                root.pointerHovered = false;
                root.seedReleased = false;
                if (root.awaitingRowGone) {
                    root.awaitingRowGone = false;
                    root.handoffOpacity = 1;
                }
            }
        }
        // a row kept hidden after its drop: the first refresh since the
        // handoff ended decides. still on this workspace means the move did
        // not happen, so the row fades back in; elsewhere, the row is on its
        // way out with the model update
        function onDataVersionChanged() {
            if (!root.awaitingRowGone)
                return;
            const c = Overview.findWindow(root.address);
            if (c === null || !c.workspace || c.workspace.id !== root.handoffFromWs)
                return;
            root.awaitingRowGone = false;
            if (Overview.interactive && root.interactive)
                handoffFadeIn.start();
            else
                root.handoffOpacity = 1;
        }
        function onHoverSeedAddressChanged() {
            root.seedReleased = false;
        }
        function onInteractiveChanged() {
            if (!Overview.interactive)
                root.dropDrag();
        }
        // the move settled (the tile drew the real one), timed out or the
        // overview closed: the row comes back if it still exists
        function onPendingDropsVersionChanged() {
            if (root.handingOff && Overview.pendingDropFor(root.address, Overview.pendingDropsVersion) === null)
                root.endHandoff();
        }
        function onDropPreviewReadyChanged() {
            if (root.handingOff && Overview.dropPreviewReady === root.address)
                root.startHandoffFade();
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

    // the bindings back and the drag scale at 1, which detaches the transform
    function restoreGeometry() {
        root.x = Qt.binding(function () {
            return root.restX;
        });
        root.y = Qt.binding(function () {
            return root.restY;
        });
        root.dragShrink = 1;
    }

    // ---- accepted drop ---------------------------------------------------
    //
    // the old flash: onReleased called restoreGeometry() on success and
    // cleared dragging, so x and y re-bound to the exposé slot, the shrink
    // Behavior grew the thumb back to scale 1, and the thumb drew at its old
    // exposé rect until the refresh removed the row. now nothing rebinds
    // until the move has settled

    // the exposé stays above the strip while this thumb is still visible over
    // it after the release: an accepted drop until its fade ends, a rejected
    // one until the return flight lands (Overview.dragLayerHold)
    readonly property bool needsDragLayer: (root.handingOff && root.handoffOpacity > 0) || returnFlight.running
    property int layerGen: -1

    function releaseDragLayer() {
        if (root.layerGen < 0)
            return;
        Overview.releaseDragLayer(root.layerGen);
        root.layerGen = -1;
    }

    onNeedsDragLayerChanged: {
        if (root.needsDragLayer && root.layerGen < 0)
            root.layerGen = Overview.takeDragLayer();
        else if (!root.needsDragLayer)
            root.releaseDragLayer();
    }

    // the workspace the row showed the window on when the drop was accepted,
    // and a row whose window hyprland has moved away: it stays invisible until
    // the refresh removes it, or shows the window never left
    property int handoffFromWs: 0
    property bool awaitingRowGone: false

    function startHandoff() {
        root.handoffFromWs = root.workspaceId;
        root.awaitingRowGone = false;
        root.handingOff = true;
        root.handoffOpacity = 1;
        handoffFadeIn.stop();
        if (Overview.dropPreviewReady === root.address)
            root.startHandoffFade();
        else
            handoffFallback.restart();
    }

    function startHandoffFade() {
        handoffFallback.stop();
        if (!handoffFade.running && root.handoffOpacity > 0)
            handoffFade.start();
    }

    // the row outlived the move (same workspace, a refused move, a close):
    // back to its slot, invisible, and in again
    function endHandoff() {
        if (!root.handingOff)
            return;
        handoffFade.stop();
        handoffFallback.stop();
        root.handingOff = false;
        root.restoreGeometry();
        if (Overview.interactive && root.interactive) {
            root.handoffOpacity = 0;
            // the move went through but the refresh that removes this row is
            // late: fading in would show the window at a slot it has left
            if (Overview.droppedAwayFrom(root.address, root.handoffFromWs)) {
                root.awaitingRowGone = true;
                Overview.requestDropRefresh();
            } else {
                handoffFadeIn.start();
            }
        } else {
            root.handoffOpacity = 1;
        }
    }

    // the tile preview normally has a frame within a few frames; a tile that
    // never draws it must not keep the dragged thumb up
    Timer {
        id: handoffFallback
        interval: Config.dropFadeMs * 2
        repeat: false
        onTriggered: root.startHandoffFade()
    }

    NumberAnimation {
        id: handoffFade
        target: root
        property: "handoffOpacity"
        to: 0
        duration: Config.dropFadeMs
        easing.type: Theme.standardEasing
    }

    NumberAnimation {
        id: handoffFadeIn
        target: root
        property: "handoffOpacity"
        to: 1
        duration: Config.dropFadeMs
        easing.type: Theme.standardEasing
    }

    // a rejected drop or a cancel flies the thumb back to its slot while the
    // approach shrink runs in reverse (plan.md: "animates it back").
    //
    // a keybind switch mid-drag is the case that has to be caught here: the row
    // turns into a leaving row, the mouse area goes disabled, the grab drops and
    // onCanceled fires. there is no slot to return to then - the row is sliding
    // off screen - so the bindings go back immediately and the thumb rides the
    // slide out instead of animating toward a stale rect and snapping
    function returnToSlot() {
        returnFlight.stop();
        if (root.demoted || !root.interactive || !Overview.interactive || (root.x === root.restX && root.y === root.restY)) {
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

    // starts from the current shrunk size and position. scaling about the grab
    // point at 1 is the identity, so the end frame is exactly the slot
    ParallelAnimation {
        id: returnFlight

        NumberAnimation {
            target: root
            property: "x"
            to: root.restX
            duration: Config.dragReturnMs
            easing.type: Theme.standardEasing
        }

        NumberAnimation {
            target: root
            property: "y"
            to: root.restY
            duration: Config.dragReturnMs
            easing.type: Theme.standardEasing
        }

        NumberAnimation {
            target: root
            property: "dragShrink"
            to: 1
            duration: Config.dragReturnMs
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
    // the window closed mid-drag and its row went: the drag ends here, no move
    Component.onDestruction: {
        if (root.dragging)
            Overview.cancelDrag("gone");
        root.releaseDragLayer();
        Overview.unregisterThumb(root);
    }

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
    opacity: (root.shown && !root.suppressed) ? root.handoffOpacity : 0

    // a flat arriving thumb whose capture came in after the slide started
    // fades in over a few frames instead of popping in mid-slide
    Behavior on opacity {
        enabled: root.flat
        NumberAnimation {
            duration: 80
            easing.type: Theme.standardEasing
        }
    }

    ClippingRectangle {
        id: clip
        anchors.fill: parent
        // the real window's rounding scaled with it, so the swap at rest is exact.
        // hyprland's decoration:rounding when it answered, the config otherwise
        radius: HyprState.rounding >= 0 ? HyprState.rounding * root.thumbScale : Math.max(Theme.spacingXXS, Config.windowRounding * root.thumbScale)
        color: root.placeholder ? Theme.surfaceContainer : "transparent"

        ScreencopyView {
            id: view
            anchors.fill: parent
            captureSource: (root.attached && Overview.active) ? root.source : null
            live: root.wantLive && Overview.active
            paintCursor: false
            // nearest only for an exact 1:1 physical mapping: scale 1, snapped
            // to the physical grid, no drag scale, and a logical size that is
            // whole physical pixels at the monitor scale. anything else
            // (a flight frame, a fractional scale that does not divide, a
            // downscaled thumb) is filtered. the view exposes no mipmap
            // control (quickshell-wayland-screencopy.qmltypes)
            smooth: !((root.snapped || root.flat) && root.thumbScale === 1 && !root.shrinkActive && root.wholePhysical(root.geoW) && root.wholePhysical(root.geoH))

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

    // the border hyprland draws, outside the window rect with its corner radius
    // grown by the width. at the swap frames it lands on the real border pixel
    // for pixel. theme colours and widths only when hyprland's could not be read
    //
    // hyprland colours by focus, not hover: until the exposé is open (preparing,
    // opening) the active colour goes to the window focused now, and from the
    // close on to the window the close hands focus to. only the open exposé
    // lights by hover and drag
    readonly property var borderInfo: HyprState.clientBorders[root.address] || null
    readonly property bool grouped: root.borderInfo !== null && root.borderInfo.grouped
    readonly property string focusLandingAddress: {
        if (Overview.state === "closing" && Overview.focusTarget !== "") {
            if (Overview.focusKind === "window")
                return Overview.focusTarget;
            if (Overview.focusKind === "workspace")
                return HyprState.lastFocusedOn(parseInt(Overview.focusTarget, 10));
        }
        return HyprState.focusedAddress;
    }
    readonly property bool lit: Overview.interactive ? (root.hovered || root.dragging || root.handingOff) : (root.address !== "" && root.address === root.focusLandingAddress)

    // a real fullscreen window has no border, the same as border_size 0
    readonly property real borderBase: root.borderInfo !== null && root.borderInfo.noBorder ? 0 : (HyprState.borderSize >= 0 ? HyprState.borderSize : Theme.borderWidth)
    // idle: the border scaled with the window, never under one physical pixel
    readonly property real idleWidth: root.borderBase <= 0 ? 0 : (root.thumbScale === 1 ? root.borderBase : Math.max(1 / root.pixelScale, root.snapped ? root.snap(root.borderBase * root.thumbScale) : root.borderBase * root.thumbScale))
    // lit: exactly border_size at the swap frames (progress 0), growing over
    // the flight to a width that still reads on a small thumb, even when
    // hyprland draws no border at all
    readonly property real litTarget: Math.max(root.borderBase * root.thumbScale, Theme.spacingXXS)
    readonly property real litWidth: Overview.progress === 0 ? root.borderBase : root.borderBase + ((root.snapped ? root.snap(root.litTarget) : root.litTarget) - root.borderBase) * Overview.progress
    // a flat thumb is the real window at scale 1: exactly hyprland's border
    readonly property real outlineWidth: root.flat ? root.borderBase : (root.lit ? root.litWidth : root.idleWidth)
    readonly property color outlineColor: (root.grouped && HyprState.groupBordersKnown) ? (root.lit ? HyprState.groupActiveBorderColor : HyprState.groupInactiveBorderColor) : (HyprState.bordersKnown ? (root.lit ? HyprState.activeBorderColor : HyprState.inactiveBorderColor) : (root.lit ? Theme.primary : Theme.outlineVariant))

    Rectangle {
        x: -root.outlineWidth
        y: -root.outlineWidth
        width: root.width + root.outlineWidth * 2
        height: root.height + root.outlineWidth * 2
        visible: Overview.progress > 0 && root.outlineWidth > 0
        color: "transparent"
        radius: clip.radius > 0 ? clip.radius + root.outlineWidth : 0
        border.width: root.outlineWidth
        border.color: root.outlineColor
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

    MouseArea {
        id: mouse
        anchors.fill: parent
        // clicks stay live through the opening flight (Overview.clickable); dragging
        // needs the settled layout, so it waits for interactive
        enabled: root.interactive && Overview.clickable
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        drag.target: Overview.interactive ? root : null
        // the thumb follows the pointer exactly, so the grab point (the
        // shrink origin) is the cursor and the probe below is the drop point
        drag.smoothed: false

        // hover follows containsMouse, and only while enabled: disabling at close
        // must not drop the look mid-flight, the thumb lands under the cursor lit
        // exactly as the real border will be
        onEnabledChanged: {
            if (mouse.enabled && mouse.containsMouse) {
                root.pointerHovered = true;
                root.seedReleased = true;
            } else if (mouse.enabled && root.seeded && root.pointerOutside()) {
                // enabled with the pointer known to be elsewhere: no enter or
                // exit will ever come for this thumb, so the seed ends here
                root.releaseSeed();
            }
        }
        onContainsMouseChanged: {
            if (!mouse.enabled)
                return;
            root.pointerHovered = mouse.containsMouse;
            root.seedReleased = true;
            // a real hover anywhere makes the seed stale for every thumb
            if (mouse.containsMouse)
                Overview.hoverSeedAddress = "";
        }

        onPressed: ev => {
            // a thumb handing off an accepted drop is already on its way out
            if (!Overview.interactive || root.handingOff)
                return;
            // a press during a release animation takes the thumb where it is,
            // at scale 1: the grab point changes and a leftover shrink about
            // the new origin would jump
            returnFlight.stop();
            root.dragShrink = 1;
            root.grabX = ev.x;
            root.grabY = ev.y;
            root.dragging = true;
        }

        onPositionChanged: ev => {
            if (!root.dragMoving)
                return;
            const p = mouse.mapToItem(null, ev.x, ev.y);
            // the overlay HoverHandler sees no moves while this mouse area
            // holds the grab; the strip's edge auto-scroll and the retarget
            // on scroll read this position
            Overview.notePointer(root.Window.window, p.x, p.y);
            Overview.dragMove(root, p.x, p.y);
        }

        // the drop is decided and dispatched while dragging is still set (the
        // transform attached, x and y where they were released); an accepted
        // one starts the handoff before anything else can rebind x and y
        onReleased: ev => {
            if (!root.dragging)
                return;
            const p = mouse.mapToItem(null, ev.x, ev.y);
            const accepted = Overview.endDrag(root, p.x, p.y);
            if (accepted)
                root.startHandoff();
            root.dragging = false;
            root.dropTiles = [];
            if (!accepted)
                root.returnToSlot();
        }

        onCanceled: {
            if (!root.dragging)
                return;
            Overview.cancelDrag("cancel");
            root.dragging = false;
            root.dropTiles = [];
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
