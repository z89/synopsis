pragma ComponentBehavior: Bound

// the current workspace, unpacked. every thumb flies from its real rect to its
// layout rect on the one shared progress value.
//
// one persistent ListModel drives every thumb, so a delegate is created once per
// window address and survives refreshes and workspace switches. a refresh is a
// diff (remove, append, move); a switch while we are open retargets the rows
// already on screen instead of re-phasing them: every row carries its own
// startOff and endOff and rides the one eased `slide` value from the offset it
// had reached to where it now belongs. a row whose window is in the new set
// lands at 0 (it never gets a second row, whichever direction it was going),
// every other row leaves toward the side its own workspace sits on. nothing that
// is already showing a capture is ever destroyed and rebuilt, so no thumb can
// fall back to its placeholder mid-animation.
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

    // address -> window model object (every row in thumbModel, live or leaving)
    property var winMap: ({})
    // address -> exposé target rect, for live rows only
    property var targetMap: ({})
    // bumped whenever either map is replaced, so delegate lookups re-evaluate
    property int mapVersion: 0

    property real slide: 1
    // when the last slide started, for the rate-adaptive duration. 0 means none
    // yet in this overview, so the next slide is a full one
    property real lastSwitchAt: 0
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

    // the live windows, plus the ones still held by leaving rows
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
        const prevId = expose.lastActiveId;
        const switched = expose.primed && activeId !== prevId;
        // only a switch seen while the overview is up and interactive slides; the
        // refresh during preparing is the first look at the world, not a transition
        const sliding = switched && Overview.interactive && (expose.list.length > 0 || next.length > 0);
        // the same switch seen while preparing: nothing has flown yet, so the
        // old rows are dropped outright rather than slid, and the gate runs
        // again for the set that replaces them
        const reset = switched && !sliding && Overview.state === "preparing";
        // a higher id arrives from the right, like hyprland's own slide
        const arriveSign = ((activeId > prevId) !== Config.slideReverse) ? 1 : -1;
        if (sliding)
            expose.retargetRows(next, activeId, prevId);
        expose.lastActiveId = activeId;
        expose.primed = true;
        // a tile click asked for this switch: the flight starts back to the real
        // rects now, so the incoming thumbs land on the real windows
        if (sliding)
            Overview.noteWorkspaceSwitch(activeId);
        expose.list = next;
        expose.rebuildWinMap(next);
        if (sliding) {
            expose.appendMissing(next, activeId, arriveSign * expose.slideDistance);
            expose.orderRows(next);
        } else if (reset) {
            thumbModel.clear();
            expose.appendAll(next, activeId);
        } else {
            expose.diffRows(next, activeId);
        }
        expose.rebuildTargets();
        if (sliding)
            expose.startSlide(arriveSign);
        else if (reset)
            Overview.prepareReady();
        if (Config.frameLog)
            console.warn("[synopsis] " + Date.now() + " sync " + (m ? m.name : "") + " rows=" + thumbModel.count + " took " + (Date.now() - startedAt) + " ms");
    }

    function rowFor(addr: string): int {
        for (let r = 0; r < thumbModel.count; r++) {
            if (thumbModel.get(r).addr === addr)
                return r;
        }
        return -1;
    }

    // one row per address, always: a second row for a window that is already on
    // screen would draw it twice and capture the same toplevel twice
    function appendRow(addr: string, wsId: int, startOff: real) {
        if (expose.rowFor(addr) >= 0) {
            console.warn("[synopsis] duplicate row " + addr);
            return;
        }
        thumbModel.append({
            addr: addr,
            wsId: wsId,
            startOff: startOff,
            endOff: 0,
            fx: 0,
            fy: 0,
            fw: 0,
            fh: 0,
            fscale: 0
        });
    }

    function appendAll(next, wsId: int) {
        for (let i = 0; i < next.length; i++)
            expose.appendRow(next[i].address, wsId, 0);
    }

    // the windows of the new set that have no row yet: they enter from the side
    // the new workspace comes from
    function appendMissing(next, wsId: int, startOff: real) {
        for (let i = 0; i < next.length; i++) {
            if (expose.rowFor(next[i].address) < 0)
                expose.appendRow(next[i].address, wsId, startOff);
        }
    }

    // same workspace: remove what left, append what arrived, then permute the
    // live rows into stack order. every surviving delegate keeps its capture.
    function diffRows(next, wsId: int) {
        const wanted = {};
        for (let i = 0; i < next.length; i++)
            wanted[next[i].address] = true;
        for (let r = thumbModel.count - 1; r >= 0; r--) {
            const row = thumbModel.get(r);
            if (row.endOff === 0 && wanted[row.addr] === undefined)
                thumbModel.remove(r);
        }
        for (let a = 0; a < next.length; a++) {
            if (expose.rowFor(next[a].address) < 0)
                expose.appendRow(next[a].address, wsId, 0);
        }
        expose.orderRows(next);
    }

    // the live rows occupy the slots the live rows already hold; leaving rows
    // are never moved out of their own places
    function orderRows(next) {
        const slots = [];
        for (let r = 0; r < thumbModel.count; r++) {
            if (thumbModel.get(r).endOff === 0)
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

    // where a row is drawn right now, from its own row data: no item lookup, so
    // it is exact even for a row whose delegate has not been laid out yet
    function rowOffset(row): real {
        return row.startOff + (row.endOff - row.startOff) * expose.slide;
    }

    // a switch, possibly arriving mid-slide: every existing row restarts from the
    // offset it has reached and gets its own target. a row whose window is in the
    // new set comes back to 0 wherever it was going; every other row leaves toward
    // its own workspace's side, so nothing ever reverses across the screen.
    //
    // at most two workspace sets are on screen, like hyprland's own slide: the set
    // that was live until now (wsId === prevId) becomes the leaving set, and any
    // older set still sliding out is dropped where it stands. a window of such a
    // set that is also in the new set keeps its one row and turns around with the
    // rest, so the two-set cap never costs a capture and never makes a second row.
    function retargetRows(next, activeId: int, prevId: int) {
        const wanted = {};
        for (let i = 0; i < next.length; i++)
            wanted[next[i].address] = true;
        for (let r = thumbModel.count - 1; r >= 0; r--) {
            const row = thumbModel.get(r);
            const cur = expose.rowOffset(row);
            const leaving = row.endOff !== 0;
            if (wanted[row.addr] !== undefined) {
                // returning: the frozen rect equals the target at progress 1, so
                // handing it back to the live geometry is not a jump
                thumbModel.setProperty(r, "wsId", activeId);
                thumbModel.setProperty(r, "startOff", cur);
                thumbModel.setProperty(r, "endOff", 0);
                continue;
            }
            // an older workspace, still on its way out: it would be a third set
            if (leaving && row.wsId !== prevId) {
                thumbModel.remove(r);
                continue;
            }
            if (leaving && Math.abs(cur) >= expose.slideDistance) {
                thumbModel.remove(r);
                continue;
            }
            // a lower workspace sits to the left and leaves leftward
            const sign = ((row.wsId < activeId) !== Config.slideReverse) ? -1 : 1;
            if (!leaving)
                expose.freezeRow(r, items.itemAt(r));
            thumbModel.setProperty(r, "startOff", cur);
            thumbModel.setProperty(r, "endOff", sign * expose.slideDistance);
        }
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
    }

    // the slide landed: the rows that were leaving are gone, and every row that
    // stays is back at offset 0
    function dropOutgoing() {
        let dropped = false;
        for (let r = thumbModel.count - 1; r >= 0; r--) {
            if (thumbModel.get(r).endOff !== 0) {
                thumbModel.remove(r);
                dropped = true;
            } else if (thumbModel.get(r).startOff !== 0) {
                thumbModel.setProperty(r, "startOff", 0);
            }
        }
        if (dropped)
            expose.rebuildWinMap(expose.list);
    }

    function countLeaving(): int {
        let n = 0;
        for (let r = 0; r < thumbModel.count; r++) {
            if (thumbModel.get(r).endOff !== 0)
                n++;
        }
        return n;
    }

    // the longest travel still ahead, in pixels
    function maxTravel(): real {
        let far = 0;
        for (let r = 0; r < thumbModel.count; r++) {
            const row = thumbModel.get(r);
            const d = Math.abs(row.endOff - row.startOff);
            if (d > far)
                far = d;
        }
        return far;
    }

    function startSlide(arriveSign: int) {
        slideAnim.stop();
        if (!expose.sliding) {
            expose.sliding = true;
            Overview.slidesRunning++;
        }
        const now = Date.now();
        // -1 is "no previous switch this overview": the first slide is always full
        const interval = expose.lastSwitchAt > 0 ? now - expose.lastSwitchAt : -1;
        expose.lastSwitchAt = now;
        // a burst of switches barely moves the rows: scale the duration by the
        // longest remaining travel so it finishes promptly instead of ramping
        const far = expose.slideDistance > 0 ? expose.maxTravel() / expose.slideDistance : 1;
        // a config with switchMinMs above switchMs would otherwise make a spam
        // slide outlast a normal one: the floor never rises above the full length
        const floorMs = Math.min(Config.switchMinMs, Config.switchMs);
        if (interval < 0 || interval >= Config.switchMs) {
            // a single switch, or one interrupting a slide that had time to run:
            // exactly the rule that was here before, untouched
            slideAnim.duration = Math.round(Config.switchMs * Math.max(0.45, Math.min(1, far)));
        } else {
            // switches are coming faster than a slide can finish: this one is sized
            // to the gap the user is actually leaving, so the last of a burst is
            // still on screen rather than a queue of half-finished slides
            const paced = Math.max(floorMs, Math.min(Config.switchMs, interval * Config.switchSpamFactor));
            slideAnim.duration = Math.round(Math.max(floorMs, paced * Math.max(0.45, Math.min(1, far))));
        }
        expose.slide = 0;
        slideAnim.start();
        const leaving = expose.countLeaving();
        console.warn("[synopsis] " + now + " slide " + (expose.mon ? expose.mon.name : "") + " arrive=" + arriveSign + " interval=" + interval + " dur=" + slideAnim.duration + " live=" + (thumbModel.count - leaving) + " leaving=" + leaving);
    }

    function endSlide() {
        slideAnim.stop();
        // the overview went away: the next one starts with no switch history, so a
        // reopen right after a burst still gets a full slide
        expose.lastSwitchAt = 0;
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
            required property real startOff
            required property real endOff
            required property real fx
            required property real fy
            required property real fw
            required property real fh
            required property real fscale

            readonly property bool leaving: thumb.endOff !== 0
            readonly property var winData: expose.winFor(thumb.addr, expose.mapVersion)
            readonly property var tgt: expose.targetFor(thumb.addr, expose.mapVersion)

            win: thumb.winData
            interactive: !thumb.leaving
            gated: !thumb.leaving
            // a row on its way out keeps its last frame: a live capture for a
            // workspace the user has already left is work nobody sees, and during
            // a burst it is several of them at once
            wantLive: !thumb.leaving
            // and it draws under the set that is arriving, never over it
            demoted: thumb.leaving
            thumbScale: thumb.leaving ? thumb.fscale : 1 + ((thumb.tgt ? thumb.tgt.scale : 1) - 1) * expose.progress
            geoX: thumb.leaving ? thumb.fx : (thumb.winData ? thumb.winData.x + ((thumb.tgt ? thumb.tgt.x : thumb.winData.x) - thumb.winData.x) * expose.progress : 0)
            geoY: thumb.leaving ? thumb.fy : (thumb.winData ? thumb.winData.y + ((thumb.tgt ? thumb.tgt.y : thumb.winData.y) - thumb.winData.y) * expose.progress : 0)
            geoW: thumb.leaving ? thumb.fw : (thumb.winData ? thumb.winData.w + ((thumb.tgt ? thumb.tgt.w : thumb.winData.w) - thumb.winData.w) * expose.progress : 0)
            geoH: thumb.leaving ? thumb.fh : (thumb.winData ? thumb.winData.h + ((thumb.tgt ? thumb.tgt.h : thumb.winData.h) - thumb.winData.h) * expose.progress : 0)
            offsetX: thumb.startOff + (thumb.endOff - thumb.startOff) * expose.slide
        }
    }
}
