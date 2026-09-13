pragma ComponentBehavior: Bound

// the current workspace, unpacked. every thumb flies from its real rect to its
// layout rect on the one shared progress value.
//
// a workspace switch while we are open is a slide, not a rebuild: the set on the
// way out keeps the geometry it had and translates off one side, the set on the
// way in starts off the other side and lands on its exposé targets. the live set
// is only replaced when the model's exposé signature changed, so nothing is
// destroyed and recreated for a switch that leaves the same windows on screen.

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
    property real margin: 0

    property var list: []
    property string lastSig: ""
    property int lastActiveId: 0
    property bool primed: false

    // frozen copies of the outgoing thumbs: model, rendered rect and scale
    property var outgoingList: []
    property real slide: 1
    property int slideDir: 1
    // a full screen width moves any on-screen thumb fully off screen, like hyprland's slide
    property real screenW: 0
    readonly property real slideDistance: expose.screenW > 0 ? expose.screenW : expose.areaW + expose.margin

    readonly property bool overviewActive: Overview.active

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

    // one handler for the whole model, so the active workspace and the signature
    // are never read a binding apart
    onMonChanged: expose.sync()
    Component.onCompleted: expose.sync()

    onOverviewActiveChanged: {
        if (!expose.overviewActive)
            expose.endSlide();
    }

    function sync() {
        const m = expose.mon;
        const next = m ? m.expose : [];
        const sig = m ? (m.exposeSig || "") : "";
        const activeId = m ? m.activeId : 0;
        const switched = expose.primed && activeId !== expose.lastActiveId;
        // only a switch seen while the overview is up and interactive slides; the
        // refresh during preparing is the first look at the world, not a transition
        const sliding = switched && Overview.interactive && (expose.list.length > 0 || next.length > 0);
        if (sliding) {
            expose.freezeOutgoing();
            // higher id slides left to right, like hyprland's own slide
            expose.slideDir = ((activeId > expose.lastActiveId) !== Config.slideReverse) ? 1 : -1;
        }
        expose.lastActiveId = activeId;
        expose.primed = true;
        // a tile click asked for this switch: the flight starts back to the real
        // rects now, so the incoming thumbs land on the real windows
        if (sliding)
            Overview.noteWorkspaceSwitch(activeId);
        if (sig !== expose.lastSig) {
            expose.lastSig = sig;
            expose.list = next;
        }
        if (sliding)
            expose.startSlide();
    }

    // itemAt() is typed QQuickItem; an untyped parameter keeps the call unchecked
    function freezeThumb(item, out) {
        if (!item || !item.visible)
            return;
        out.push({
            win: item.win,
            x: item.x,
            y: item.y,
            w: item.width,
            h: item.height,
            scale: item.thumbScale
        });
    }

    // a switch arriving mid-slide: whatever is on screen right now becomes the
    // outgoing set at exactly the offset it has reached
    function freezeOutgoing() {
        const out = [];
        for (let i = 0; i < items.count; i++)
            expose.freezeThumb(items.itemAt(i), out);
        expose.outgoingList = out;
    }

    function startSlide() {
        slideAnim.stop();
        if (!expose.sliding) {
            expose.sliding = true;
            Overview.slidesRunning++;
        }
        expose.slide = 0;
        slideAnim.start();
        console.warn("[synopsis] slide " + (expose.mon ? expose.mon.name : "") + " dir=" + expose.slideDir + " out=" + expose.outgoingList.length + " in=" + expose.list.length);
    }

    function endSlide() {
        slideAnim.stop();
        expose.slide = 1;
        expose.outgoingList = [];
        expose.slideDone();
    }

    // the close path waits for the slide, so its last frames never snap
    property bool sliding: false

    function slideDone() {
        if (!expose.sliding)
            return;
        expose.sliding = false;
        Overview.slidesRunning--;
        Overview.noteSlideFinished();
    }

    NumberAnimation {
        id: slideAnim
        target: expose
        property: "slide"
        from: 0
        to: 1
        duration: Config.switchMs
        easing.type: Config.switchCurve
        onFinished: {
            expose.outgoingList = [];
            expose.slideDone();
        }
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
            offsetX: expose.slideDir * expose.slideDistance * (1 - expose.slide)
        }
    }

    // the set on its way out. frozen geometry, no input, no live capture, gone the
    // moment the slide finishes
    Repeater {
        id: outgoing
        model: expose.outgoingList

        delegate: WindowThumb {
            required property var modelData

            win: modelData.win
            interactive: false
            gated: false
            wantLive: false
            thumbScale: modelData.scale
            geoX: modelData.x
            geoY: modelData.y
            geoW: modelData.w
            geoH: modelData.h
            offsetX: -expose.slideDir * expose.slideDistance * expose.slide
        }
    }
}
