pragma ComponentBehavior: Bound

// the current workspace, unpacked. every thumb flies from its real rect to its
// layout rect on the one shared progress value.

import QtQuick
import qs.Core
import "../Core/Layout.js" as Layout

Item {
    id: expose

    property var mon: null
    property real progress: 0
    property real areaX: 0
    property real areaY: 0
    property real areaW: 0
    property real areaH: 0

    readonly property var list: expose.mon ? expose.mon.expose : []
    readonly property var targets: Layout.computeExpose(expose.list.map(function (w) {
        return {
            id: w.address,
            x: w.x,
            y: w.y,
            w: w.w,
            h: w.h
        };
    }), {
        x: expose.areaX,
        y: expose.areaY,
        w: expose.areaW,
        h: expose.areaH
    }, {
        spacing: Config.exposeSpacing,
        maxScale: Config.exposeMaxScale
    })

    onTargetsChanged: {
        if (Config.frameLog)
            console.warn("[synopsis] targets " + expose.areaW + "x" + expose.areaH + " " + JSON.stringify(expose.list.map(function (w) { return [w.x, w.y, w.w, w.h]; })) + " -> " + JSON.stringify(expose.targets.map(function (t) { return [Math.round(t.x), Math.round(t.y), Math.round(t.w), Math.round(t.h)]; })));
    }

    Repeater {
        id: items
        model: expose.list

        delegate: WindowThumb {
            id: thumb
            required property int index
            required property var modelData

            readonly property var target: expose.targets[index] || ({
                    x: modelData.x,
                    y: modelData.y,
                    w: modelData.w,
                    h: modelData.h,
                    scale: 1
                })

            win: modelData
            interactive: true
            gated: true
            wantLive: true
            thumbScale: 1 + (target.scale - 1) * expose.progress
            geoX: modelData.x + (target.x - modelData.x) * expose.progress
            geoY: modelData.y + (target.y - modelData.y) * expose.progress
            geoW: modelData.w + (target.w - modelData.w) * expose.progress
            geoH: modelData.h + (target.h - modelData.h) * expose.progress
        }
    }
}
