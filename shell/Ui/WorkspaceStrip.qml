pragma ComponentBehavior: Bound

// the strip of workspace tiles. it descends from the top with the scrim.

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

    readonly property var list: strip.mon ? strip.mon.workspaces : []
    readonly property real aspect: (strip.mon && strip.mon.h > 0) ? (strip.mon.w / strip.mon.h) : 1
    readonly property var tileLayout: Layout.computeStrip(strip.list.length, strip.aspect, {
        x: strip.areaX,
        y: strip.areaY,
        w: strip.areaW,
        h: strip.areaH
    }, {
        gap: Config.stripGap,
        maxTileHeight: strip.areaH
    })

    opacity: strip.progress
    // off the top edge at rest, in place at full progress
    y: (strip.progress - 1) * (strip.areaY + strip.areaH)

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
        model: strip.list

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
            current: modelData.current
            x: cell.x
            y: cell.y
            width: cell.w
            height: cell.h
            visible: cell.w > 0
        }
    }
}
