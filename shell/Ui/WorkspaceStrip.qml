pragma ComponentBehavior: Bound

// the strip of workspace tiles. it descends from the top with the scrim.
//
// the tile set is held here and only replaced when the model's strip signature
// changed, so a workspace switch rebuilds nothing: one highlight rectangle slides
// to the new tile instead.

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

    property var tileModel: []

    readonly property string wsSig: strip.mon ? (strip.mon.wsSig || "") : ""
    readonly property int activeId: strip.mon ? strip.mon.activeId : 0
    readonly property int specialId: strip.mon ? strip.mon.specialId : 0
    readonly property real aspect: (strip.mon && strip.mon.h > 0) ? (strip.mon.w / strip.mon.h) : 1
    // the plus button is a square as tall as a tile and sits one gap after the
    // last one, so its width is reserved before the tiles are laid out. with n
    // tiles of aspect a the row n*h*a + n*gap + h fits areaW when
    // h <= (areaW - n*gap) / (n*a + 1); that bound, capped by the area height,
    // is the button size, and the tiles get exactly the width that is left
    readonly property real buttonReserve: {
        const n = strip.tileModel.length;
        if (n <= 0)
            return Math.max(0, Math.min(strip.areaH, strip.areaW));
        return Math.max(0, Math.min(strip.areaH, (strip.areaW - n * Config.stripGap) / (n * strip.aspect + 1)));
    }
    readonly property var tileLayout: Layout.computeStrip(strip.tileModel.length, strip.aspect, {
        x: strip.areaX,
        y: strip.areaY,
        w: Math.max(0, strip.areaW - Config.stripGap - strip.buttonReserve),
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

    readonly property int activeIndex: strip.indexOfWorkspace(strip.tileModel, strip.activeId, strip.specialId)
    readonly property var activeCell: (strip.activeIndex >= 0) ? (strip.tileLayout.tiles[strip.activeIndex] || null) : null

    // the plus button rides after the last tile, at the same height and gap.
    // the tile layout itself (and tileScale) stays computed from tiles only;
    // here the whole row (tiles + button) is re-centred within the area
    readonly property int tileCount: strip.tileLayout.tiles.length
    readonly property real tileW: strip.tileCount > 0 ? strip.tileLayout.tiles[0].w : 0
    readonly property real tileH: strip.tileCount > 0 ? strip.tileLayout.tiles[0].h : Math.min(strip.areaH, strip.areaW)
    readonly property real tileY: strip.tileCount > 0 ? strip.tileLayout.tiles[0].y : (strip.areaY + (strip.areaH - strip.tileH) / 2)
    readonly property real gap: Config.stripGap
    readonly property real buttonSize: strip.tileH
    readonly property real tilesWidth: strip.tileCount > 0 ? (strip.tileCount * strip.tileW + strip.gap * (strip.tileCount - 1)) : 0
    readonly property real rowWidth: strip.tilesWidth + (strip.tileCount > 0 ? strip.gap : 0) + strip.buttonSize
    readonly property real rowStartX: strip.areaX + (strip.areaW - strip.rowWidth) / 2
    readonly property real tileShiftX: strip.rowStartX - (strip.tileCount > 0 ? strip.tileLayout.tiles[0].x : strip.areaX)
    readonly property real buttonX: strip.rowStartX + strip.tilesWidth + (strip.tileCount > 0 ? strip.gap : 0)

    opacity: strip.progress
    // off the top edge at rest, in place at full progress
    y: (strip.progress - 1) * (strip.areaY + strip.areaH)

    onWsSigChanged: strip.syncTiles()
    onTileScaleChanged: strip.publishTileScale()
    Component.onCompleted: {
        strip.syncTiles();
        strip.publishTileScale();
    }

    function publishTileScale() {
        if (strip.tileScale > 0)
            Overview.dropTileScale = strip.tileScale;
    }

    function syncTiles() {
        strip.tileModel = strip.mon ? strip.mon.workspaces : [];
    }

    function indexOfWorkspace(list, id, special) {
        let found = -1;
        for (let i = 0; i < list.length; i++) {
            const ws = list[i];
            if (!ws)
                continue;
            if (ws.id === id)
                return i;
            if (special !== 0 && ws.id === special)
                found = i;
        }
        return found;
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

    Repeater {
        id: tiles
        model: strip.tileModel

        delegate: WorkspaceTile {
            required property int index
            required property var modelData

            readonly property var cell: strip.tileLayout.tiles[index] || ({
                    x: 0,
                    y: 0,
                    w: 0,
                    h: 0
                })

            ws: modelData
            mon: strip.mon
            x: cell.x + strip.tileShiftX
            y: cell.y
            width: cell.w
            height: cell.h
            visible: cell.w > 0
        }
    }

    // switches to a new empty workspace; visually a square tile-alike, drawn
    // with rectangles only so it needs no font or icon asset
    Rectangle {
        id: newWorkspaceButton

        x: strip.buttonX
        y: strip.tileY
        width: strip.buttonSize
        height: strip.buttonSize
        radius: Theme.cornerRadius
        visible: strip.buttonSize > 0
        color: plusHover.hovered ? Theme.surfaceContainerHigh : Theme.surfaceContainer

        Rectangle {
            anchors.fill: parent
            color: "transparent"
            radius: Theme.cornerRadius
            border.width: plusHover.hovered ? Theme.spacingXXS : Theme.borderWidth
            border.color: plusHover.hovered ? Theme.primary : Theme.outline
        }

        // the plus glyph: two thin rounded bars crossed, sized off the button
        Rectangle {
            anchors.centerIn: parent
            width: parent.width * 0.5
            height: Theme.spacingXXS
            radius: height / 2
            color: plusHover.hovered ? Theme.primary : Theme.surfaceTextMedium
        }

        Rectangle {
            anchors.centerIn: parent
            width: Theme.spacingXXS
            height: parent.height * 0.5
            radius: width / 2
            color: plusHover.hovered ? Theme.primary : Theme.surfaceTextMedium
        }

        HoverHandler {
            id: plusHover
            // the same gates as a tile: hover once open, clicks through opening
            enabled: Overview.interactive
        }

        MouseArea {
            anchors.fill: parent
            enabled: Overview.clickable
            acceptedButtons: Qt.LeftButton
            onClicked: Overview.createWorkspace()
        }
    }

    // the one marker for the current workspace. it travels between tiles on the
    // same duration and easing as the exposé slide
    Rectangle {
        id: highlight

        visible: strip.activeCell !== null && strip.activeCell.w > 0
        x: strip.activeCell ? (strip.activeCell.x + strip.tileShiftX) : 0
        y: strip.activeCell ? strip.activeCell.y : 0
        width: strip.activeCell ? strip.activeCell.w : 0
        height: strip.activeCell ? strip.activeCell.h : 0
        color: "transparent"
        radius: Theme.cornerRadius
        border.width: Theme.spacingXXS
        border.color: Theme.primary

        Behavior on x {
            // snaps while the strip is off screen (preparing, opening, closed) and
            // travels only when it can be seen: open, and the close after a tile click
            enabled: Overview.interactive || Overview.state === "closing"
            NumberAnimation {
                duration: Config.switchMs
                easing.type: Config.switchCurve
            }
        }

        Behavior on width {
            enabled: Overview.interactive || Overview.state === "closing"
            NumberAnimation {
                duration: Config.switchMs
                easing.type: Config.switchCurve
            }
        }
    }
}
