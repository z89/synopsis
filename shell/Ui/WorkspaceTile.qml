pragma ComponentBehavior: Bound

// one workspace: the wallpaper with this workspace's windows composed on top,
// in hyprland's own stacking order.

import QtQuick
import Quickshell.Hyprland
import Quickshell.Widgets
import qs.Core

Item {
    id: tile

    property var ws: null
    property var mon: null

    readonly property int wsId: tile.ws ? tile.ws.id : 0
    readonly property string wsName: tile.ws ? tile.ws.name : ""
    // read from the model, never stored in the tile object, so a workspace switch
    // changes one binding instead of rebuilding the tile and its thumbs
    readonly property bool current: tile.mon ? (tile.wsId === tile.mon.activeId || (tile.mon.specialId !== 0 && tile.wsId === tile.mon.specialId)) : false
    readonly property real tileScale: (tile.mon && tile.mon.w > 0) ? (tile.width / tile.mon.w) : 1
    // set by Overview.dragMove only while the drop would be accepted: the edge
    // zone inside the tile does not light it
    readonly property bool dropTarget: Overview.dragAddress !== "" && Overview.dropWorkspaceId === tile.wsId
    readonly property bool hovered: hover.hovered
    readonly property bool liveTile: tile.current || tile.hovered
    // windows dropped on this tile whose move the snapshot does not show yet.
    // replaced only when this tile's own set of drops changes: every
    // pendingDropsVersion bump handing each tile a new array rebuilt every
    // preview Repeater (captures blinking, thumbs re-registering)
    property var pendingHere: []
    property string pendingSig: ""

    function syncPending() {
        const list = Overview.pendingDropsOn(tile.wsId, Overview.pendingDropsVersion);
        const sig = list.map(function (d) {
            return d.address + "@" + d.at;
        }).join("|");
        if (sig === tile.pendingSig)
            return;
        tile.pendingSig = sig;
        tile.pendingHere = list;
    }

    onWsIdChanged: tile.syncPending()

    Connections {
        target: Overview

        function onPendingDropsVersionChanged() {
            tile.syncPending();
        }
    }

    // a drag reads the tile list at its start and maps each rect live
    Component.onCompleted: {
        tile.syncPending();
        Overview.registerTile(tile);
    }
    Component.onDestruction: Overview.unregisterTile(tile)

    function thumbCapture(item) {
        if (item)
            item.captureOnce();
    }

    function captureIdle() {
        for (let i = 0; i < thumbs.count; i++)
            tile.thumbCapture(thumbs.itemAt(i));
    }

    // test hook for tools/sim, frame log only: synopsis:tile-probe:<tag> logs
    // every thumb of every tile with its capture state
    Connections {
        target: Hyprland
        enabled: Config.frameLog

        function onRawEvent(event) {
            const data = "" + event.data;
            if (("" + event.name).indexOf("custom") !== 0 || data.indexOf("synopsis:tile-probe:") !== 0)
                return;
            const tag = data.substring(20);
            for (let i = 0; i < thumbs.count; i++)
                tile.probeSlot(thumbs.itemAt(i), tag);
        }
    }

    function probeSlot(item, tag) {
        if (item)
            console.warn("[synopsis] " + Date.now() + " tile probe " + tag + " " + item.probeLine());
    }

    // ---- previews keyed by window address --------------------------------
    //
    // the old flash: the preview Repeater's model was ws.windows, a fresh array
    // on every snapshot that touched this workspace, so a window moving in or
    // out destroyed and rebuilt every thumb on both tiles; each new thumb stayed
    // invisible until its first capture. now thumbList holds one row per
    // address, synced in place (insert, move, a leaving mark), and a thumb
    // reads its window entry from winMap, so a moved rect is a binding change
    // that glides and the capture survives. a window that left fades out once
    // its thumb on the destination tile shows (or after a fallback), and a
    // window that arrived while open fades in on its first frame

    // address -> window entry of the current ws, replaced with ws
    property var winMap: ({})
    property string orderSig: ""

    onWsChanged: tile.syncThumbs()

    function syncThumbs() {
        const list = tile.ws ? (tile.ws.windows || []) : [];
        const map = {};
        const order = [];
        for (let i = 0; i < list.length; i++) {
            map[list[i].address] = list[i];
            order.push(list[i].address);
        }
        tile.winMap = map;
        const sig = order.join("|");
        if (sig === tile.orderSig)
            return;
        tile.orderSig = sig;
        // gone from this workspace: marked, the delegate fades and prunes it;
        // back again before that: revived in place
        for (let r = 0; r < thumbList.count; r++) {
            const row = thumbList.get(r);
            const want = map[row.address] !== undefined;
            if (row.leaving === want)
                thumbList.setProperty(r, "leaving", !want);
        }
        let pos = 0;
        for (let k = 0; k < order.length; k++) {
            while (pos < thumbList.count && thumbList.get(pos).leaving)
                pos++;
            const addr = order[k];
            if (pos < thumbList.count && thumbList.get(pos).address === addr) {
                pos++;
                continue;
            }
            let found = -1;
            for (let j = pos + 1; j < thumbList.count; j++) {
                if (thumbList.get(j).address === addr) {
                    found = j;
                    break;
                }
            }
            if (found >= 0)
                thumbList.move(found, pos, 1);
            else
                thumbList.insert(pos, {
                    address: addr,
                    leaving: false
                });
            pos++;
        }
    }

    // rows whose leave finished; deferred, so the model is never changed
    // from inside a delegate's own handler
    function pruneLeaving() {
        for (let r = thumbs.count - 1; r >= 0; r--) {
            if (tile.slotGone(thumbs.itemAt(r)))
                thumbList.remove(r);
        }
    }

    // itemAt() is typed QQuickItem; an untyped parameter keeps the read unchecked
    function slotGone(item) {
        return item !== null && item.leaving && item.gone;
    }

    // the strip relays a thumb that showed on another tile: this tile's
    // leaving copy of that window can go now
    function releaseLeaving(address) {
        for (let i = 0; i < thumbs.count; i++) {
            const item = thumbs.itemAt(i);
            if (item)
                tile.releaseSlot(item, address);
        }
    }

    function releaseSlot(item, address) {
        if (item.address === address && item.leaving)
            item.fadeOut();
    }

    // a thumb on this tile has its first frame (the strip listens)
    signal thumbShown(string address)

    ListModel {
        id: thumbList
    }

    ClippingRectangle {
        id: clip
        anchors.fill: parent
        radius: Theme.cornerRadius
        color: Theme.surfaceContainer

        Image {
            anchors.fill: parent
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
            source: Theme.wallpaperPath.length > 0 ? ("file://" + Theme.wallpaperPath) : ""
        }

        // its own layer, so the stacking z of each slot stays below the
        // dropped previews
        Item {
            id: thumbLayer
            anchors.fill: parent

            Repeater {
                id: thumbs
                model: thumbList

                delegate: Item {
                    id: slot

                    required property int index
                    required property string address
                    required property bool leaving

                    // the live entry while the window is here, the last one
                    // while it leaves
                    readonly property var liveWin: tile.winMap[slot.address] || null
                    property var lastWin: null
                    readonly property var win: slot.liveWin !== null ? slot.liveWin : slot.lastWin
                    // the leave finished; pruned on the next turn
                    property bool gone: false
                    // born into an open overview: fades in on its first frame
                    property bool arriving: false
                    property bool shownOnce: false

                    width: thumbLayer.width
                    height: thumbLayer.height
                    // hyprland's stacking order, the model order
                    z: slot.index

                    onLiveWinChanged: {
                        if (slot.liveWin !== null)
                            slot.lastWin = slot.liveWin;
                    }

                    // frame requests sent while not live (frame log only)
                    property int captures: 0

                    function captureOnce() {
                        if (Config.frameLog && preview.hasSource && !preview.liveNow)
                            slot.captures++;
                        preview.captureOnce();
                    }

                    function probeLine() {
                        return slot.address + " ws=" + tile.wsId + " leaving=" + slot.leaving + " op=" + slot.opacity.toFixed(2) + " vis=" + preview.opacity.toFixed(2) + " src=" + preview.hasSource + " live=" + preview.liveNow + " content=" + preview.contentIn + " captures=" + slot.captures + " tileVisible=" + tile.visible;
                    }

                    function logCapture() {
                        if (Config.frameLog && slot.arriving && Overview.interactive)
                            console.warn("[synopsis] " + Date.now() + " tile thumb cap " + slot.address + " ws=" + tile.wsId + " src=" + preview.hasSource + " live=" + preview.liveNow + " content=" + preview.contentIn);
                    }

                    // only an arriving slot starts hidden, and it shows on a
                    // real frame (or the placeholder). the preview's shown
                    // changes while the delegate is still being created,
                    // before onCompleted sets arriving and before the preview
                    // sets bornOpen (shown is true then with no frame): a
                    // reveal from there latched shownOnce with arriving still
                    // false, so onCompleted's opacity 0 was never undone and
                    // the thumb never relayed its arrival
                    function markShown() {
                        if (slot.shownOnce || !slot.arriving || !(preview.contentIn || preview.placeholder))
                            return;
                        slot.reveal("frame");
                    }

                    // the actual show, split from markShown so the fallback
                    // timer can force it even with no frame yet (a slot must
                    // never sit at opacity 0 forever)
                    function reveal(via) {
                        if (slot.shownOnce)
                            return;
                        slot.shownOnce = true;
                        frameHold.stop();
                        if (Config.frameLog && slot.arriving)
                            console.warn("[synopsis] " + Date.now() + " tile thumb shown " + slot.address + " ws=" + tile.wsId + " via=" + via + " src=" + preview.hasSource + " live=" + preview.liveNow + " content=" + preview.contentIn);
                        // a drop preview covers it until it lands: no fade,
                        // or the preview would go with this still transparent
                        if (slot.arriving && preview.pendingDrop === null && Overview.interactive)
                            fadeInAnim.start();
                        else
                            slot.opacity = 1;
                        if (slot.arriving)
                            tile.thumbShown(slot.address);
                    }

                    function fadeOut() {
                        frameHold.stop();
                        fadeInAnim.stop();
                        if (!fadeOutAnim.running)
                            fadeOutAnim.start();
                    }

                    function finishLeave() {
                        if (!slot.leaving)
                            return;
                        slot.gone = true;
                        Qt.callLater(tile.pruneLeaving);
                    }

                    onLeavingChanged: {
                        if (Config.frameLog)
                            console.warn("[synopsis] " + Date.now() + " tile thumb " + (slot.leaving ? "leaving " : "back ") + slot.address + " ws=" + tile.wsId);
                        if (slot.leaving) {
                            // dropped elsewhere (already hidden) or not on
                            // screen to watch: gone at once
                            if (!Overview.interactive || preview.pendingDrop !== null || slot.opacity === 0) {
                                slot.finishLeave();
                                return;
                            }
                            frameHold.restart();
                        } else {
                            frameHold.stop();
                            fadeOutAnim.stop();
                            slot.gone = false;
                            if (slot.opacity < 1)
                                fadeInAnim.start();
                        }
                    }

                    Component.onCompleted: {
                        slot.lastWin = slot.liveWin;
                        slot.arriving = Overview.interactive;
                        if (slot.arriving) {
                            slot.opacity = 0;
                            // a slot not current/hovered has no live view, so
                            // its first frame otherwise waits on the idle
                            // sweep, which skips tiles scrolled out of view;
                            // ask for one frame now regardless of visibility
                            slot.captureOnce();
                            frameHold.restart();
                        }
                        if (Config.frameLog)
                            console.warn("[synopsis] " + Date.now() + " tile thumb created " + slot.address + " ws=" + tile.wsId + " open=" + slot.arriving);
                        slot.markShown();
                    }
                    Component.onDestruction: {
                        if (Config.frameLog)
                            console.warn("[synopsis] " + Date.now() + " tile thumb destroyed " + slot.address + " ws=" + tile.wsId);
                    }

                    // shared by both ends of a slot's life: the destination's
                    // thumb normally shows within a few frames, and a leaving
                    // copy's replacement normally shows just as fast; either
                    // one that never does (another monitor, a tile scrolled
                    // away, a capture that never lands) must not hang forever
                    Timer {
                        id: frameHold
                        interval: Config.dropFadeMs * 2
                        repeat: false
                        onTriggered: slot.leaving ? slot.fadeOut() : slot.reveal("hold")
                    }

                    NumberAnimation {
                        id: fadeInAnim
                        target: slot
                        property: "opacity"
                        to: 1
                        duration: Theme.shortDuration
                        easing.type: Theme.standardEasing
                    }

                    NumberAnimation {
                        id: fadeOutAnim
                        target: slot
                        property: "opacity"
                        to: 0
                        duration: Theme.shortDuration
                        easing.type: Theme.standardEasing
                        onFinished: slot.finishLeave()
                    }

                    WindowThumb {
                        id: preview

                        readonly property var pendingDrop: Overview.pendingDropFor(slot.address, Overview.pendingDropsVersion)
                        // the snapshot shows the dropped window on this workspace and
                        // this thumb has a frame: the dropped preview can go. being
                        // here is enough for a tiled window (the layout decides), for
                        // a window the drop thought floating but is not (a stale
                        // flag), and for a move from another workspace (the move and
                        // the placement are one request, so a snapshot with the
                        // window here is past both, even when hyprland clamped the
                        // position). only a drop on its own workspace waits for the
                        // position, within 2 px
                        readonly property bool dropLanded: !slot.leaving && slot.win !== null && preview.pendingDrop !== null && preview.pendingDrop.wsId === tile.wsId && preview.contentIn && (!preview.pendingDrop.floating || !slot.win.floating || !preview.pendingDrop.sameWs || (Math.abs(slot.win.x - preview.pendingDrop.x) <= 2 && Math.abs(slot.win.y - preview.pendingDrop.y) <= 2))

                        win: slot.win
                        interactive: false
                        gated: false
                        wantLive: tile.liveTile || preview.pendingDrop !== null
                        // dropped elsewhere: gone from here at once. dropped here: the
                        // preview draws it until this thumb has landed
                        suppressed: preview.pendingDrop !== null && !preview.dropLanded
                        // read back off the animated box rather than driven
                        // by tileScale directly: at rest the two are the same
                        // ratio, but mid-glide the box on screen is not yet
                        // win.w * tileScale, and a decoration scale pinned to
                        // the target would sit out of proportion with it for
                        // the length of the animation
                        thumbScale: (slot.win && slot.win.w > 0) ? (preview.geoW / slot.win.w) : tile.tileScale
                        geoX: slot.win ? slot.win.x * tile.tileScale : 0
                        geoY: slot.win ? slot.win.y * tile.tileScale : 0
                        geoW: slot.win ? slot.win.w * tile.tileScale : 0
                        geoH: slot.win ? slot.win.h * tile.tileScale : 0
                        gliding: glideX.running || glideY.running || glideW.running || glideH.running

                        // the rest of the tile reflows around a window that came
                        // or went: each thumb glides to its new rect while open
                        Behavior on geoX {
                            enabled: Overview.interactive
                            NumberAnimation {
                                id: glideX
                                duration: Theme.shortDuration
                                easing.type: Theme.standardEasing
                            }
                        }

                        Behavior on geoY {
                            enabled: Overview.interactive
                            NumberAnimation {
                                id: glideY
                                duration: Theme.shortDuration
                                easing.type: Theme.standardEasing
                            }
                        }

                        Behavior on geoW {
                            enabled: Overview.interactive
                            NumberAnimation {
                                id: glideW
                                duration: Theme.shortDuration
                                easing.type: Theme.standardEasing
                            }
                        }

                        Behavior on geoH {
                            enabled: Overview.interactive
                            NumberAnimation {
                                id: glideH
                                duration: Theme.shortDuration
                                easing.type: Theme.standardEasing
                            }
                        }

                        onShownChanged: slot.markShown()
                        onContentInChanged: {
                            slot.logCapture();
                            slot.markShown();
                        }
                        // the source is handed out a few ms after the slot is
                        // born (Overview stagger), so the captureOnce in
                        // onCompleted had nothing to capture yet: ask again
                        onHasSourceChanged: {
                            slot.logCapture();
                            if (preview.hasSource && slot.arriving && !slot.shownOnce)
                                slot.captureOnce();
                        }
                        onLiveNowChanged: slot.logCapture()

                        // deferred: settling bumps pendingDropsVersion, which
                        // re-evaluates dropLanded inside its own change handler
                        onDropLandedChanged: {
                            if (preview.dropLanded)
                                Qt.callLater(Overview.settleDrop, slot.address);
                        }
                    }
                }
            }
        }

        // the optimistic preview: exactly the rect the dragged thumb was
        // released at, live, until the refresh brings the real one
        Repeater {
            model: tile.pendingHere

            delegate: WindowThumb {
                id: dropped
                required property var modelData

                win: dropped.modelData.win
                interactive: false
                gated: false
                wantLive: true
                thumbScale: tile.tileScale
                geoX: dropped.modelData.x * tile.tileScale
                geoY: dropped.modelData.y * tile.tileScale
                geoW: dropped.modelData.w * tile.tileScale
                geoH: dropped.modelData.h * tile.tileScale

                onContentInChanged: {
                    if (dropped.contentIn)
                        Overview.dropPreviewReady = dropped.modelData.address;
                }
            }
        }
    }

    Rectangle {
        anchors.fill: parent
        color: "transparent"
        radius: Theme.cornerRadius
        // the current workspace is marked by the strip's own highlight, which
        // travels between tiles; this border is hover and drop feedback only
        border.width: tile.dropTarget ? Theme.spacingXS : (tile.hovered ? Theme.spacingXXS : Theme.borderWidth)
        border.color: tile.dropTarget ? Theme.secondary : Theme.outline
    }

    HoverHandler {
        id: hover
        enabled: Overview.interactive
    }

    MouseArea {
        anchors.fill: parent
        // a tile click is accepted through the opening flight too, so the first
        // clicks after the keybind are not swallowed (Overview.clickable)
        enabled: Overview.clickable
        acceptedButtons: Qt.LeftButton
        // the current tile has nothing to switch to, so it is just a close
        onClicked: {
            if (tile.current)
                Overview.close();
            else
                Overview.activateWorkspace(tile.wsId, tile.wsName);
        }
    }
}
