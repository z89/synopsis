pragma ComponentBehavior: Bound

// the current workspace, unpacked. every thumb flies from its real rect to its
// layout rect on the one shared progress value.
//
// one persistent ListModel drives every thumb, so a delegate is created once per
// window address and survives refreshes and workspace switches. a refresh is a
// diff (remove, append, move); a switch while we are open flips the rows already
// on screen to phase "out" with their rendered geometry frozen and appends the
// new set as phase "in" rows that start off the other side. nothing that is
// already showing a capture is ever destroyed and rebuilt, so no thumb can fall
// back to its placeholder mid-animation.
//
// window data and layout targets live in plain maps keyed by address; the
// delegates read them through mapVersion so a rebuilt map re-evaluates bindings
// without touching the rows.

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

    // the live set, in stack order: the model objects from mon.expose
    property var list: []
    property int lastActiveId: 0
    property bool primed: false

    // address -> window model object (every row in thumbModel, in or out)
    property var winMap: ({})
    // address -> exposé target rect, for phase "in" rows only
    property var targetMap: ({})
    // bumped whenever either map is replaced, so delegate lookups re-evaluate
    property int mapVersion: 0

    property real slide: 1
    property int slideDir: 1
    // a full screen width moves any on-screen thumb fully off screen, like hyprland's slide
    property real screenW: 0
    readonly property real slideDistance: expose.screenW > 0 ? expose.screenW : expose.areaW + expose.margin

    readonly property bool overviewActive: Overview.active

    // the world moved while we were preparing: every row is still drawn at the
    // rect of a window that is no longer there, over a transparent backdrop.
    // opacity, not visible: a hidden subtree may stop feeding the captures the
    // gate is waiting for, and a thumb captures fine at opacity 0 (WindowThumb)
    opacity: (Overview.state === "preparing" && Overview.prepareDirty) ? 0 : 1

    ListModel {
        id: thumbModel
        dynamicRoles: false
    }

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

    // the area or the live set changed: republish the target map, same rows
    onTargetsChanged: {
        expose.rebuildTargets();
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

    // ---- lookups ---------------------------------------------------------

    // version is the binding dependency on mapVersion, nothing more
    function winFor(addr: string, version: int): var {
        return expose.winMap[addr] || null;
    }

    function targetFor(addr: string, version: int): var {
        return expose.targetMap[addr] || null;
    }

    function rebuildTargets() {
        const map = {};
        const live = expose.list;
        const t = expose.targets;
        for (let i = 0; i < live.length; i++) {
            const w = live[i];
            map[w.address] = t[i] || {
                x: w.x,
                y: w.y,
                w: w.w,
                h: w.h,
                scale: 1
            };
        }
        expose.targetMap = map;
        expose.mapVersion++;
    }

    // the live windows, plus the ones still held by outgoing rows
    function rebuildWinMap(next) {
        const map = {};
        for (let i = 0; i < next.length; i++)
            map[next[i].address] = next[i];
        const old = expose.winMap;
        for (let r = 0; r < thumbModel.count; r++) {
            const addr = thumbModel.get(r).addr;
            if (map[addr] === undefined && old[addr] !== undefined)
                map[addr] = old[addr];
        }
        expose.winMap = map;
        expose.mapVersion++;
    }

    // ---- sync ------------------------------------------------------------

    function sync() {
        const startedAt = Date.now();
        const m = expose.mon;
        const next = m ? m.expose : [];
        const activeId = m ? m.activeId : 0;
        const switched = expose.primed && activeId !== expose.lastActiveId;
        // only a switch seen while the overview is up and interactive slides; the
        // refresh during preparing is the first look at the world, not a transition
        const sliding = switched && Overview.interactive && (expose.list.length > 0 || next.length > 0);
        // the same switch seen while preparing: nothing has flown yet, so the
        // old rows are dropped outright rather than slid, and the gate runs
        // again for the set that replaces them
        const reset = switched && !sliding && Overview.state === "preparing";
        if (sliding) {
            // freeze first: slideDir feeds the live rows' offset, and flipping it
            // before the freeze would teleport them mid-slide
            expose.freezeRows();
            // higher id slides left to right, like hyprland's own slide
            expose.slideDir = ((activeId > expose.lastActiveId) !== Config.slideReverse) ? 1 : -1;
        }
        expose.lastActiveId = activeId;
        expose.primed = true;
        // a tile click asked for this switch: the flight starts back to the real
        // rects now, so the incoming thumbs land on the real windows
        if (sliding)
            Overview.noteWorkspaceSwitch(activeId);
        expose.list = next;
        expose.rebuildWinMap(next);
        if (sliding) {
            expose.appendAll(next);
        } else if (reset) {
            thumbModel.clear();
            expose.appendAll(next);
        } else {
            expose.diffRows(next);
        }
        expose.rebuildTargets();
        if (sliding)
            expose.startSlide();
        else if (reset)
            Overview.prepareReady();
        if (Config.frameLog)
            console.warn("[synopsis] " + Date.now() + " sync " + (m ? m.name : "") + " rows=" + thumbModel.count + " took " + (Date.now() - startedAt) + " ms");
    }

    function appendRow(addr: string) {
        thumbModel.append({
            addr: addr,
            phase: "in",
            fx: 0,
            fy: 0,
            fw: 0,
            fh: 0,
            fscale: 0
        });
    }

    function appendAll(next) {
        for (let i = 0; i < next.length; i++)
            expose.appendRow(next[i].address);
    }

    // same workspace: remove what left, append what arrived, then permute the
    // live rows into stack order. every surviving delegate keeps its capture.
    function diffRows(next) {
        const wanted = {};
        for (let i = 0; i < next.length; i++)
            wanted[next[i].address] = true;
        for (let r = thumbModel.count - 1; r >= 0; r--) {
            const row = thumbModel.get(r);
            if (row.phase === "in" && wanted[row.addr] === undefined)
                thumbModel.remove(r);
        }
        const have = {};
        for (let k = 0; k < thumbModel.count; k++) {
            const kept = thumbModel.get(k);
            if (kept.phase === "in")
                have[kept.addr] = true;
        }
        for (let a = 0; a < next.length; a++) {
            if (have[next[a].address] === undefined)
                expose.appendRow(next[a].address);
        }
        expose.orderRows(next);
    }

    // the live rows occupy the slots the live rows already hold; outgoing rows
    // are never moved out of their own places
    function orderRows(next) {
        const slots = [];
        for (let r = 0; r < thumbModel.count; r++) {
            if (thumbModel.get(r).phase === "in")
                slots.push(r);
        }
        for (let j = 0; j < next.length && j < slots.length; j++) {
            const dest = slots[j];
            if (thumbModel.get(dest).addr === next[j].address)
                continue;
            let from = -1;
            for (let k = j + 1; k < slots.length && from < 0; k++) {
                if (thumbModel.get(slots[k]).addr === next[j].address)
                    from = slots[k];
            }
            if (from >= 0)
                thumbModel.move(from, dest, 1);
        }
    }

    // ---- slide -----------------------------------------------------------

    // a switch, possibly arriving mid-slide: whatever is on screen right now
    // becomes the outgoing set at exactly the offset it has reached, so a second
    // switch continues from the current position instead of snapping back
    function freezeRows() {
        for (let r = 0; r < thumbModel.count; r++)
            expose.freezeRow(r, items.itemAt(r));
    }

    // itemAt() is typed QQuickItem; an untyped parameter keeps the call unchecked
    function freezeRow(row, item) {
        if (!item)
            return;
        thumbModel.setProperty(row, "fx", item.x);
        thumbModel.setProperty(row, "fy", item.y);
        thumbModel.setProperty(row, "fw", item.width);
        thumbModel.setProperty(row, "fh", item.height);
        thumbModel.setProperty(row, "fscale", item.thumbScale);
        thumbModel.setProperty(row, "phase", "out");
    }

    function dropOutgoing() {
        let dropped = false;
        for (let r = thumbModel.count - 1; r >= 0; r--) {
            if (thumbModel.get(r).phase === "out") {
                thumbModel.remove(r);
                dropped = true;
            }
        }
        if (dropped)
            expose.rebuildWinMap(expose.list);
    }

    function countPhase(phase: string): int {
        let n = 0;
        for (let r = 0; r < thumbModel.count; r++) {
            if (thumbModel.get(r).phase === phase)
                n++;
        }
        return n;
    }

    function startSlide() {
        slideAnim.stop();
        if (!expose.sliding) {
            expose.sliding = true;
            Overview.slidesRunning++;
        }
        expose.slide = 0;
        slideAnim.start();
        console.warn("[synopsis] slide " + (expose.mon ? expose.mon.name : "") + " dir=" + expose.slideDir + " out=" + expose.countPhase("out") + " in=" + expose.countPhase("in"));
    }

    function endSlide() {
        slideAnim.stop();
        expose.slide = 1;
        expose.dropOutgoing();
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
            expose.dropOutgoing();
            expose.slideDone();
        }
    }

    Repeater {
        id: items
        model: thumbModel

        delegate: WindowThumb {
            id: thumb
            required property string addr
            required property string phase
            required property real fx
            required property real fy
            required property real fw
            required property real fh
            required property real fscale

            readonly property bool leaving: thumb.phase === "out"
            readonly property var winData: expose.winFor(thumb.addr, expose.mapVersion)
            readonly property var tgt: expose.targetFor(thumb.addr, expose.mapVersion)

            win: thumb.winData
            interactive: !thumb.leaving
            gated: !thumb.leaving
            wantLive: true
            thumbScale: thumb.leaving ? thumb.fscale : 1 + ((thumb.tgt ? thumb.tgt.scale : 1) - 1) * expose.progress
            geoX: thumb.leaving ? thumb.fx : (thumb.winData ? thumb.winData.x + ((thumb.tgt ? thumb.tgt.x : thumb.winData.x) - thumb.winData.x) * expose.progress : 0)
            geoY: thumb.leaving ? thumb.fy : (thumb.winData ? thumb.winData.y + ((thumb.tgt ? thumb.tgt.y : thumb.winData.y) - thumb.winData.y) * expose.progress : 0)
            geoW: thumb.leaving ? thumb.fw : (thumb.winData ? thumb.winData.w + ((thumb.tgt ? thumb.tgt.w : thumb.winData.w) - thumb.winData.w) * expose.progress : 0)
            geoH: thumb.leaving ? thumb.fh : (thumb.winData ? thumb.winData.h + ((thumb.tgt ? thumb.tgt.h : thumb.winData.h) - thumb.winData.h) * expose.progress : 0)
            offsetX: thumb.leaving ? -expose.slideDir * expose.slideDistance * expose.slide : expose.slideDir * expose.slideDistance * (1 - expose.slide)
        }
    }
}
