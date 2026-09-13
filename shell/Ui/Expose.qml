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
    readonly property real screenSpan: expose.screenW > 0 ? expose.screenW : expose.areaW + expose.margin
    // how far a leaving set actually travels: recomputed at every switch from
    // the travel the two sets need to clear the screen in the slide direction
    // (computeSlideDistance), so the leaving set is fully off before it is
    // dropped while the midpoint of an ultrawide slide still shows one of them
    property real slideDistance: expose.screenSpan

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

    readonly property string overviewState: Overview.state

    // the close flight has taken over the picture: land the slide inside it
    onOverviewStateChanged: {
        if (expose.overviewState === "closing")
            expose.closeSlide();
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
        // a switch seen once the overview is on screen slides, the opening
        // flight included: the offsets ride on top of the flight rather than
        // fighting it (WindowThumb draws x = geoX + offsetX, and geoX is the
        // flight), so an arriving set unpacks out of its real rects while it
        // slides in. the refresh during preparing is the first look at the
        // world, not a transition, and a switch during closing belongs to the
        // close, which retargets the running slide itself
        const onScreen = Overview.state === "open" || Overview.state === "opening";
        const sliding = switched && onScreen && (expose.list.length > 0 || next.length > 0);
        // the same switch seen while preparing: nothing has flown yet, so the
        // old rows are dropped outright rather than slid, and the gate runs
        // again for the set that replaces them
        const reset = switched && !sliding && Overview.state === "preparing";
        // a higher id arrives from the right, like hyprland's own slide
        const arriveSign = ((activeId > prevId) !== Config.slideReverse) ? 1 : -1;
        if (sliding) {
            // every offset set below is a multiple of this, so the distance for
            // this switch is fixed before the first row is retargeted
            expose.slideDistance = expose.computeSlideDistance(next, arriveSign);
            expose.retargetRows(next, activeId, prevId);
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
    //
    // `dist` is the slide distance this row was launched with. it is stored per
    // row because slideDistance is recomputed at every switch: a row that left a
    // wide workspace is a full screen width out while a switch into a narrow one
    // has just made the distance smaller, and comparing it against the new
    // distance would call it finished and delete it mid-flight. a retargeted row
    // gets the new distance, since that is the one it is now travelling
    function appendRow(addr: string, wsId: int, startOff: real, dist: real) {
        if (expose.rowFor(addr) >= 0) {
            console.warn("[synopsis] duplicate row " + addr);
            return;
        }
        thumbModel.append({
            addr: addr,
            wsId: wsId,
            startOff: startOff,
            endOff: 0,
            dist: dist,
            fx: 0,
            fy: 0,
            fw: 0,
            fh: 0,
            fscale: 0
        });
    }

    function appendAll(next, wsId: int) {
        for (let i = 0; i < next.length; i++)
            expose.appendRow(next[i].address, wsId, 0, expose.slideDistance);
    }

    // the windows of the new set that have no row yet: they enter from the side
    // the new workspace comes from
    function appendMissing(next, wsId: int, startOff: real) {
        for (let i = 0; i < next.length; i++) {
            if (expose.rowFor(next[i].address) < 0)
                expose.appendRow(next[i].address, wsId, startOff, expose.slideDistance);
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
                expose.appendRow(next[a].address, wsId, 0, expose.slideDistance);
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
                thumbModel.setProperty(r, "dist", expose.slideDistance);
                continue;
            }
            // an older workspace, still on its way out: it would be a third set
            if (leaving && row.wsId !== prevId) {
                thumbModel.remove(r);
                continue;
            }
            // against the distance this row was launched with, never the one
            // this switch just computed: a narrower new set must not delete rows
            // that are still on screen on their way out of a wider one
            if (leaving && Math.abs(cur) >= row.dist) {
                thumbModel.remove(r);
                continue;
            }
            // a lower workspace sits to the left and leaves leftward
            const sign = ((row.wsId < activeId) !== Config.slideReverse) ? -1 : 1;
            if (!leaving)
                expose.freezeRow(r, items.itemAt(r));
            thumbModel.setProperty(r, "startOff", cur);
            thumbModel.setProperty(r, "endOff", sign * expose.slideDistance);
            thumbModel.setProperty(r, "dist", expose.slideDistance);
        }
    }

    // itemAt() is typed QQuickItem; an untyped parameter keeps the call
    // unchecked. item.x is geoX + offsetX and a frozen row keeps riding an
    // offset, so what is frozen is the geometry alone: otherwise the offset of a
    // row caught mid-slide would be counted twice
    function freezeRow(row, item) {
        if (!item)
            return;
        thumbModel.setProperty(row, "fx", item.x - expose.rowOffset(thumbModel.get(row)));
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

    // every row on its way out, gone at once. used only while the close flight
    // is running: a leaving row is an exposé-sized thumb of a workspace that is
    // not there any more, sliding underneath the rows flying home
    function dropLeaving(): bool {
        let dropped = false;
        for (let r = thumbModel.count - 1; r >= 0; r--) {
            if (thumbModel.get(r).endOff !== 0) {
                thumbModel.remove(r);
                dropped = true;
            }
        }
        if (dropped)
            expose.rebuildWinMap(expose.list);
        return dropped;
    }

    // how long a slide may still take once the close flight is running. the
    // flight runs from the current progress to 0 over flightMs * progress
    // (Overview.runFlight), and WindowThumb draws x = geoX + offsetX: the flight
    // only lands geoX on the real window, so an offset still left at progress 0
    // is a window drawn beside itself and shifted after the fact. 0.8 keeps a
    // margin for the rounding at both ends
    function closingCap(): real {
        const flightLeft = Config.flightMs * Math.max(0, Math.min(1, Overview.progress));
        return 0.8 * Math.min(Config.flightMs, flightLeft);
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

    // ---- slide distance ---------------------------------------------------

    // where the layout would put a set of windows, as its bounds in x: {lo, hi},
    // or null for an empty set. the arriving set is measured here because its
    // rows do not exist yet, and the layout is the same computation `targets`
    // will run a moment later. monitor-local, like every rect in this file:
    // Overview stores window x as at[0] - monitor.x and the layout places the
    // targets inside areaX, which is window-local on a per-monitor overlay
    function exposeBounds(set): var {
        if (!set || set.length === 0)
            return null;
        const t = Layout.computeExpose(set.map(function (w) {
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
        });
        let lo = Infinity;
        let hi = -Infinity;
        for (let i = 0; i < t.length; i++) {
            if (t[i].x < lo)
                lo = t[i].x;
            if (t[i].x + t[i].w > hi)
                hi = t[i].x + t[i].w;
        }
        return hi > lo ? {
            lo: lo,
            hi: hi
        } : null;
    }

    // the bounds of the rows that are about to leave, measured from their exposé
    // rest rects and never from a delegate's animated x: during the opening
    // flight item.x is the flight-interpolated position, which is the real
    // window rect at progress 0, so measuring it there collapsed the bounds and
    // with it the travel. a live row's rest rect is its exposé target, a row
    // already leaving keeps its frozen rect (fx/fw)
    function leavingBounds(next): var {
        const wanted = {};
        for (let i = 0; i < next.length; i++)
            wanted[next[i].address] = true;
        let lo = Infinity;
        let hi = -Infinity;
        for (let r = 0; r < thumbModel.count; r++) {
            const row = thumbModel.get(r);
            if (wanted[row.addr] !== undefined)
                continue;
            let x = 0;
            let w = 0;
            if (row.endOff !== 0) {
                x = row.fx;
                w = row.fw;
            } else {
                const t = expose.targetMap[row.addr] || expose.winMap[row.addr];
                if (!t)
                    continue;
                x = t.x;
                w = t.w;
            }
            if (x < lo)
                lo = x;
            if (x + w > hi)
                hi = x + w;
        }
        return hi > lo ? {
            lo: lo,
            hi: hi
        } : null;
    }

    // how far both sets have to travel for the switch to read as one slide: the
    // leaving set must clear the screen edge it is heading for, and the arriving
    // set must start fully off the edge it comes from. a set's own width is not
    // that distance - a leaving set centred on a 5120 px screen with a 2764 px
    // span still had 1180 px of screen to cross on each side, so it was dropped
    // (|offset| >= its dist) while it was still plainly visible.
    //
    // arriveSign = +1: the new set comes from the right and the old one goes
    // left, so the old one travels its right edge (hi) and the new one must
    // start at least screen - lo out. arriveSign = -1 mirrors it. the max of the
    // two plus the gap is the shortest distance that satisfies both, which keeps
    // one set on screen through the midpoint instead of emptying it
    function computeSlideDistance(next, arriveSign: int): real {
        const screen = expose.screenSpan;
        const leave = expose.leavingBounds(next);
        const arrive = expose.exposeBounds(next);
        let travel = -1;
        if (leave)
            travel = arriveSign >= 0 ? leave.hi : screen - leave.lo;
        if (arrive) {
            const enter = arriveSign >= 0 ? screen - arrive.lo : arrive.hi;
            if (enter > travel)
                travel = enter;
        }
        // neither side has a measurable rect: a full screen is always enough
        if (travel < 0 || screen <= 0)
            return screen > 0 ? screen : expose.screenSpan;
        return Math.max(0, Math.min(screen, travel + Config.slideGap));
    }

    function startSlide(arriveSign: int) {
        slideAnim.stop();
        // a tile click switches and closes in the same breath, so this slide can
        // begin with the close flight already running: the leaving set goes now
        // and the travel below is only the arriving rows'
        const closing = Overview.state === "closing";
        if (closing)
            expose.dropLeaving();
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
        if (closing) {
            const cap = expose.closingCap();
            if (cap < 1) {
                // the close began this early in the opening flight: the flight
                // has a millisecond or less left, so there is no room for a
                // slide at all. land it now, exactly as closeSlide does for
                // dur < 1 - every row at its end offset, leaving rows gone -
                // rather than running the full switchMs under a flight that
                // has already arrived, which leaves thumbs beside their windows
                const leavingNow = expose.countLeaving();
                console.warn("[synopsis] " + now + " slide " + (expose.mon ? expose.mon.name : "") + " arrive=" + arriveSign + " interval=" + interval + " dur=0 live=" + (thumbModel.count - leavingNow) + " leaving=" + leavingNow + " dist=" + Math.round(expose.slideDistance));
                expose.endSlide();
                return;
            }
            slideAnim.duration = Math.max(1, Math.min(slideAnim.duration, Math.round(cap)));
        }
        expose.slide = 0;
        slideAnim.start();
        const leaving = expose.countLeaving();
        console.warn("[synopsis] " + now + " slide " + (expose.mon ? expose.mon.name : "") + " arrive=" + arriveSign + " interval=" + interval + " dur=" + slideAnim.duration + " live=" + (thumbModel.count - leaving) + " leaving=" + leaving + " dist=" + Math.round(expose.slideDistance));
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

    // the close flight is drawing every row back onto its real window, and it is
    // what the eye follows now. so the leaving rows go at once - they are
    // exposé-sized thumbs of a workspace that is no longer there, sliding under
    // the flight - and the rows that stay come home inside the flight, because
    // WindowThumb draws x = geoX + offsetX and the flight only lands geoX on the
    // real window: any offset left over at progress 0 is a window drawn beside
    // itself, then snapped late.
    function closeSlide() {
        if (!expose.sliding)
            return;
        const remaining = slideAnim.duration * (1 - expose.slide);
        let dropped = false;
        for (let r = thumbModel.count - 1; r >= 0; r--) {
            const row = thumbModel.get(r);
            if (row.endOff !== 0) {
                thumbModel.remove(r);
                dropped = true;
                continue;
            }
            // restart from where it is, still aiming at 0
            thumbModel.setProperty(r, "startOff", expose.rowOffset(row));
        }
        if (dropped)
            expose.rebuildWinMap(expose.list);
        const dur = Math.min(remaining, expose.closingCap());
        if (Config.frameLog)
            console.warn("[synopsis] " + Date.now() + " closeslide remaining=" + Math.round(remaining) + " dur=" + Math.round(dur) + " rows=" + thumbModel.count);
        if (dur < 1) {
            // nothing worth animating, and nothing may be left hanging: land it
            expose.endSlide();
            return;
        }
        slideAnim.stop();
        slideAnim.duration = Math.round(dur);
        expose.slide = 0;
        slideAnim.start();
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
