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
    readonly property var tileLayout: Layout.computeStrip(strip.tileModel.length, strip.aspect, {
        x: strip.areaX,
        y: strip.areaY,
        w: strip.areaW,
        h: strip.areaH
    }, {
        gap: Config.stripGap,
        maxTileHeight: strip.areaH
    })

    readonly property int activeIndex: strip.indexOfWorkspace(strip.tileModel, strip.activeId, strip.specialId)
    readonly property var activeCell: (strip.activeIndex >= 0) ? (strip.tileLayout.tiles[strip.activeIndex] || null) : null

    opacity: strip.progress
    // off the top edge at rest, in place at full progress
    y: (strip.progress - 1) * (strip.areaY + strip.areaH)

    onWsSigChanged: strip.syncTiles()
    Component.onCompleted: strip.syncTiles()

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
            x: cell.x
            y: cell.y
            width: cell.w
            height: cell.h
            visible: cell.w > 0
        }
    }

    // the one marker for the current workspace. it travels between tiles on the
    // same duration and easing as the exposé slide
    Rectangle {
        id: highlight

        visible: strip.activeCell !== null && strip.activeCell.w > 0
        x: strip.activeCell ? strip.activeCell.x : 0
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
