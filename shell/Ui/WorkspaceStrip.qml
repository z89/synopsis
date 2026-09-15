pragma ComponentBehavior: Bound

// the strip of workspace tiles. it descends from the top with the scrim.
//
// the tiles live in a ListModel keyed by workspace id and synced in place
// (insert, remove, move), so a tile persists for as long as its id is shown:
// a plus click, a prune or a virtual id turning real never rebuilds the other
// tiles or their captures. a workspace switch changes nothing here at all; one
// highlight rectangle slides to the new tile instead.

import QtQuick
import qs.Core
import "../Core/Layout.js" as Layout

Item {
    id: strip

    property var mon: null
    property real progress: 0
    property real areaX: 0
    property real areaY: 0
    property real areaW: 0
    property real areaH: 0

    // bumped after every sync, the binding dependency for lookups into tileList
    // (a ListModel move or set does not change its count)
    property int tilesRevision: 0

    readonly property string wsSig: strip.mon ? (strip.mon.wsSig || "") : ""
    readonly property int activeId: strip.mon ? strip.mon.activeId : 0
    readonly property int specialId: strip.mon ? strip.mon.specialId : 0
    readonly property real aspect: (strip.mon && strip.mon.h > 0) ? (strip.mon.w / strip.mon.h) : 1
    // the button sits apart from the last tile by a clearly larger gap than
    // between tiles, so it reads as "add" rather than one more workspace
    readonly property real buttonGap: Config.stripGap * 2.5

    // the plus button is a square as tall as a tile and sits one (larger) gap
    // after the last one, so its width is reserved before the tiles are laid
    // out. with n tiles of aspect a the row n*h*a + (n-1)*gap + buttonGap + h
    // fits areaW when h <= (areaW - (n-1)*gap - buttonGap) / (n*a + 1); that
    // bound, capped by the area height, is the button size, and the tiles get
    // exactly the width that is left
    readonly property real buttonReserve: {
        const n = tileList.count;
        if (n <= 0)
            return Math.max(0, Math.min(strip.areaH, strip.areaW));
        return Math.max(0, Math.min(strip.areaH, (strip.areaW - (n - 1) * Config.stripGap - strip.buttonGap) / (n * strip.aspect + 1)));
    }
    readonly property var tileLayout: Layout.computeStrip(tileList.count, strip.aspect, {
        x: strip.areaX,
        y: strip.areaY,
        w: Math.max(0, strip.areaW - strip.buttonGap - strip.buttonReserve),
        h: strip.areaH
    }, {
        gap: Config.stripGap,
        maxTileHeight: strip.areaH
    })

    // the scale a window is drawn at inside a tile. a dragged thumb shrinks to it,
    // so it ends up the size it will have once dropped and the strip stays visible
    // under it. drags stay within one monitor and every strip derives its tiles
    // from the same fraction of its own monitor, so one shared value is enough
    readonly property real tileScale: (strip.mon && strip.mon.w > 0 && strip.tileLayout.tiles.length > 0) ? (strip.tileLayout.tiles[0].w / strip.mon.w) : 0

    readonly property int activeIndex: strip.indexOfTile(strip.tilesRevision, strip.activeId, strip.specialId)
    readonly property var activeCell: (strip.activeIndex >= 0) ? (strip.tileLayout.tiles[strip.activeIndex] || null) : null

    // the button rides one (larger) gap after the last tile. the button size is
    // reserved before the tiles are laid out and computeStrip centres them in
    // what is left, so the tiles already sit where the centred row puts them
    // and only the button needs placing
    readonly property int tileCount: strip.tileLayout.tiles.length
    readonly property real tileW: strip.tileCount > 0 ? strip.tileLayout.tiles[0].w : 0
    readonly property real tileH: strip.tileCount > 0 ? strip.tileLayout.tiles[0].h : Math.min(strip.areaH, strip.areaW)
    readonly property real tileY: strip.tileCount > 0 ? strip.tileLayout.tiles[0].y : (strip.areaY + (strip.areaH - strip.tileH) / 2)
    readonly property real buttonSize: strip.tileH
    readonly property real tilesWidth: strip.tileCount > 0 ? (strip.tileCount * strip.tileW + Config.stripGap * (strip.tileCount - 1)) : 0
    readonly property real rowWidth: strip.tilesWidth + strip.buttonGap + strip.buttonSize
    readonly property real rowStartX: strip.areaX + (strip.areaW - strip.rowWidth) / 2
    readonly property real buttonX: strip.rowStartX + strip.tilesWidth + strip.buttonGap

    opacity: strip.progress
    // off the top edge at rest, in place at full progress
    y: (strip.progress - 1) * (strip.areaY + strip.areaH)

    onWsSigChanged: strip.syncTiles()
    onTileScaleChanged: strip.publishTileScale()
    onActiveCellChanged: Qt.callLater(strip.placeHighlight)
    Component.onCompleted: {
        strip.syncTiles();
        strip.publishTileScale();
        strip.placeHighlight();
    }

    function publishTileScale() {
        if (strip.tileScale > 0)
            Overview.dropTileScale = strip.tileScale;
    }

    // diffs tileList against the model's workspace list by id, in the model's
    // (id) order: ids no longer shown are removed, known ids moved into place,
    // new ids inserted. only an id inserted while the overview is open is
    // marked fresh and plays the entrance; the population at open is not
    function syncTiles() {
        const list = [];
        const src = strip.mon ? (strip.mon.workspaces || []) : [];
        for (let s = 0; s < src.length; s++)
            if (src[s])
                list.push(src[s]);
        const wanted = {};
        for (let w = 0; w < list.length; w++)
            wanted[list[w].id] = true;
        for (let r = tileList.count - 1; r >= 0; r--)
            if (!wanted[tileList.get(r).tileId])
                tileList.remove(r);
        const animate = Overview.interactive;
        for (let i = 0; i < list.length; i++) {
            const id = list[i].id;
            if (i < tileList.count && tileList.get(i).tileId === id)
                continue;
            let found = -1;
            for (let j = i + 1; j < tileList.count; j++) {
                if (tileList.get(j).tileId === id) {
                    found = j;
                    break;
                }
            }
            if (found >= 0)
                tileList.move(found, i, 1);
            else
                tileList.insert(i, {
                    tileId: id,
                    fresh: animate
                });
        }
        strip.tilesRevision++;
    }

    function indexOfTile(revision, id, special) {
        let found = -1;
        for (let i = 0; i < tileList.count; i++) {
            const tid = tileList.get(i).tileId;
            if (tid === id)
                return i;
            if (special !== 0 && tid === special)
                found = i;
        }
        return found;
    }

    // this id's entry in the monitor model; mon is passed so a binding
    // calling this tracks every rebuild of it
    function workspaceFor(m, id) {
        const list = m ? (m.workspaces || []) : [];
        for (let i = 0; i < list.length; i++)
            if (list[i] && list[i].id === id)
                return list[i];
        return null;
    }

    // the highlight is placed here rather than bound, so each move picks its own
    // timing: staying on the same workspace while the row re-centres or
    // resizes follows the tiles (their duration and easing), moving to another
    // workspace travels like the exposé slide. deferred with callLater so an
    // activeId and a layout change from one model rebuild land as one move
    function placeHighlight() {
        const c = strip.activeCell;
        const id = (c && strip.activeIndex >= 0 && strip.activeIndex < tileList.count) ? tileList.get(strip.activeIndex).tileId : 0;
        const sameTile = id !== 0 && id === highlight.placedId;
        highlight.moveMs = sameTile ? Theme.shortDuration : Config.switchMs;
        highlight.moveEasing = sameTile ? Theme.standardEasing : Config.switchCurve;
        highlight.placedId = id;
        if (!c)
            return;
        highlight.x = c.x;
        highlight.y = c.y;
        highlight.width = c.w;
        highlight.height = c.h;
    }

    // itemAt() is typed QQuickItem; an untyped parameter keeps the call unchecked
    function tileCapture(item) {
        if (item)
            item.captureIdle();
    }

    function captureIdle() {
        for (let i = 0; i < tiles.count; i++)
            strip.tileCapture(tiles.itemAt(i));
    }

    ListModel {
        id: tileList
    }

    Repeater {
        id: tiles
        model: tileList

        delegate: WorkspaceTile {
            id: tileItem

            required property int index
            required property int tileId
            required property bool fresh

            readonly property var cell: strip.tileLayout.tiles[tileItem.index] || ({
                    x: 0,
                    y: 0,
                    w: 0,
                    h: 0
                })

            // mon is rebuilt whole on any change on this monitor, but ws is
            // only replaced when this tile's own content (name, window rects)
            // changed, so a plus click or a change on another tile leaves this
            // tile's thumbs and captures alone while moved windows still show
            readonly property var liveWs: strip.workspaceFor(strip.mon, tileItem.tileId)
            readonly property string liveSig: tileItem.liveWs ? Overview._stripSignature([tileItem.liveWs]) : ""

            onLiveSigChanged: tileItem.ws = tileItem.liveWs

            mon: strip.mon
            x: tileItem.cell.x
            y: tileItem.cell.y
            width: tileItem.cell.w
            height: tileItem.cell.h
            visible: tileItem.cell.w > 0

            // re-centring and resizing glide only while open: the opening and
            // closing flights lay the row out once and must not animate on top
            // of their own slide
            Behavior on x {
                enabled: Overview.interactive
                NumberAnimation {
                    duration: Theme.shortDuration
                    easing.type: Theme.standardEasing
                }
            }

            Behavior on y {
                enabled: Overview.interactive
                NumberAnimation {
                    duration: Theme.shortDuration
                    easing.type: Theme.standardEasing
                }
            }

            Behavior on width {
                enabled: Overview.interactive
                NumberAnimation {
                    duration: Theme.shortDuration
                    easing.type: Theme.standardEasing
                }
            }

            Behavior on height {
                enabled: Overview.interactive
                NumberAnimation {
                    duration: Theme.shortDuration
                    easing.type: Theme.standardEasing
                }
            }

            // a tile inserted while open (the plus button) fades and scales in
            // at its slot; every other tile is simply there at 1/1
            ParallelAnimation {
                id: entrance

                NumberAnimation {
                    target: tileItem
                    property: "opacity"
                    from: 0
                    to: 1
                    duration: Theme.shortDuration
                    easing.type: Theme.standardEasing
                }

                NumberAnimation {
                    target: tileItem
                    property: "scale"
                    from: 0.85
                    to: 1
                    duration: Theme.shortDuration
                    easing.type: Theme.standardEasing
                }
            }

            Component.onCompleted: {
                tileItem.ws = tileItem.liveWs;
                if (tileItem.fresh && Overview.interactive) {
                    tileItem.opacity = 0;
                    tileItem.scale = 0.85;
                    entrance.start();
                }
            }
        }
    }

    // appends a virtual empty workspace to this monitor's strip; minimal and
    // modern by design (plan.md new-workspace): idle is unfilled with a thin,
    // low-contrast outline, hover fills subtly and tints the glyph, press
    // dips the whole square. drawn with rectangles only, no font or icon asset
    Item {
        id: newWorkspaceButton

        x: strip.buttonX
        y: strip.tileY
        width: strip.buttonSize
        height: strip.buttonSize
        visible: strip.buttonSize > 0
        scale: plusMouse.pressed ? 0.96 : (plusHover.hovered ? 1.05 : 1.0)

        Behavior on x {
            enabled: Overview.interactive
            NumberAnimation {
                duration: Theme.shortDuration
                easing.type: Theme.standardEasing
            }
        }

        Behavior on y {
            enabled: Overview.interactive
            NumberAnimation {
                duration: Theme.shortDuration
                easing.type: Theme.standardEasing
            }
        }

        Behavior on width {
            enabled: Overview.interactive
            NumberAnimation {
                duration: Theme.shortDuration
                easing.type: Theme.standardEasing
            }
        }

        Behavior on height {
            enabled: Overview.interactive
            NumberAnimation {
                duration: Theme.shortDuration
                easing.type: Theme.standardEasing
            }
        }

        Behavior on scale {
            NumberAnimation {
                duration: Theme.shortDuration
                easing.type: Theme.standardEasing
            }
        }

        Rectangle {
            anchors.fill: parent
            radius: Theme.cornerRadius
            color: plusHover.hovered ? Theme.surfaceContainerHigh : "transparent"

            Behavior on color {
                ColorAnimation {
                    duration: Theme.shortDuration
                }
            }
        }

        Rectangle {
            anchors.fill: parent
            color: "transparent"
            radius: Theme.cornerRadius
            border.width: Theme.borderWidth
            border.color: plusHover.hovered ? Theme.primary : Theme.outlineVariant
            opacity: plusHover.hovered ? 1 : 0.6

            Behavior on opacity {
                NumberAnimation {
                    duration: Theme.shortDuration
                }
            }
        }

        // the plus glyph: two thin rounded bars crossed, sized off the button
        Rectangle {
            anchors.centerIn: parent
            width: parent.width * 0.3
            height: 2
            radius: height / 2
            color: plusHover.hovered ? Theme.primary : Theme.surfaceVariantText
        }

        Rectangle {
            anchors.centerIn: parent
            width: 2
            height: parent.height * 0.3
            radius: width / 2
            color: plusHover.hovered ? Theme.primary : Theme.surfaceVariantText
        }

        HoverHandler {
            id: plusHover
            // the same gates as a tile: hover once open, clicks through opening
            enabled: Overview.interactive
        }

        MouseArea {
            id: plusMouse
            anchors.fill: parent
            enabled: Overview.clickable
            acceptedButtons: Qt.LeftButton
            onClicked: Overview.createWorkspace(strip.mon ? strip.mon.name : "")
        }
    }

    // the one marker for the current workspace. placeHighlight sets its geometry
    // and the timing of each move
    Rectangle {
        id: highlight

        property int placedId: 0
        property int moveMs: Config.switchMs
        property int moveEasing: Config.switchCurve

        visible: strip.activeCell !== null && strip.activeCell.w > 0
        color: "transparent"
        radius: Theme.cornerRadius
        border.width: Theme.spacingXXS
        border.color: Theme.primary

        Behavior on x {
            // snaps while the strip is off screen (preparing, opening, closed) and
            // travels only when it can be seen: open, and the close after a tile click
            enabled: Overview.interactive || Overview.state === "closing"
            NumberAnimation {
                duration: highlight.moveMs
                easing.type: highlight.moveEasing
            }
        }

        Behavior on y {
            enabled: Overview.interactive || Overview.state === "closing"
            NumberAnimation {
                duration: highlight.moveMs
                easing.type: highlight.moveEasing
            }
        }

        Behavior on width {
            enabled: Overview.interactive || Overview.state === "closing"
            NumberAnimation {
                duration: highlight.moveMs
                easing.type: highlight.moveEasing
            }
        }

        Behavior on height {
            enabled: Overview.interactive || Overview.state === "closing"
            NumberAnimation {
                duration: highlight.moveMs
                easing.type: highlight.moveEasing
            }
        }
    }
}
