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
    // slideAnim's linear time fraction; slide is its eased value, one lookup
    // per frame for every row. the table and its time scale are snapshotted
    // when a slide starts (curveFor), so a config reload cannot swap them
    // under it. slide may overshoot 1 on a spring: it is an offset, not state
    property real slideT: 1
    property var slideLut: Config.switchLut
    property real slideScale: 1
    property bool slideHypr: false
    // a row is drawn at startOff + (endOff - startOff) * slide + startVel *
    // slideB: slideB (ms) carries the velocity a row had when a running slide
    // was interrupted, so the new motion leaves from where the row was and as
    // fast as it was going (continueSlide). 0 for a slide from rest
    property real slideB: 0
    // what slideT is mapped through: 0 the table from rest (slideLut), 1
    // hyprland's spring continued from each row's offset and velocity, 2 a
    // cubic hermite to each row's end over slideDur (no spring, or the close)
    // for the rows that carry a velocity, while the rows with none stay on the
    // table: a row arriving from rest starts as it would in any other slide
    property int slideMode: 0
    // slide for a row with a velocity (startVel !== 0): the hermite's in mode
    // 2, the same value as slide otherwise. a row reads one of the two
    property real slideH: 1
    // slideAnim.duration of the running slide, in ms
    property real slideDur: 1
    // the continued spring, fixed when it starts: angular frequency squared,
    // half the damping rate, and the damped (or overdamped) roots
    property real springW2: 1
    property real springG: 0
    property real springWd: 0
    property int springKind: 0
    // one spring evaluation, written here rather than returned in a fresh
    // array, so a frame allocates nothing
    readonly property var springOut: ({
            s: 0,
            v: 0
        })
    onSlideTChanged: expose.evalSlide()
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

    // the area or the live set changed: republish the target map, same rows.
    // outside a sync the rows glide to it (reflowRows); inside one, sync
    // captured the rows before it touched anything and glides them itself
    onTargetsChanged: {
        if (expose.syncing) {
            expose.rebuildTargets();
        } else {
            const before = expose.captureRows();
            expose.rebuildTargets();
            expose.reflowRows(before);
        }
        if (Config.frameLog)
            console.warn("[synopsis] targets " + expose.areaW + "x" + expose.areaH + " " + JSON.stringify(expose.list.map(function (w) { return [w.x, w.y, w.w, w.h]; })) + " -> " + JSON.stringify(expose.targets.map(function (t) { return [Math.round(t.x), Math.round(t.y), Math.round(t.w), Math.round(t.h)]; })));
    }

    // one handler for the whole model, so the active workspace and the signature
    // are never read a binding apart
    onMonChanged: expose.sync()
    Component.onCompleted: expose.sync()

    onOverviewActiveChanged: {
        if (!expose.overviewActive) {
            expose.endSlide();
            expose.endReflow();
        }
    }

    readonly property string overviewState: Overview.state

    // the close flight has taken over the picture: land the slide inside it
    onOverviewStateChanged: {
        if (expose.overviewState === "closing") {
            expose.closeSlide();
            expose.closeReflow();
        } else if (expose.overviewState !== "open")
            expose.clearFlat();
    }

    // flat rows exist: a tile switch close is drawing the arriving set at full
    // size, so the exposé draws above the strip (OverlayWindow). held until the
    // close is over, not just the slide, so the strip cannot pop back over the
    // landed windows for the last frames of the flight
    property bool flatClose: false

    // the tile close was reversed (opening) or is over: a flat row would sit at
    // its real rect in an exposé, so every row flies on progress again
    function clearFlat() {
        for (let r = 0; r < thumbModel.count; r++) {
            if (thumbModel.get(r).flatRow)
                thumbModel.setProperty(r, "flatRow", false);
        }
        expose.flatClose = false;
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
        // every row's drawn rect before anything below moves it: whatever the
        // new targets and rows are, the rows glide from here (reflowRows)
        const before = expose.captureRows();
        expose.syncing = true;
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
        // a tile click asked for this switch: the slide below runs on
        // tileSwitchMs and the close flight starts in the same frame
        // (Overview.beginTileSwitchClose). a switch between two workspaces with
        // no windows has nothing to slide but has still landed: it is reported
        // all the same and closes at once, or a tile click (the plus button
        // from an empty workspace) waits for the switch watchdog. asked before
        // the distance, which a tile switch measures from the real rects
        const tileSwitch = switched && onScreen && Overview.noteWorkspaceSwitch(activeId, m ? m.name : "");
        if (sliding) {
            // every offset set below is a multiple of this, so the distance for
            // this switch is fixed before the first row is retargeted
            expose.slideDistance = expose.computeSlideDistance(next, arriveSign, tileSwitch);
            // a tile switch runs from rest on the close flight's table
            expose.retargetRows(next, activeId, prevId, tileSwitch ? expose.restRates() : expose.slideRates());
        }
        expose.lastActiveId = activeId;
        expose.primed = true;
        expose.list = next;
        expose.rebuildWinMap(next);
        if (sliding) {
            // a tile switch closes: the arriving windows are appended flat, at
            // their real rect and scale 1 from the first frame, so they only
            // slide in horizontally like hyprland's own workspace slide. they
            // never fly from an exposé rect, which sits lower and smaller
            expose.appendMissing(next, activeId, arriveSign * expose.slideDistance, tileSwitch);
            expose.orderRows(next);
        } else if (reset) {
            thumbModel.clear();
            expose.appendAll(next, activeId);
        } else {
            expose.diffRows(next, activeId);
        }
        expose.rebuildTargets();
        if (sliding)
            expose.startSlide(arriveSign, tileSwitch);
        else if (reset)
            Overview.prepareReady();
        expose.syncing = false;
        expose.reflowRows(before);
        if (tileSwitch) {
            // last, once every row and the slide are in place: beginClose flips
            // the state, which re-enters closeSlide and sync on this exposé.
            // sync runs inside the change notification of OverlayWindow's mon
            // binding, and beginClose writes state, pinnedActive and the
            // pending workspace, all of which that binding reads ("Binding loop
            // detected for property mon"). so the close runs once the binding
            // has finished, before the next frame, and the tile slide is
            // restarted from 0 in the same call: both animations register on
            // the same animation tick with the same duration, even if a frame
            // was rendered in between (a slide at 0 draws exactly what the
            // rows show before it starts)
            const leavingRows = sliding ? expose.countLeaving() : 0;
            const arrivingRows = sliding ? thumbModel.count - leavingRows : 0;
            if (Config.frameLog && sliding) {
                const offs = [];
                for (let r = 0; r < thumbModel.count; r++) {
                    const row = thumbModel.get(r);
                    if (row.endOff !== 0)
                        continue;
                    offs.push(Math.round(row.startOff));
                    const it = items.itemAt(r);
                    if (it)
                        console.warn("[synopsis] " + Date.now() + " tile arrive geom addr=" + row.addr + " x=" + Math.round(it.x - it.offsetX) + " y=" + Math.round(it.y) + " w=" + Math.round(it.width) + " h=" + Math.round(it.height) + " scale=" + it.thumbScale + " flight=" + (it.flat ? 0 : 1));
                }
                console.warn("[synopsis] " + Date.now() + " tile arrive rows=" + offs.length + " startOff=" + offs.join(","));
            }
            const monName = m ? m.name : "";
            const gen = expose.slideGen;
            // the close flight shares the slide's table and cut; with nothing
            // to slide it is picked the same way
            const tileCurve = sliding ? {
                lut: expose.slideLut,
                scale: expose.slideScale,
                hypr: expose.slideHypr
            } : expose.curveFor(!expose.sliding);
            Qt.callLater(function () {
                if (Overview.state !== "open")
                    return;
                if (sliding && expose.sliding && expose.tileSlide && expose.slideGen === gen && slideAnim.running) {
                    slideAnim.stop();
                    expose.slideB = 0;
                    expose.slideH = 0;
                    expose.slide = 0;
                    slideAnim.start();
                }
                Overview.beginTileSwitchClose(monName, leavingRows, arrivingRows, tileCurve);
            });
        }
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
    //
    // `flat`: the row draws at its real window rect and scale 1 whatever the
    // flight progress is (the arriving set of a tile switch close)
    function appendRow(addr: string, wsId: int, startOff: real, dist: real, flat: bool) {
        if (expose.rowFor(addr) >= 0) {
            console.warn("[synopsis] duplicate row " + addr);
            return;
        }
        thumbModel.append({
            addr: addr,
            wsId: wsId,
            startOff: startOff,
            endOff: 0,
            // px per ms, the velocity the row had when its slide was
            // interrupted (continueSlide); 0 from rest
            startVel: 0,
            dist: dist,
            flatRow: flat,
            fx: 0,
            fy: 0,
            fw: 0,
            fh: 0,
            fscale: 0,
            // the glide still ahead: drawn rect minus exposé rect, scaled by
            // reflowK (reflowRows)
            gdx: 0,
            gdy: 0,
            gdw: 0,
            gdh: 0,
            gds: 0
        });
    }

    function appendAll(next, wsId: int) {
        for (let i = 0; i < next.length; i++)
            expose.appendRow(next[i].address, wsId, 0, expose.slideDistance, false);
    }

    // the windows of the new set that have no row yet: they enter from the side
    // the new workspace comes from
    function appendMissing(next, wsId: int, startOff: real, flat: bool) {
        for (let i = 0; i < next.length; i++) {
            if (expose.rowFor(next[i].address) < 0)
                expose.appendRow(next[i].address, wsId, startOff, expose.slideDistance, flat);
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
        expose.returnRows(wanted, wsId);
        for (let a = 0; a < next.length; a++) {
            if (expose.rowFor(next[a].address) < 0)
                expose.appendRow(next[a].address, wsId, 0, expose.slideDistance, false);
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
        if (row.startVel !== 0)
            return row.startOff + (row.endOff - row.startOff) * expose.slideH + row.startVel * expose.slideB;
        return row.startOff + (row.endOff - row.startOff) * expose.slide;
    }

    // how fast a row is moving right now, in px per ms, from the rates of the
    // running slide (slideRates)
    function rowVelocity(row, rates): real {
        return (row.endOff - row.startOff) * (row.startVel !== 0 ? rates.dsH : rates.ds) + row.startVel * rates.dB;
    }

    // a window that is live again while its row is still leaving: the switch
    // saw the move before the snapshot did (a stale refresh, a move patched a
    // turn late). the row turns around instead of sliding out and being dropped
    // with its window still here. before the slide has advanced a frame only
    // those rows change; after, every row is re-based where it is and as fast
    // as it goes, and the slide continues from there
    function returnRows(wanted, wsId: int) {
        let any = false;
        for (let r = 0; r < thumbModel.count && !any; r++) {
            const row = thumbModel.get(r);
            any = row.endOff !== 0 && wanted[row.addr] !== undefined;
        }
        if (!any)
            return;
        // a tile click's slide runs on the close flight's timeline, started in
        // the same frame (sync): continuing it would put every row on another
        // clock and land it beside the flight. a row coming back joins that
        // timeline instead: re-based where it is, on the table from here to 0
        // in the time the slide has left, and nothing else is touched. with
        // next to nothing left it is out of sight and would cross the screen in
        // a frame or two; it keeps leaving, and the close lands its window
        if (expose.tileSlide || Overview.state === "closing") {
            const left = 1 - expose.slide;
            let joined = 0;
            for (let r = 0; r < thumbModel.count && left >= 0.05; r++) {
                const row = thumbModel.get(r);
                if (row.endOff === 0 || wanted[row.addr] === undefined)
                    continue;
                const cur = expose.rowOffset(row);
                thumbModel.setProperty(r, "wsId", wsId);
                thumbModel.setProperty(r, "endOff", 0);
                thumbModel.setProperty(r, "dist", expose.slideDistance);
                thumbModel.setProperty(r, "startVel", 0);
                thumbModel.setProperty(r, "startOff", cur / left);
                joined++;
            }
            if (Config.frameLog)
                console.warn("[synopsis] " + Date.now() + " rows returned on close joined=" + joined + " left=" + left.toFixed(3));
            return;
        }
        const started = expose.sliding && slideAnim.running && expose.slideT > 0;
        const rates = expose.slideRates();
        const remaining = slideAnim.duration * (1 - Math.max(0, Math.min(1, expose.slideT)));
        for (let r = 0; r < thumbModel.count; r++) {
            const row = thumbModel.get(r);
            const back = row.endOff !== 0 && wanted[row.addr] !== undefined;
            if (!back && !started)
                continue;
            const cur = expose.rowOffset(row);
            const vel = started ? expose.rowVelocity(row, rates) : row.startVel;
            if (back) {
                thumbModel.setProperty(r, "wsId", wsId);
                thumbModel.setProperty(r, "endOff", 0);
                thumbModel.setProperty(r, "dist", expose.slideDistance);
            }
            thumbModel.setProperty(r, "startOff", cur);
            thumbModel.setProperty(r, "startVel", vel);
        }
        if (Config.frameLog)
            console.warn("[synopsis] " + Date.now() + " rows returned started=" + started);
        if (started) {
            // the floor never above a full slide on this table, as in
            // startSlide: with animations off (1 ms curves) nothing animates
            const fullMs = expose.slideHypr ? Config.hyprWorkspaceMs : Config.switchMs;
            expose.continueSlide(Math.max(Math.min(Config.switchMinMs, fullMs), remaining));
        }
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
    //
    // rates: the running slide's (slideRates), so every row also keeps the
    // velocity it had and the new slide continues it (continueSlide)
    function retargetRows(next, activeId: int, prevId: int, rates: var) {
        const wanted = {};
        for (let i = 0; i < next.length; i++)
            wanted[next[i].address] = true;
        for (let r = thumbModel.count - 1; r >= 0; r--) {
            const row = thumbModel.get(r);
            const cur = expose.rowOffset(row);
            const vel = expose.rowVelocity(row, rates);
            thumbModel.setProperty(r, "startVel", vel);
            const leaving = row.endOff !== 0;
            // a row is flat only for the tile close it was appended in
            if (row.flatRow)
                thumbModel.setProperty(r, "flatRow", false);
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
            } else {
                if (thumbModel.get(r).startOff !== 0)
                    thumbModel.setProperty(r, "startOff", 0);
                if (thumbModel.get(r).startVel !== 0)
                    thumbModel.setProperty(r, "startVel", 0);
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
    // flight runs from the current progress to 0 over closeFlightMs * progress
    // (Overview.runFlight; closeFlightMs is flightMs except for a tile switch
    // close), and WindowThumb draws x = geoX + offsetX: the flight only lands
    // geoX on the real window, so an offset still left at progress 0 is a
    // window drawn beside itself and shifted after the fact. 0.8 keeps a
    // margin for the rounding at both ends
    function closingCap(): real {
        const full = Overview.closeFlightMs > 0 ? Overview.closeFlightMs : Config.flightMs;
        const flightLeft = full * Math.max(0, Math.min(1, Overview.progress));
        return 0.8 * Math.min(full, flightLeft);
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

    // the real window rects of a set, as its bounds in x: {lo, hi} or null
    function realBounds(set): var {
        if (!set || set.length === 0)
            return null;
        let lo = Infinity;
        let hi = -Infinity;
        for (let i = 0; i < set.length; i++) {
            if (set[i].x < lo)
                lo = set[i].x;
            if (set[i].x + set[i].w > hi)
                hi = set[i].x + set[i].w;
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
    //
    // real: a tile switch close, whose arriving rows are flat (their real
    // window rects at scale 1, no flight), so they must start fully off screen
    // measured from those rects, not from the smaller exposé layout
    function computeSlideDistance(next, arriveSign: int, real: bool): real {
        const screen = expose.screenSpan;
        const leave = expose.leavingBounds(next);
        const arrive = real ? expose.realBounds(next) : expose.exposeBounds(next);
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

    // tile: the switch a tile click asked for. the overlay is still open here and
    // the close flight starts right after, in this frame, on tileSwitchMs with
    // the flight's curve; the slide takes exactly that duration and curve, so
    // the leaving set slides fully out and the arriving set reaches offset 0 on
    // the frame its geometry lands on the real windows
    // the table a slide (or a tile switch close) starting now runs on.
    // hyprland's workspace curve only from rest: a spring restarted at zero
    // velocity under rows already moving stutters (spam) or stalls (escape),
    // so restarts and closeSlide take switchLut. the spring is cut where its
    // residual stays under half a pixel over this screen (Config.snapFrac)
    function curveFor(fromRest: bool): var {
        if (fromRest && Config.workspaceCurveActive) {
            const lut = Config.hyprWorkspaceLut;
            return {
                lut: lut,
                scale: Config.snapFrac(lut, Math.max(expose.screenW, expose.slideDistance)),
                hypr: true
            };
        }
        return {
            lut: Config.switchLut,
            scale: 1,
            hypr: false
        };
    }

    // ---- slide evaluation ---------------------------------------------------

    // slideT -> slide and slideB, once per frame, shared by every row
    function evalSlide() {
        const t = expose.slideT;
        if (t >= 1) {
            expose.slideB = 0;
            expose.slideH = 1;
            expose.slide = 1;
            return;
        }
        const u = Math.max(0, t);
        if (expose.slideMode === 1) {
            expose.springEval(u * expose.slideDur / 1000);
            expose.slideB = expose.springOut.v / expose.springW2 * 1000;
            expose.slideH = expose.springOut.s;
            expose.slide = expose.springOut.s;
        } else if (expose.slideMode === 2) {
            expose.slideB = expose.slideDur * u * (1 - u) * (1 - u);
            expose.slideH = u * u * (3 - 2 * u);
            expose.slide = Config.curveAt(expose.slideLut, u * expose.slideScale);
        } else {
            expose.slideB = 0;
            expose.slide = Config.curveAt(expose.slideLut, u * expose.slideScale);
            expose.slideH = expose.slide;
        }
    }

    // hyprland's spring from rest towards 1 after tsec seconds, value and
    // velocity (per second) into springOut: Config._springAt's closed forms on
    // the constants continueSlide fixed. a row continued on it is drawn at
    // x0 + (T - x0) * s + v0 * s' / w0^2, the unique solution of the same
    // spring through (x0, v0), which is what hyprland integrates
    function springEval(tsec: real) {
        const out = expose.springOut;
        const g = expose.springG;
        if (expose.springKind === 0) {
            const wd = expose.springWd;
            const e = Math.exp(-g * tsec);
            const sn = Math.sin(wd * tsec);
            out.s = 1 - e * (Math.cos(wd * tsec) + (g / wd) * sn);
            out.v = e * (expose.springW2 / wd) * sn;
        } else if (expose.springKind === 1) {
            const e = Math.exp(-g * tsec);
            out.s = 1 - e * (1 + g * tsec);
            out.v = e * g * g * tsec;
        } else {
            // overdamped: springWd holds the root spread, roots -g +- it
            const r1 = -g + expose.springWd;
            const r2 = -g - expose.springWd;
            const a = r2 / (r1 - r2);
            const b = -1 - a;
            const e1 = Math.exp(r1 * tsec);
            const e2 = Math.exp(r2 * tsec);
            out.s = 1 + a * e1 + b * e2;
            out.v = a * r1 * e1 + b * r2 * e2;
        }
    }

    // nothing moving
    function restRates(): var {
        return {
            ds: 0,
            dsH: 0,
            dB: 0
        };
    }

    // d(slide)/dt per ms and d(slideB)/dt of the running slide at its current
    // time, so a row's velocity is (endOff - startOff) * ds + startVel * dB.
    // read once per interrupt, never per frame
    function slideRates(): var {
        const t = expose.slideT;
        if (!expose.sliding || !slideAnim.running || t >= 1 || expose.slideDur <= 0)
            return expose.restRates();
        const u = Math.max(0, t);
        if (expose.slideMode === 1) {
            expose.springEval(u * expose.slideDur / 1000);
            const s = expose.springOut.s;
            const v = expose.springOut.v;
            return {
                ds: v / 1000,
                dsH: v / 1000,
                dB: (1 - s) - 2 * expose.springG * v / expose.springW2
            };
        }
        // the table's rate: every row in mode 0, the rows with no velocity in 2
        const ds = Config.curveSlope(expose.slideLut, u * expose.slideScale) * expose.slideScale / expose.slideDur;
        if (expose.slideMode === 2) {
            return {
                ds: ds,
                dsH: 6 * u * (1 - u) / expose.slideDur,
                dB: (1 - u) * (1 - 3 * u)
            };
        }
        return {
            ds: ds,
            dsH: ds,
            dB: 0
        };
    }

    function anyVelocity(): bool {
        for (let r = 0; r < thumbModel.count; r++) {
            if (Math.abs(thumbModel.get(r).startVel) > 0.0001)
                return true;
        }
        return false;
    }

    // how long a continued spring runs: after this no row can still be half a
    // pixel from its end, bounded from the largest distance and the largest
    // velocity any row starts with. the residual never exceeds amp * e^(-rate
    // t), the decay envelope of each branch below, so no time past the one
    // where that envelope falls under half a pixel can be the cut: the 4 ms
    // scan down from the horizon starts there and finds the same cut, in tens
    // of evaluations rather than hundreds. once per interrupt
    function springCutMs(far: real, fast: real): int {
        const horizon = 4 * Math.max(250, Config.hyprWorkspaceMs);
        const g = expose.springG;
        const w2 = expose.springW2;
        const wd = expose.springWd;
        let amp = 0;
        let rate = 0;
        if (expose.springKind === 0) {
            // |1 - s| <= e^(-gt) w0 / wd, |s'| / w0^2 <= e^(-gt) / wd
            amp = (far * Math.sqrt(w2) + fast * 1000) / wd;
            rate = g;
        } else if (expose.springKind === 1) {
            // (1 + gt) e^(-gt/4) <= 4 e^(-3/4), t e^(-gt/4) <= 4 / (e g)
            amp = far * 4 * Math.exp(-0.75) + fast * 1000 * (g * g / w2) * 4 / (Math.E * g);
            rate = 0.75 * g;
        } else {
            // both roots decay at least as fast as the slower one, r1
            const r1 = -g + wd;
            const r2 = -g - wd;
            const a = r2 / (r1 - r2);
            const b = -1 - a;
            amp = far * (Math.abs(a) + Math.abs(b)) + fast * 1000 * (Math.abs(a * r1) + Math.abs(b * r2)) / w2;
            rate = -r1;
        }
        let start = horizon;
        if (rate > 0) {
            if (amp <= 0.5)
                return 1;
            start = Math.min(horizon, 4 * Math.ceil(Math.log(amp / 0.5) / rate * 1000 / 4));
        }
        for (let ms = start; ms > 0; ms -= 4) {
            expose.springEval(ms / 1000);
            const residual = far * Math.abs(1 - expose.springOut.s) + fast * Math.abs(expose.springOut.v / expose.springW2 * 1000);
            if (residual >= 0.5)
                return Math.min(horizon, ms + 4);
        }
        return 1;
    }

    // a hermite leaving faster than 3 * distance / duration toward its end
    // overshoots it and comes back: such a row keeps the fastest velocity
    // that still lands without reversing. one leaving away from its end, or
    // with next to no distance left, swings out before it turns, up to 4/27 *
    // |v| * duration: it keeps the fastest velocity whose swing stays within
    // min(24 px, a tenth of its width)
    function capHermite(dur: real) {
        for (let r = 0; r < thumbModel.count; r++) {
            const row = thumbModel.get(r);
            const v = row.startVel;
            if (v === 0)
                continue;
            const d = row.endOff - row.startOff;
            let lim = 0;
            if (v * d > 0) {
                lim = 3 * Math.abs(d) / dur;
            } else {
                const it = items.itemAt(r);
                const budget = Math.min(24, it ? 0.1 * it.width : 24);
                lim = expose.swingTravel(Math.abs(d), budget) / dur;
            }
            if (Math.abs(v) > lim)
                thumbModel.setProperty(r, "startVel", v > 0 ? lim : -lim);
        }
    }

    // how far (px) a hermite over d px leaving away from its end at V = |v| *
    // duration swings out before it turns: at u = V / (6d + 3V)
    function hermiteSwing(d: real, travel: real): real {
        const q = 6 * d + 3 * travel;
        return travel * travel * (18 * d * d + 17 * d * travel + 4 * travel * travel) / (q * q * q);
    }

    // the largest |v| * duration whose swing stays within budget. the swing
    // rises with it and is at most 4/27 of it, so 27/4 * budget always fits:
    // bisected up from there, once per row per interrupt
    function swingTravel(d: real, budget: real): real {
        if (!(budget > 0))
            return 0;
        let lo = 6.75 * budget;
        let hi = lo;
        while (expose.hermiteSwing(d, hi) <= budget) {
            lo = hi;
            hi *= 2;
            if (hi > 1e7)
                return lo;
        }
        for (let it = 0; it < 24; it++) {
            const mid = (lo + hi) / 2;
            if (expose.hermiteSwing(d, mid) <= budget)
                lo = mid;
            else
                hi = mid;
        }
        return lo;
    }

    // an interrupt: every row is re-based (startOff where it is, startVel how
    // fast it goes) and carries on to its endOff with no velocity step. on
    // hyprland's spring when the workspace curve is one, the way hyprland keeps
    // a running spring's velocity when a switch lands on it; otherwise a cubic
    // hermite over ms. returns the duration it runs
    function continueSlide(ms: real): int {
        const sp = Config.workspaceCurveActive ? Config.hyprWorkspaceSpring : null;
        let dur = 1;
        if (sp) {
            let far = 0;
            let fast = 0;
            for (let r = 0; r < thumbModel.count; r++) {
                const row = thumbModel.get(r);
                far = Math.max(far, Math.abs(row.endOff - row.startOff));
                fast = Math.max(fast, Math.abs(row.startVel));
            }
            const w2 = sp.k / sp.m;
            const g = sp.c / (2 * sp.m);
            const w0 = Math.sqrt(w2);
            expose.springW2 = w2;
            expose.springG = g;
            // the same branch order as Config._springAt, so a spring from rest
            // continued here is the table's own curve
            if (g < w0) {
                expose.springKind = 0;
                expose.springWd = Math.sqrt(w2 - g * g);
            } else if (Math.abs(g - w0) <= Math.max(w0, 1) * 0.0001) {
                expose.springKind = 1;
                expose.springWd = 0;
            } else {
                expose.springKind = 2;
                expose.springWd = Math.sqrt(g * g - w2);
            }
            expose.slideMode = 1;
            dur = expose.springCutMs(far, fast);
        } else {
            dur = Math.max(1, Math.round(ms));
            expose.capHermite(dur);
            expose.slideMode = 2;
        }
        expose.runSlide(dur);
        return dur;
    }

    // (re)start slideAnim from 0 on the mode already set: at 0 every mode
    // draws each row at exactly its startOff
    function runSlide(dur: int) {
        slideAnim.stop();
        expose.slideGen++;
        slideAnim.duration = Math.max(1, dur);
        expose.slideDur = slideAnim.duration;
        expose.slideB = 0;
        expose.slideH = 0;
        expose.slide = 0;
        slideAnim.start();
    }

    function useCurve(curve: var) {
        expose.slideLut = curve.lut;
        expose.slideScale = curve.scale;
        expose.slideHypr = curve.hypr;
    }

    function startSlide(arriveSign: int, tile: bool) {
        slideAnim.stop();
        // duration and closeSlide read this, so it is set before the start
        expose.tileSlide = tile;
        // defensive: sync() only slides while open or opening, and a tile click
        // starts its slide before the close, so this should not happen. if a
        // slide does begin with the close flight already running, the leaving
        // set goes now and the travel below is only the arriving rows'
        const closing = Overview.state === "closing";
        if (closing)
            expose.dropLeaving();
        // rows still moving from the slide this switch interrupts: they carry
        // on from their own velocity (continueSlide) instead of a table from rest
        const moving = !tile && !closing && expose.anyVelocity();
        const curve = expose.curveFor((tile ? !expose.sliding : !moving) && !closing);
        expose.useCurve(curve);
        // the full length on this table: hyprland's slide, or switchMs and
        // tileSwitchMs with switchEasing
        const fullMs = curve.hypr ? Config.hyprWorkspaceMs : (tile ? Config.tileSwitchMs : Config.switchMs);
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
        const floorMs = Math.min(Config.switchMinMs, fullMs);
        let ms;
        if (tile) {
            // one duration with the close flight, never paced or scaled
            ms = fullMs;
        } else if (interval < 0 || interval >= fullMs) {
            // a single switch, or one interrupting a slide that had time to run:
            // exactly the rule that was here before, untouched
            ms = fullMs * Math.max(0.45, Math.min(1, far));
        } else {
            // switches are coming faster than a slide can finish: this one is sized
            // to the gap the user is actually leaving, so the last of a burst is
            // still on screen rather than a queue of half-finished slides
            const paced = Math.max(floorMs, Math.min(fullMs, interval * Config.switchSpamFactor));
            ms = Math.max(floorMs, paced * Math.max(0.45, Math.min(1, far)));
        }
        if (moving) {
            const cont = expose.continueSlide(ms);
            const movingLeaving = expose.countLeaving();
            console.warn("[synopsis] " + now + " slide " + (expose.mon ? expose.mon.name : "") + " arrive=" + arriveSign + " interval=" + interval + " dur=" + cont + " live=" + (thumbModel.count - movingLeaving) + " leaving=" + movingLeaving + " dist=" + Math.round(expose.slideDistance) + " continued=" + expose.slideMode);
            if (Config.frameLog) {
                // the table rows with no velocity follow, for analyze.py
                const samples = [];
                for (let k = 1; k <= 20; k++)
                    samples.push(Config.curveAt(expose.slideLut, k / 20 * expose.slideScale).toFixed(4));
                console.warn("[synopsis] " + now + " continued table dur=" + cont + " arrive=" + arriveSign + " dist=" + expose.slideDistance.toFixed(1) + " mode=" + expose.slideMode + " s=" + samples.join(","));
            }
            return;
        }
        // the spring's cut tail is not run at all (curve.scale is 1 otherwise)
        slideAnim.duration = Math.max(1, Math.round(ms * curve.scale));
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
        expose.slideMode = 0;
        expose.runSlide(slideAnim.duration);
        if (tile) {
            for (let r = 0; r < thumbModel.count; r++) {
                if (thumbModel.get(r).flatRow) {
                    expose.flatClose = true;
                    break;
                }
            }
        }
        const leaving = expose.countLeaving();
        console.warn("[synopsis] " + now + " slide " + (expose.mon ? expose.mon.name : "") + " arrive=" + arriveSign + " interval=" + interval + " dur=" + slideAnim.duration + " live=" + (thumbModel.count - leaving) + " leaving=" + leaving + " dist=" + Math.round(expose.slideDistance));
    }

    function endSlide() {
        expose.slideGen++;
        slideAnim.stop();
        // the overview went away: the next one starts with no switch history, so a
        // reopen right after a burst still gets a full slide
        expose.lastSwitchAt = 0;
        expose.clearFlat();
        expose.slideB = 0;
        expose.slideH = 1;
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
    //
    // not for the tile slide this close was started with: that slide already
    // runs on the flight's duration and curve from the same frame, its leaving
    // set slides fully out and is removed when the slide ends. a close that
    // comes later (reverse, then escape) is an ordinary one and caps it.
    //
    // one timeline with the flight: the slide runs exactly the flight's length
    // (Overview.runFlight computes it the same way, and starts it in the same
    // call right after this), so the offsets and the geometry land on the same
    // frame and nothing is corrected after the other has arrived. every row
    // carries on from its offset and its velocity on a cubic hermite to 0, so
    // escape mid-slide neither stalls the rows nor restarts them from rest
    function closeSlide() {
        if (!expose.sliding)
            return;
        if (expose.tileSlide && Overview.tileSwitchClosing)
            return;
        expose.tileSlide = false;
        // slideT is linear time, so this is the time the slide really has left
        const remaining = slideAnim.duration * (1 - expose.slideT);
        const rates = expose.slideRates();
        const full = Overview.closeFlightMs > 0 ? Overview.closeFlightMs : Config.flightMs;
        const dur = Math.round(full * Math.max(0, Math.min(1, Math.abs(Overview.progress))));
        let dropped = false;
        for (let r = thumbModel.count - 1; r >= 0; r--) {
            const row = thumbModel.get(r);
            if (row.endOff !== 0) {
                thumbModel.remove(r);
                dropped = true;
                continue;
            }
            // carry on from where it is and as fast as it goes, still aiming at 0
            const cur = expose.rowOffset(row);
            const vel = expose.rowVelocity(row, rates);
            thumbModel.setProperty(r, "startOff", cur);
            thumbModel.setProperty(r, "startVel", vel);
        }
        if (dropped)
            expose.rebuildWinMap(expose.list);
        if (Config.frameLog)
            console.warn("[synopsis] " + Date.now() + " closeslide remaining=" + Math.round(remaining) + " dur=" + dur + " rows=" + thumbModel.count);
        if (dur < 1) {
            // nothing worth animating, and nothing may be left hanging: land it
            expose.endSlide();
            return;
        }
        expose.capHermite(dur);
        expose.slideMode = 2;
        expose.runSlide(dur);
    }

    // the close path waits for the slide, so its last frames never snap
    property bool sliding: false
    // the running slide is a tile click's: tileSwitchMs on the flight's curve
    property bool tileSlide: false
    // bumped whenever slideAnim is started, restarted or ended: the deferred
    // tile close restarts only the slide its own sync started
    property int slideGen: 0

    function slideDone() {
        if (!expose.sliding)
            return;
        expose.sliding = false;
        expose.tileSlide = false;
        Overview.slidesRunning--;
        Overview.noteSlideFinished(expose.mon ? expose.mon.name : "");
    }

    NumberAnimation {
        id: slideAnim
        target: expose
        // linear time; onSlideTChanged maps it through the slide's snapshot
        // (curveFor): the tile slide too, its arriving rows no longer fly, so a
        // slide from rest follows hyprland's workspace slide
        property: "slideT"
        from: 0
        to: 1
        duration: Config.switchMs
        onFinished: {
            if (Config.frameLog && expose.flatClose) {
                for (let r = 0; r < thumbModel.count; r++) {
                    const it = items.itemAt(r);
                    const w = expose.winMap[thumbModel.get(r).addr];
                    if (it && w && thumbModel.get(r).flatRow)
                        console.warn("[synopsis] " + Date.now() + " tile arrive land dx=" + (it.x - w.x) + " dy=" + (it.y - w.y) + " dw=" + (it.width - w.w) + " dh=" + (it.height - w.h) + " off=" + it.offsetX);
                }
            }
            expose.dropOutgoing();
            expose.slideDone();
        }
    }

    // ---- reflow -----------------------------------------------------------

    // a live row whose exposé rect changes while the exposé is on screen (a
    // window moved into or out of the set, a rect or the area changed, a
    // leaving row turned around) glides from the rect it was drawn at to the
    // new one instead of jumping to it: the row keeps its distance from the
    // new rect (gdx..gds) and draws rect + distance * reflowK while reflowK
    // eases 1 -> 0, one table lookup per frame for every row. on hyprland's
    // workspace curve when it is active (the slide a move rides on), the
    // switch easing otherwise
    property real reflowT: 1
    property real reflowK: 0
    property var reflowLut: Config.switchLut
    property real reflowScale: 1
    onReflowTChanged: expose.reflowK = expose.reflowT >= 1 ? 0 : 1 - Config.curveAt(expose.reflowLut, expose.reflowT * expose.reflowScale)
    // sync is rebuilding rows and maps: onTargetsChanged leaves the glide to it
    property bool syncing: false

    NumberAnimation {
        id: reflowAnim
        target: expose
        property: "reflowT"
        from: 0
        to: 1
        duration: Config.switchMs
        onFinished: expose.endReflow()
    }

    // addr -> the rect each row is drawn at now (geometry only, no offset)
    function captureRows(): var {
        const out = {};
        for (let r = 0; r < thumbModel.count; r++) {
            const it = items.itemAt(r);
            if (!it)
                continue;
            out[thumbModel.get(r).addr] = {
                x: it.geoX,
                y: it.geoY,
                w: it.geoW,
                h: it.geoH,
                s: it.thumbScale
            };
        }
        return out;
    }

    // called once the rows, maps and slide are in place. nothing is started
    // unless some live row is now drawn somewhere else than before: a sync that
    // moved nothing leaves a running glide alone. otherwise every live row is
    // re-based on its new rect from where it was drawn and the glide restarts
    function reflowRows(before) {
        const st = Overview.state;
        if (st !== "open" && st !== "opening")
            return;
        const k = expose.reflowK;
        let changed = false;
        for (let r = 0; r < thumbModel.count && !changed; r++) {
            const row = thumbModel.get(r);
            const was = before[row.addr];
            const it = items.itemAt(r);
            if (!was || !it || row.endOff !== 0 || row.flatRow)
                continue;
            changed = Math.abs(it.geoX - was.x) > 0.01 || Math.abs(it.geoY - was.y) > 0.01 || Math.abs(it.geoW - was.w) > 0.01 || Math.abs(it.geoH - was.h) > 0.01 || Math.abs(it.thumbScale - was.s) > 0.0001;
        }
        if (!changed)
            return;
        let far = 0;
        for (let r = 0; r < thumbModel.count; r++) {
            const row = thumbModel.get(r);
            const was = before[row.addr];
            const it = items.itemAt(r);
            let dx = 0, dy = 0, dw = 0, dh = 0, ds = 0;
            if (was && it && row.endOff === 0 && !row.flatRow) {
                // the new rect alone: the binding is rect + old distance * k
                dx = was.x - (it.geoX - row.gdx * k);
                dy = was.y - (it.geoY - row.gdy * k);
                dw = was.w - (it.geoW - row.gdw * k);
                dh = was.h - (it.geoH - row.gdh * k);
                ds = was.s - (it.thumbScale - row.gds * k);
            }
            far = Math.max(far, Math.abs(dx), Math.abs(dy), Math.abs(dw), Math.abs(dh));
            if (row.gdx !== dx)
                thumbModel.setProperty(r, "gdx", dx);
            if (row.gdy !== dy)
                thumbModel.setProperty(r, "gdy", dy);
            if (row.gdw !== dw)
                thumbModel.setProperty(r, "gdw", dw);
            if (row.gdh !== dh)
                thumbModel.setProperty(r, "gdh", dh);
            if (row.gds !== ds)
                thumbModel.setProperty(r, "gds", ds);
        }
        const curve = expose.curveFor(true);
        const scale = curve.hypr ? Config.snapFrac(curve.lut, Math.max(1, far)) : 1;
        const fullMs = curve.hypr ? Config.hyprWorkspaceMs : Config.switchMs;
        expose.startReflow(curve.lut, scale, Math.max(1, Math.round(fullMs * scale)));
        if (Config.frameLog)
            console.warn("[synopsis] " + Date.now() + " reflow far=" + Math.round(far) + " dur=" + reflowAnim.duration);
    }

    function startReflow(lut: var, scale: real, dur: int) {
        reflowAnim.stop();
        expose.reflowLut = lut;
        expose.reflowScale = scale;
        reflowAnim.duration = dur;
        expose.reflowT = 0;
        expose.reflowK = 1;
        reflowAnim.start();
    }

    // the close flight took over: what is left of the glide lands with it, on
    // its table and its length, so no row is still gliding once it has arrived
    function closeReflow() {
        if (!reflowAnim.running)
            return;
        const k = expose.reflowK;
        for (let r = 0; r < thumbModel.count; r++) {
            const row = thumbModel.get(r);
            if (row.gdx !== 0)
                thumbModel.setProperty(r, "gdx", row.gdx * k);
            if (row.gdy !== 0)
                thumbModel.setProperty(r, "gdy", row.gdy * k);
            if (row.gdw !== 0)
                thumbModel.setProperty(r, "gdw", row.gdw * k);
            if (row.gdh !== 0)
                thumbModel.setProperty(r, "gdh", row.gdh * k);
            if (row.gds !== 0)
                thumbModel.setProperty(r, "gds", row.gds * k);
        }
        const full = Overview.closeFlightMs > 0 ? Overview.closeFlightMs : Config.flightMs;
        const dur = Math.round(full * Math.max(0, Math.min(1, Math.abs(Overview.progress))));
        if (dur < 1) {
            expose.endReflow();
            return;
        }
        const own = Overview.closeFlightLut !== null && Overview.closeFlightLut.length > 1;
        expose.startReflow(own ? Overview.closeFlightLut : Config.flightLut, own ? Overview.closeFlightScale : 1, dur);
    }

    function endReflow() {
        reflowAnim.stop();
        expose.reflowT = 1;
        expose.reflowK = 0;
        for (let r = 0; r < thumbModel.count; r++) {
            const row = thumbModel.get(r);
            if (row.gdx !== 0 || row.gdy !== 0 || row.gdw !== 0 || row.gdh !== 0 || row.gds !== 0) {
                thumbModel.setProperty(r, "gdx", 0);
                thumbModel.setProperty(r, "gdy", 0);
                thumbModel.setProperty(r, "gdw", 0);
                thumbModel.setProperty(r, "gdh", 0);
                thumbModel.setProperty(r, "gds", 0);
            }
        }
    }

    // frameLog only: every row's drawn rect once per animation tick, for the
    // simulator's motion checks (analyze.py motion_checks). off, it never runs
    FrameAnimation {
        running: Config.frameLog && Overview.active && expose.mon !== null
        onTriggered: {
            const parts = [];
            for (let r = 0; r < thumbModel.count; r++) {
                const it = items.itemAt(r);
                if (it)
                    parts.push(thumbModel.get(r).addr + ":" + it.x.toFixed(1) + "," + it.y.toFixed(1) + "," + it.width.toFixed(1) + "," + it.height.toFixed(1) + "," + it.offsetX.toFixed(1) + "," + (thumbModel.get(r).endOff !== 0 ? 1 : 0));
            }
            // slideT last, in the same call as the offsets it produced
            console.warn("[synopsis] " + Date.now() + " rows " + (expose.mon ? expose.mon.name : "") + " " + Overview.state + " " + parts.join(" ") + " slideT:" + expose.slideT.toFixed(4));
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
            required property real startVel
            required property real gdx
            required property real gdy
            required property real gdw
            required property real gdh
            required property real gds
            required property real fx
            required property real fy
            required property real fw
            required property real fh
            required property real fscale
            // not `flat`: that is WindowThumb's own property, bound below
            required property bool flatRow

            readonly property bool leaving: thumb.endOff !== 0
            readonly property var winData: expose.winFor(thumb.addr, expose.mapVersion)
            readonly property var tgt: expose.targetFor(thumb.addr, expose.mapVersion)
            // real rect, scale 1, whatever the flight progress: only offsetX moves
            readonly property bool flatNow: thumb.flatRow && !thumb.leaving && thumb.winData !== null
            // 0 for a flat row: its geometry does not follow the flight
            readonly property real flightT: thumb.flatNow ? 0 : expose.progress

            win: thumb.winData
            flat: thumb.flatNow
            interactive: !thumb.leaving
            gated: !thumb.leaving
            // a row on its way out keeps its last frame: a live capture for a
            // workspace the user has already left is work nobody sees, and during
            // a burst it is several of them at once
            wantLive: !thumb.leaving
            // and it draws under the set that is arriving, never over it
            demoted: thumb.leaving
            // a leaving row draws its frozen rect; a live one the flight between
            // its real and exposé rect, plus what is left of a glide (reflowK)
            thumbScale: thumb.leaving ? thumb.fscale : 1 + ((thumb.tgt ? thumb.tgt.scale : 1) - 1) * thumb.flightT + thumb.gds * expose.reflowK
            geoX: thumb.leaving ? thumb.fx : (thumb.winData ? thumb.winData.x + ((thumb.tgt ? thumb.tgt.x : thumb.winData.x) - thumb.winData.x) * thumb.flightT + thumb.gdx * expose.reflowK : 0)
            geoY: thumb.leaving ? thumb.fy : (thumb.winData ? thumb.winData.y + ((thumb.tgt ? thumb.tgt.y : thumb.winData.y) - thumb.winData.y) * thumb.flightT + thumb.gdy * expose.reflowK : 0)
            geoW: thumb.leaving ? thumb.fw : (thumb.winData ? thumb.winData.w + ((thumb.tgt ? thumb.tgt.w : thumb.winData.w) - thumb.winData.w) * thumb.flightT + thumb.gdw * expose.reflowK : 0)
            geoH: thumb.leaving ? thumb.fh : (thumb.winData ? thumb.winData.h + ((thumb.tgt ? thumb.tgt.h : thumb.winData.h) - thumb.winData.h) * thumb.flightT + thumb.gdh * expose.reflowK : 0)
            // one of slide and slideH, never both: a row with no velocity follows
            // the table alone and is evaluated once a frame
            offsetX: thumb.startVel !== 0 ? thumb.startOff + (thumb.endOff - thumb.startOff) * expose.slideH + thumb.startVel * expose.slideB : thumb.startOff + (thumb.endOff - thumb.startOff) * expose.slide
            gliding: expose.reflowK !== 0
        }
    }
}
