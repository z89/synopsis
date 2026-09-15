pragma ComponentBehavior: Bound

// one workspace: the wallpaper with this workspace's windows composed on top,
// in hyprland's own stacking order.

import QtQuick
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

        Repeater {
            id: thumbs
            model: tile.ws ? tile.ws.windows : []

            delegate: WindowThumb {
                id: preview
                required property var modelData

                readonly property var pendingDrop: Overview.pendingDropFor(preview.modelData.address, Overview.pendingDropsVersion)
                // the snapshot shows the dropped window on this workspace and
                // this thumb has a frame: the dropped preview can go. being
                // here is enough for a tiled window (the layout decides), for
                // a window the drop thought floating but is not (a stale
                // flag), and for a move from another workspace (the move and
                // the placement are one request, so a snapshot with the
                // window here is past both, even when hyprland clamped the
                // position). only a drop on its own workspace waits for the
                // position, within 2 px
                readonly property bool dropLanded: preview.pendingDrop !== null && preview.pendingDrop.wsId === tile.wsId && preview.contentIn && (!preview.pendingDrop.floating || !preview.modelData.floating || !preview.pendingDrop.sameWs || (Math.abs(preview.modelData.x - preview.pendingDrop.x) <= 2 && Math.abs(preview.modelData.y - preview.pendingDrop.y) <= 2))

                win: preview.modelData
                interactive: false
                gated: false
                wantLive: tile.liveTile || preview.pendingDrop !== null
                // dropped elsewhere: gone from here at once. dropped here: the
                // preview draws it until this thumb has landed
                suppressed: preview.pendingDrop !== null && !preview.dropLanded
                thumbScale: tile.tileScale
                geoX: preview.modelData.x * tile.tileScale
                geoY: preview.modelData.y * tile.tileScale
                geoW: preview.modelData.w * tile.tileScale
                geoH: preview.modelData.h * tile.tileScale

                // deferred: settling bumps pendingDropsVersion, which
                // re-evaluates dropLanded inside its own change handler
                onDropLandedChanged: {
                    if (preview.dropLanded)
                        Qt.callLater(Overview.settleDrop, preview.modelData.address);
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
