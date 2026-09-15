pragma ComponentBehavior: Bound

// the strip of workspace tiles. it descends from the top with the scrim.
//
// the tiles live in a ListModel keyed by workspace id and synced in place
// (insert, remove, move), so a tile persists for as long as its id is shown:
// a plus click, a prune or a virtual id turning real never rebuilds the other
// tiles or their captures. a workspace switch changes nothing here at all; one
// highlight rectangle slides to the new tile instead.
//
// every tile has one fixed size (Layout.computeStripRow): tiles never grow or
// shrink as workspaces come and go. up to Config.stripMaxVisible tiles the row
// is centred; past that it overflows, left-aligns and scrolls sideways inside
// a non-interactive Flickable (shift + wheel, a touchpad's horizontal swipe,
// the thin bar under the tiles, or a dragged window held at either edge)

import QtQuick
import Quickshell
import Quickshell.Hyprland
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
    readonly property string monName: strip.mon ? (strip.mon.name || "") : ""
    readonly property int activeId: strip.mon ? strip.mon.activeId : 0
    readonly property int specialId: strip.mon ? strip.mon.specialId : 0
    readonly property real aspect: (strip.mon && strip.mon.h > 0) ? (strip.mon.w / strip.mon.h) : 1
    // the button sits apart from the last tile by a clearly larger gap than
    // between tiles, so it reads as "add" rather than one more workspace
    readonly property real buttonGap: Config.stripGap * 2.5

    // positions are relative to the scroll view (the area's top-left corner)
    readonly property var row: Layout.computeStripRow(tileList.count, strip.aspect, {
        x: 0,
        y: 0,
        w: strip.areaW,
        h: strip.areaH
    }, {
        gap: Config.stripGap,
        buttonGap: strip.buttonGap,
        fixedCount: Config.stripFixedCount,
        maxVisible: Config.stripMaxVisible,
        buttonFraction: Config.stripButtonFraction
    })
    readonly property bool overflow: strip.row.overflow

    // ---- device pixels --------------------------------------------------
    //
    // the viewport is layered while a fade shows, and a layer only looks the
    // same as the unlayered viewport if its texture maps 1:1 onto device
    // pixels: whole device pixels in size, on the device pixel grid in the
    // scene, with contentX on the grid at rest. at a fractional scale (1.25)
    // the row's own numbers are fractional, so the viewport is sized in whole
    // steps that are whole in device pixels too (4 px at 1.25), the section is
    // nudged onto the grid, and every scroll target is snapped
    readonly property real dpr: {
        const w = strip.QsWindow.window;
        const r = w ? w.devicePixelRatio : 0;
        return r > 0 ? r : 1;
    }
    readonly property int pixelStep: {
        for (let k = 1; k <= 8; k++)
            if (Math.abs(k * strip.dpr - Math.round(k * strip.dpr)) < 0.001)
                return k;
        return 1;
    }
    readonly property real devicePx: 1 / strip.dpr
    // floor, so the viewport never reaches into the button gap
    readonly property real viewW: Math.floor(strip.row.viewportWidth / strip.pixelStep) * strip.pixelStep
    readonly property real viewH: Math.ceil(strip.areaH / strip.pixelStep) * strip.pixelStep
    // the section's resting scene position rounded to device pixels. from the
    // parent, not the strip, so the flight's y never enters it: the offset is
    // constant through open and close and the flight itself is left unsnapped
    readonly property point gridOffset: {
        const d = strip.dpr;
        const px = strip.x + strip.areaX;
        const py = strip.areaY;
        const p = strip.parent ? strip.parent.mapToItem(null, px, py) : Qt.point(px, py);
        return Qt.point(Math.round(p.x * d) / d - p.x, Math.round(p.y * d) / d - p.y);
    }
    readonly property real maxScroll: Math.max(0, strip.row.contentWidth - strip.viewW)

    // a dragged window is over the tile section. the dragged thumb holds the
    // pointer grab, so no hover reaches the strip; Overview's pointer does.
    // re-evaluated on pointer moves, and only mapped while a drag runs
    readonly property bool dragOver: {
        if (!strip.overflow || Overview.dragAddress === "" || Overview.pointerWindow !== strip.Window.window)
            return false;
        const p = section.mapFromItem(null, Overview.pointerX, Overview.pointerY);
        return p.x >= 0 && p.y >= 0 && p.x <= section.width && p.y <= section.height;
    }

    // the scale a window is drawn at inside a tile. a dragged thumb shrinks to it,
    // so it ends up the size it will have once dropped and the strip stays visible
    // under it. the tile size is fixed per monitor, so this only changes with
    // the monitor itself; every tile also exposes its own tileScale
    readonly property real tileScale: (strip.mon && strip.mon.w > 0 && strip.row.tileW > 0) ? (strip.row.tileW / strip.mon.w) : 0

    readonly property int activeIndex: strip.indexOfTile(strip.tilesRevision, strip.activeId, strip.specialId)
    readonly property var activeCell: (strip.activeIndex >= 0) ? (strip.row.tiles[strip.activeIndex] || null) : null

    // a dragged window held near either side of the overflowing row scrolls it,
    // faster the deeper it sits in the edge zone. re-evaluated on pointer moves
    // only; the timer below runs just while this is non-zero
    readonly property real edgeSpeed: {
        if (!strip.overflow || !Overview.interactive || Overview.dragAddress === "" || Overview.pointerWindow !== strip.Window.window)
            return 0;
        const zone = Math.max(1, Config.stripScrollEdge);
        const p = view.mapFromItem(null, Overview.pointerX, Overview.pointerY);
        if (p.y < -zone || p.y > view.height + zone)
            return 0;
        // past the narrowed viewport (the gap, the pinned add button) is not
        // "maximally deep in the edge zone": it is off the scrollable area
        // entirely, and must not scroll at all
        if (p.x < -Config.stripGap || p.x > view.width + Config.stripGap)
            return 0;
        let depth = 0;
        if (p.x < zone)
            depth = -(zone - p.x) / zone;
        else if (p.x > view.width - zone)
            depth = (p.x - (view.width - zone)) / zone;
        return Math.max(-1, Math.min(1, depth)) * 20;
    }

    // ---- edge fades -----------------------------------------------------
    //
    // a real alpha fade at each edge of the scrolling viewport, never a coloured
    // overlay: the strip sits over a translucent, blurred backdrop. room is how
    // far the view is from that end, in fade widths, and exactly 0 at the end,
    // so a fade is fully gone the moment the view gets there. the gate fades a
    // whole fade in or out when it appears or vanishes at once (overflow on,
    // a jump away from an end). view.width, not the row's viewport, so a fade
    // follows the viewport's own glide when overflow toggles
    readonly property real fadeW: Math.max(Config.stripFadeMin, Math.min(Config.stripFadeMax, strip.row.tileW * Config.stripFadeFraction))
    // within one device pixel of an end counts as at it: a snapped contentX
    // at the right end sits up to a device pixel short of a fractional max
    readonly property real fadeRoomL: Math.max(0, Math.min(1, (view.contentX - strip.devicePx) / strip.fadeW))
    readonly property real fadeRoomR: Math.max(0, Math.min(1, (view.contentWidth - view.width - view.contentX - strip.devicePx) / strip.fadeW))
    // where the view is heading. a gate stays on while the view heads away
    // from its end even if contentX touches the end on the way: a workspace
    // removed mid-move shrinks the row and the flickable clamps contentX to the
    // new end for a frame, which used to fade the right edge out and back in
    readonly property real aimX: (moveAnim.running && move.scroll) ? move.toCX : (scrollAnim.running ? scrollAnim.to : view.contentX)
    // only an overflowing row has fades: a fitting row's contentWidth and width
    // update one after the other and would flick one on for nothing. when the
    // row stops overflowing, a fade still showing eases out on its gate.
    //
    // a gate turns on while the view is at, or heads to, a place away from
    // its end. once on it stays on while there is room, so a scroll onto the
    // end fades out with the room (fadeL, fadeR). a gate that is off does not
    // turn on for room alone: a scroll that starts off and heads onto the end
    // would ease a fade in and straight out again. that is a plus click, which
    // grows the row a turn before revealInserted gives the scroll its target,
    // so the gates are also held while that reveal is pending (revealId)
    property bool fadeOnL: false
    property bool fadeOnR: false

    // live values, not the fadeRoom and aimX bindings: this runs from their
    // inputs' change handlers, which may come before those bindings update
    function updateFades() {
        if (strip.revealId !== 0)
            return;
        const aim = strip.scrollTarget();
        const cx = view.contentX;
        const end = view.contentWidth - view.width;
        const px = strip.devicePx;
        const onL = strip.overflow && (aim > px || (strip.fadeOnL && cx - px > 0));
        const onR = strip.overflow && (end - aim > px || (strip.fadeOnR && end - cx - px > 0));
        if (onL !== strip.fadeOnL)
            strip.fadeOnL = onL;
        if (onR !== strip.fadeOnR)
            strip.fadeOnR = onR;
    }
    property real fadeGateL: strip.fadeOnL ? 1 : 0
    property real fadeGateR: strip.fadeOnR ? 1 : 0
    // under 1/250 a fade changes the edge pixel's alpha by less than one
    // step of 8 bits: that counts as none, so the layer turns off
    readonly property real fadeL: strip.fadeCut(strip.overflow ? Math.min(strip.fadeGateL, strip.fadeRoomL) : strip.fadeGateL)
    readonly property real fadeR: strip.fadeCut(strip.overflow ? Math.min(strip.fadeGateR, strip.fadeRoomR) : strip.fadeGateR)
    // the viewport's layer exists only while a fade shows: fadeL and fadeR
    // include the gates, so a fade easing in or out keeps it; both at 0
    // (a fitting row, or an end with no room on the other side) drop it. at
    // fade 0 the shader passes the 1:1 texture through untouched, so the
    // first frame with the layer and the first without look the same
    readonly property bool fadeLayer: strip.fadeL > 0 || strip.fadeR > 0
    // a revealed tile clears the fade (and the tile gap) on its side
    readonly property real revealPad: Math.max(Config.stripGap, strip.fadeW)

    Behavior on fadeGateL {
        enabled: Overview.interactive
        NumberAnimation {
            duration: Config.stripFadeMs
            easing.type: Easing.InOutQuad
        }
    }

    Behavior on fadeGateR {
        enabled: Overview.interactive
        NumberAnimation {
            duration: Config.stripFadeMs
            easing.type: Easing.InOutQuad
        }
    }

    opacity: strip.progress
    // off the top edge at rest, in place at full progress
    y: (strip.progress - 1) * (strip.areaY + strip.areaH)

    onWsSigChanged: strip.syncTiles()
    onTileScaleChanged: strip.publishTileScale()
    onActiveCellChanged: Qt.callLater(strip.placeHighlight)
    onRowChanged: Qt.callLater(strip.clampScroll)
    onAimXChanged: strip.updateFades()
    onRevealIdChanged: strip.updateFades()
    onDevicePxChanged: strip.updateFades()
    onFadeOnLChanged: {
        if (Config.frameLog)
            console.warn("[synopsis] " + Date.now() + " strip fade left " + (strip.fadeOnL ? "on" : "off") + " cx=" + view.contentX.toFixed(1) + " max=" + strip.maxScroll.toFixed(1));
    }
    onFadeOnRChanged: {
        if (Config.frameLog)
            console.warn("[synopsis] " + Date.now() + " strip fade right " + (strip.fadeOnR ? "on" : "off") + " cx=" + view.contentX.toFixed(1) + " max=" + strip.maxScroll.toFixed(1));
    }
    onOverflowChanged: {
        if (Config.frameLog) {
            console.warn("[synopsis] " + Date.now() + " strip overflow " + (strip.overflow ? "on " : "off ") + strip.monName + " tiles=" + tileList.count + " w=" + strip.row.tileW.toFixed(1) + " h=" + strip.row.tileH.toFixed(1));
            console.warn("[synopsis] " + Date.now() + " strip overflow " + (strip.overflow ? "on " : "off ") + strip.monName + " tiles=" + tileList.count + " viewport=" + strip.row.viewportWidth.toFixed(1) + " button=" + strip.row.buttonX.toFixed(1) + " size=" + strip.row.buttonSize.toFixed(1) + " area=" + strip.areaW.toFixed(1) + " gap=" + strip.buttonGap.toFixed(1));
        }
        strip.updateFades();
        if (!strip.overflow)
            strip.scrollTo(0, true);
    }
    Component.onCompleted: {
        strip.syncTiles();
        strip.publishTileScale();
        strip.placeHighlight();
        strip.updateFades();
    }

    Connections {
        target: Overview

        function onStateChanged() {
            const s = Overview.state;
            // closing freezes the scroll where it is and lets a running
            // highlight move finish in content coordinates. finishing the
            // scroll would slide the row sideways under the fly-off, which
            // nothing else does (no scroll runs under a flight); snapping to
            // its target would jump a still visible row. the flight starts on
            // this frame, so the horizontal stop reads as part of that one
            // change of motion rather than a jolt of its own
            if (s === "closing")
                strip.stopScroll();
            // closed, and before the next opening flight, nothing of an old
            // move or scroll survives: the highlight snaps onto the active
            // tile and the view snaps it into view
            if (s === "closed" || s === "preparing" || s === "opening") {
                strip.settle(s);
                Qt.callLater(strip.revealActive);
            }
            if (Config.frameLog && (s === "open" || s === "closing"))
                console.warn("[synopsis] " + Date.now() + " strip tile w=" + strip.row.tileW.toFixed(1) + " h=" + strip.row.tileH.toFixed(1) + " tiles=" + tileList.count + " on " + strip.monName + " (" + s + ")");
            if (Config.frameLog && s === "open") {
                const c = strip.activeCell;
                const left = view.contentX;
                const right = left + view.width;
                const shown = c !== null && c.x >= left - 0.5 && c.x + c.w <= right + 0.5;
                console.warn("[synopsis] " + Date.now() + " strip open id=" + highlight.placedId + " cx=" + left.toFixed(2) + " view=" + left.toFixed(1) + ".." + right.toFixed(1) + " visible=" + (shown ? 1 : 0) + " moving=" + ((moveAnim.running || scrollAnim.running) ? 1 : 0));
            }
        }
    }

    // test hook for tools/sim: synopsis:strip-scroll:pixel:<dx> is a touchpad
    // swipe, synopsis:strip-scroll:angle:<dx> a horizontal wheel notch (120 a
    // notch), both through the same path as a real WheelEvent, on the focused
    // monitor's strip only
    Connections {
        target: Hyprland

        function onRawEvent(event) {
            if (("" + event.name).indexOf("custom") !== 0)
                return;
            const data = "" + event.data;
            if (data.indexOf("synopsis:strip-scroll:") !== 0 || strip.monName !== HyprState.focusedMonitorName())
                return;
            if (!strip.overflow || !Overview.interactive)
                return;
            const parts = data.substring(22).split(":");
            const d = parseFloat(parts[1]);
            if (!isFinite(d) || d === 0)
                return;
            if (parts[0] === "pixel")
                strip.userScroll(d, 0);
            else if (parts[0] === "angle")
                strip.userScroll(0, d);
        }
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
        const removedIds = [];
        const insertedIds = [];
        for (let r = tileList.count - 1; r >= 0; r--) {
            if (!wanted[tileList.get(r).tileId]) {
                removedIds.push(tileList.get(r).tileId);
                tileList.remove(r);
            }
        }
        const animate = Overview.interactive;
        let inserted = 0;
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
            if (found >= 0) {
                tileList.move(found, i, 1);
            } else {
                // pending before the row grows, so the fade gates hold
                // until revealInserted has set the scroll (updateFades)
                if (animate)
                    strip.revealId = id;
                tileList.insert(i, {
                    tileId: id,
                    fresh: animate
                });
                inserted = id;
                insertedIds.push(id);
            }
        }
        strip.tilesRevision++;
        if (Config.frameLog) {
            const ids = [];
            for (let t = 0; t < tileList.count; t++)
                ids.push(tileList.get(t).tileId);
            console.warn("[synopsis] " + Date.now() + " strip sync " + strip.monName + " tiles=" + tileList.count + " ids=" + ids.join(",") + " removed=" + removedIds.join(",") + " inserted=" + insertedIds.join(","));
        }
        if (animate && inserted !== 0) {
            strip.revealId = inserted;
            Qt.callLater(strip.revealInserted);
        } else if (!animate) {
            Qt.callLater(strip.revealActive);
        }
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

    // ---- scrolling ------------------------------------------------------

    property int revealId: 0

    // where the view is heading: the running move's or animation's end, else
    // where it is
    function scrollTarget() {
        if (moveAnim.running && move.scroll)
            return move.toCX;
        return scrollAnim.running ? scrollAnim.to : view.contentX;
    }

    // every scroll that is not the highlight's own takes the view over from it.
    // the view stays where it is this frame; a running highlight move keeps
    // its geometry going and only stops writing contentX
    function stopScroll() {
        scrollAnim.stop();
        move.scroll = false;
    }

    // closed, or about to open: stop every clock and put the highlight on the
    // active tile, so the next open starts from rest (revealActive follows)
    function settle(state) {
        const was = moveAnim.running || scrollAnim.running;
        moveAnim.stop();
        scrollAnim.stop();
        move.scroll = false;
        strip.pixelX = -1;
        const c = strip.activeCell;
        if (c) {
            highlight.x = c.x;
            highlight.y = c.y;
            highlight.width = c.w;
            highlight.height = c.h;
        }
        if (Config.frameLog && was)
            console.warn("[synopsis] " + Date.now() + " strip settle (" + state + ") cx=" + view.contentX.toFixed(2));
    }

    function fadeCut(f) {
        return f < 0.004 ? 0 : f;
    }

    // a scroll position clamped to the row and on the device pixel grid; past
    // a fractional end it rounds down, so the snapped end never overshoots
    function snapScroll(x) {
        const d = strip.dpr;
        const end = Math.floor(strip.maxScroll * d + 0.001) / d;
        return Math.max(0, Math.min(Math.round(x * d) / d, end));
    }

    // the base for a user's scroll step: where the user sees the view, never a
    // running move's target. the move's scroll part is handed over here
    function userBase() {
        move.scroll = false;
        return scrollAnim.running ? scrollAnim.to : view.contentX;
    }

    // the unsnapped position of a run of pixel steps (touchpad, edge drag), so
    // steps under a device pixel add up instead of rounding away; -1 when unset
    property real pixelX: -1

    // clamped to the row and snapped to device pixels; animated only while
    // open, so opening and closing never scroll under their own flight
    function scrollTo(x, animate) {
        move.scroll = false;
        const target = strip.snapScroll(x);
        if (!animate || !Overview.interactive) {
            scrollAnim.stop();
            view.contentX = target;
            return;
        }
        if (scrollAnim.running && Math.abs(scrollAnim.to - target) < 0.01)
            return;
        scrollAnim.stop();
        if (Math.abs(view.contentX - target) < 0.5) {
            view.contentX = target;
            return;
        }
        scrollAnim.from = view.contentX;
        scrollAnim.to = target;
        scrollAnim.start();
    }

    // the smallest scroll from base that shows [left, right] clear of the edge
    // fade, clamped to the row
    function revealX(left, right, base) {
        const pad = strip.revealPad;
        const viewportW = strip.viewW;
        let x = base;
        if (right + pad > x + viewportW)
            x = right + pad - viewportW;
        if (left - pad < x)
            x = left - pad;
        return strip.snapScroll(x);
    }

    function reveal(left, right, animate) {
        strip.scrollTo(strip.revealX(left, right, strip.scrollTarget()), animate);
    }

    function clampScroll() {
        // a scrolling move with an active tile is retargeted by placeHighlight,
        // which runs on the same row change (a new row is a new activeCell)
        if (moveAnim.running && move.scroll && strip.activeCell)
            return;
        const t = strip.scrollTarget();
        if (t > strip.maxScroll || view.contentX > strip.maxScroll)
            strip.scrollTo(Math.min(t, strip.maxScroll), true);
    }

    function revealActive() {
        const c = strip.activeCell;
        if (c)
            strip.reveal(c.x, c.x + c.w, false);
        else
            strip.scrollTo(strip.scrollTarget(), false);
    }

    // a tile added while open: scroll it into the viewport (the button lives
    // outside the viewport now, so it needs no reveal of its own)
    function revealInserted() {
        const index = strip.indexOfTile(strip.tilesRevision, strip.revealId, 0);
        const c = index >= 0 ? strip.row.tiles[index] : null;
        if (c)
            strip.reveal(c.x, c.x + c.w, true);
        // after the scroll has its target, which the fade gates read
        strip.revealId = 0;
    }

    // one mouse notch moves about one tile; a touchpad's pixel deltas move 1:1
    function wheelScroll(wheel) {
        if (!strip.overflow || !Overview.interactive) {
            wheel.accepted = false;
            return;
        }
        const horizontal = wheel.angleDelta.x !== 0;
        if (!horizontal && !(wheel.modifiers & Qt.ShiftModifier)) {
            wheel.accepted = false;
            return;
        }
        if (horizontal && wheel.pixelDelta.x !== 0) {
            strip.userScroll(wheel.pixelDelta.x, 0);
            return;
        }
        strip.userScroll(0, horizontal ? wheel.angleDelta.x : wheel.angleDelta.y);
    }

    // user scroll input: a touchpad's pixel delta, or a wheel's angle delta.
    // during a highlight move it takes only the scroll over, from where the
    // view is on screen (userBase), so the step never lands on the move's
    // target first; the highlight keeps its own move
    function userScroll(pixelDelta, angleDelta) {
        const took = moveAnim.running && move.scroll;
        const before = view.contentX;
        if (pixelDelta !== 0) {
            strip.stopScroll();
            strip.scrollByPixels(-pixelDelta);
        } else {
            strip.scrollTo(strip.userBase() - angleDelta / 120 * (strip.row.tileW + Config.stripGap), true);
        }
        if (Config.frameLog)
            console.warn("[synopsis] " + Date.now() + " strip scroll " + (pixelDelta !== 0 ? "pixel d=" + pixelDelta.toFixed(1) : "angle d=" + angleDelta.toFixed(1)) + " cx=" + before.toFixed(2) + "->" + view.contentX.toFixed(2) + " to=" + strip.aimX.toFixed(2) + " took=" + (took ? 1 : 0));
    }

    // a step in pixels from where the view is; the unsnapped sum carries on
    // only while the view is still where the last step left it
    function scrollByPixels(dx) {
        const cx = view.contentX;
        const base = (strip.pixelX >= 0 && !scrollAnim.running && Math.abs(strip.snapScroll(strip.pixelX) - cx) < 0.001) ? strip.pixelX : cx;
        strip.pixelX = Math.max(0, Math.min(base + dx, strip.maxScroll));
        strip.scrollTo(strip.pixelX, false);
    }

    // the highlight is placed here rather than bound, so each move picks its own
    // timing: staying on the same workspace while the row re-centres or
    // resizes follows the tiles (shortDuration on standardLut, their easing),
    // moving to another workspace keeps the switch look (switchMs on switchLut,
    // the switchEasing curve the old Behaviors ran). deferred with callLater so
    // an activeId and a layout change from one model rebuild land as one move.
    //
    // a new tile out of view scrolls in on the same move: moveAnim runs one
    // linear clock (move.t) and stepMove maps it through one table into both
    // the highlight geometry and contentX, so they start, ease and settle on
    // the same frames. a placement mid-move starts both from where they are.
    // the view is left alone while the user holds it (the bar, a drag at the
    // edge), and only scrolls while open; otherwise a switch snaps it
    function placeHighlight() {
        const c = strip.activeCell;
        const id = (c && strip.activeIndex >= 0 && strip.activeIndex < tileList.count) ? tileList.get(strip.activeIndex).tileId : 0;
        const sameTile = id !== 0 && id === highlight.placedId;
        highlight.placedId = id;
        if (!c)
            return;
        const hold = barMouse.dragging || view.dragging || view.flicking || strip.edgeSpeed !== 0;
        // snaps while the strip is off screen (preparing, opening, closed) and
        // travels only when it can be seen: open, and the close after a tile click
        if (!(Overview.interactive || Overview.state === "closing")) {
            moveAnim.stop();
            highlight.x = c.x;
            highlight.y = c.y;
            highlight.width = c.w;
            highlight.height = c.h;
            if (!sameTile && !hold)
                strip.reveal(c.x, c.x + c.w, false);
            return;
        }
        const running = moveAnim.running;
        let cx = view.contentX;
        let scroll = false;
        let base = move.baseCX;
        if (!hold && Overview.interactive) {
            if (!sameTile) {
                base = strip.scrollTarget();
                cx = strip.revealX(c.x, c.x + c.w, base);
                scroll = Math.abs(cx - view.contentX) > 0.001;
            } else if (running && move.scroll) {
                // the row changed under a scrolling move (a workspace added or
                // removed): the target is worked out again from the move's
                // own base for where the tile now sits, so it lands where the
                // original placement would have on this row, clear of the
                // fades; the move restarts from the current highlight and
                // contentX below
                cx = strip.revealX(c.x, c.x + c.w, move.baseCX);
                scroll = true;
            }
        }
        const at = (x, y, w, h) => Math.abs(x - c.x) < 0.01 && Math.abs(y - c.y) < 0.01 && Math.abs(w - c.w) < 0.01 && Math.abs(h - c.h) < 0.01;
        // already heading there (a rebuild that moved nothing), or already there
        if (running ? (at(move.toX, move.toY, move.toW, move.toH) && (scroll ? (move.scroll && Math.abs(move.toCX - cx) < 0.5) : !move.scroll)) : (at(highlight.x, highlight.y, highlight.width, highlight.height) && !scroll))
            return;
        // the row changed under a running move that keeps its tile: the move
        // keeps its clock and curve, and the from values are solved so this
        // frame stays put and the move ends on the new targets at its own end
        // (speed scales with the new remaining distance, no restart from rest,
        // which on shortDuration spiked the scroll's speed several times over).
        // with under 5% of the curve left the solve amplifies too much, so a
        // move that near its end restarts instead
        if (running && sameTile && scroll === move.scroll) {
            const e0 = Config.curveAt(move.lut, move.t);
            if (1 - e0 >= 0.05) {
                const solve = (cur, to) => (cur - to * e0) / (1 - e0);
                move.fromX = solve(highlight.x, c.x);
                move.fromY = solve(highlight.y, c.y);
                move.fromW = solve(highlight.width, c.w);
                move.fromH = solve(highlight.height, c.h);
                move.toX = c.x;
                move.toY = c.y;
                move.toW = c.w;
                move.toH = c.h;
                if (scroll) {
                    move.fromCX = solve(view.contentX, cx);
                    move.toCX = cx;
                }
                if (Config.frameLog)
                    console.warn("[synopsis] " + Date.now() + " strip move retarget id=" + id + " t=" + move.t.toFixed(3) + " hx=" + highlight.x.toFixed(1) + "->" + c.x.toFixed(1) + " cx=" + view.contentX.toFixed(1) + "->" + move.toCX.toFixed(1) + " scroll=" + (scroll ? 1 : 0));
                return;
            }
        }
        moveAnim.stop();
        if (scroll)
            scrollAnim.stop();
        move.fromX = highlight.x;
        move.fromY = highlight.y;
        move.fromW = highlight.width;
        move.fromH = highlight.height;
        move.toX = c.x;
        move.toY = c.y;
        move.toW = c.w;
        move.toH = c.h;
        move.fromCX = view.contentX;
        move.toCX = cx;
        move.baseCX = base;
        move.scroll = scroll;
        move.lut = sameTile ? Config.standardLut : Config.switchLut;
        move.tileId = id;
        moveAnim.duration = Math.max(1, sameTile ? Theme.shortDuration : Config.switchMs);
        if (Config.frameLog)
            console.warn("[synopsis] " + Date.now() + " strip move start id=" + id + " ms=" + moveAnim.duration + " hx=" + move.fromX.toFixed(1) + "->" + move.toX.toFixed(1) + " cx=" + move.fromCX.toFixed(1) + "->" + move.toCX.toFixed(1) + " scroll=" + (scroll ? 1 : 0) + " same=" + (sameTile ? 1 : 0));
        move.t = 0;
        moveAnim.start();
    }

    // move.t -> the highlight's geometry and, while it owns the view, contentX
    function stepMove() {
        const e = Config.curveAt(move.lut, move.t);
        highlight.x = move.fromX + (move.toX - move.fromX) * e;
        highlight.y = move.fromY + (move.toY - move.fromY) * e;
        highlight.width = move.fromW + (move.toW - move.fromW) * e;
        highlight.height = move.fromH + (move.toH - move.fromH) * e;
        // the last frame lands exactly on the snapped target
        if (move.scroll)
            view.contentX = move.t >= 1 ? move.toCX : move.fromCX + (move.toCX - move.fromCX) * e;
        if (!Config.frameLog || move.t <= 0)
            return;
        console.warn("[synopsis] " + Date.now() + " strip move t=" + move.t.toFixed(3) + " hx=" + highlight.x.toFixed(1) + " cx=" + view.contentX.toFixed(1) + " scroll=" + (move.scroll ? 1 : 0));
        if (move.t >= 1) {
            const left = view.contentX;
            const right = left + view.width;
            const shown = highlight.x >= left - 0.5 && highlight.x + highlight.width <= right + 0.5;
            console.warn("[synopsis] " + Date.now() + " strip move end id=" + move.tileId + " hx=" + highlight.x.toFixed(1) + " cx=" + left.toFixed(1) + " tile=" + highlight.x.toFixed(1) + ".." + (highlight.x + highlight.width).toFixed(1) + " view=" + left.toFixed(1) + ".." + right.toFixed(1) + " visible=" + (shown ? 1 : 0) + " pad=" + strip.revealPad.toFixed(1));
        }
    }

    // itemAt() is typed QQuickItem; an untyped parameter keeps the call unchecked
    function tileCapture(item) {
        if (item)
            item.captureIdle();
    }

    // a window's thumb showed on one tile: the tile it left drops its copy
    function thumbArrived(address) {
        for (let i = 0; i < tiles.count; i++)
            strip.tileRelease(tiles.itemAt(i), address);
    }

    function tileRelease(item, address) {
        if (item)
            item.releaseLeaving(address);
    }

    // tiles scrolled fully out of view skip their idle refresh
    function captureIdle() {
        const left = view.contentX;
        const right = left + view.width;
        for (let i = 0; i < tiles.count; i++) {
            const item = tiles.itemAt(i);
            if (item && item.x + item.width > left && item.x < right)
                strip.tileCapture(item);
        }
    }

    ListModel {
        id: tileList
    }

    NumberAnimation {
        id: scrollAnim
        target: view
        property: "contentX"
        duration: Theme.shortDuration
        easing.type: Theme.standardEasing
    }

    // the highlight's move: one linear clock, mapped through lut in stepMove
    QtObject {
        id: move

        property real t: 1
        property var lut: Config.switchLut
        property int tileId: 0
        // contentX follows the move only while this holds; any other scroll
        // (wheel, the bar, an edge drag, a reveal) clears it
        property bool scroll: false
        property real fromX: 0
        property real fromY: 0
        property real fromW: 0
        property real fromH: 0
        property real toX: 0
        property real toY: 0
        property real toW: 0
        property real toH: 0
        property real fromCX: 0
        property real toCX: 0
        // the view position the reveal was measured from, kept across a
        // same-tile retarget
        property real baseCX: 0

        onTChanged: strip.stepMove()
    }

    NumberAnimation {
        id: moveAnim
        target: move
        property: "t"
        from: 0
        to: 1
        duration: Config.switchMs
        easing.type: Easing.Linear
    }

    Timer {
        interval: 16
        repeat: true
        running: strip.edgeSpeed !== 0
        onTriggered: strip.scrollByPixels(strip.edgeSpeed)
    }

    // the row. not interactive itself: tile clicks, window drags and drops
    // keep working, and the clip keeps tiles scrolled out of view from taking
    // pointer or drop events
    Flickable {
        id: view

        // inside the section, so the section's hover covers it (see section)
        parent: section
        x: 0
        y: 0
        z: 0
        // whole device pixels (see strip.viewW), so the layer maps 1:1
        width: strip.viewW
        height: strip.viewH
        contentWidth: strip.row.contentWidth
        contentHeight: height
        interactive: false
        flickableDirection: Flickable.HorizontalFlick
        boundsBehavior: Flickable.StopAtBounds
        onContentWidthChanged: strip.updateFades()
        onWidthChanged: strip.updateFades()
        // the row scrolled under a held drag (edge auto-scroll, a scroll
        // animation) with no pointer event: re-probe at the last position
        onContentXChanged: {
            strip.updateFades();
            if (Overview.dragAddress !== "")
                Overview.dragRetarget();
            if (Config.frameLog && Overview.state !== "closed")
                console.warn("[synopsis] " + Date.now() + " strip cx=" + view.contentX.toFixed(2) + " layer=" + (strip.fadeLayer ? 1 : 0) + " fadeR=" + strip.fadeR.toFixed(3));
        }
        clip: true

        // the edge fades: the clipped viewport, tiles and highlight included,
        // drawn once through shaders/edgefade.frag, which scales alpha down to
        // 1 - fadeL / 1 - fadeR over fadeW at the two edges. one texture the
        // viewport's size and one pass, no mask texture, and only while a fade
        // shows (strip.fadeLayer); rendering only, so clicks, hovers and drops
        // reach the tiles exactly as without it. (a MultiEffect mask drew no
        // fade at all in the sim.) rebuild the .qsb after editing the .frag:
        // qsb --glsl "100 es,120,150" --hlsl 50 --msl 12 -o edgefade.frag.qsb edgefade.frag
        // no explicit textureSize: the default is the item size (whole
        // logical px, see strip.viewW) times the window's device pixel ratio,
        // exact because the size is a whole multiple of pixelStep. with the
        // view on the device grid (gridOffset) texel centres land on pixel
        // centres, so linear sampling returns each texel unmixed: as sharp as
        // nearest at rest, and still smooth while the flight moves the strip
        // off the grid or the width glides
        layer.enabled: strip.fadeLayer
        layer.smooth: true
        layer.effect: ShaderEffect {
            readonly property real fadeL: strip.fadeL
            readonly property real fadeR: strip.fadeR
            readonly property real edge: Math.min(0.5, strip.fadeW / Math.max(1, view.width))

            fragmentShader: Qt.resolvedUrl("shaders/edgefade.frag.qsb")
        }

        // fitting <-> overflowing: the viewport widens or narrows to make
        // room for the button, gated exactly as the tiles' own glide is
        Behavior on width {
            enabled: Overview.interactive
            NumberAnimation {
                duration: Theme.shortDuration
                easing.type: Theme.standardEasing
            }
        }

        Repeater {
            id: tiles
            model: tileList

            delegate: WorkspaceTile {
                id: tileItem

                required property int index
                required property int tileId
                required property bool fresh

                readonly property var cell: strip.row.tiles[tileItem.index] || ({
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
                onThumbShown: address => strip.thumbArrived(address)

                mon: strip.mon
                x: tileItem.cell.x
                y: tileItem.cell.y
                width: tileItem.cell.w
                height: tileItem.cell.h
                visible: tileItem.cell.w > 0

                // re-centring glides only while open: the opening and closing
                // flights lay the row out once and must not animate on top of
                // their own slide. the size is fixed, so it never animates
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

        // the one marker for the current workspace. placeHighlight and stepMove
        // set its geometry, on the same clock as the scroll that reveals it
        Rectangle {
            id: highlight

            property int placedId: 0

            visible: strip.activeCell !== null && strip.activeCell.w > 0
            color: "transparent"
            radius: Theme.cornerRadius
            border.width: Theme.spacingXXS
            border.color: Theme.primary
        }
    }

    // appends a virtual empty workspace to this monitor's strip; minimal by
    // design: idle is unfilled with a thin, low-contrast outline, hover
    // tints it translucent primary, press dips it. a fixed size, smaller
    // than a tile. a sibling of the scrolling view, not a tile in it: never
    // clipped or scrolled, always visible at strip.row.buttonX/Y (area-relative)
    Item {
        id: newWorkspaceButton

        readonly property bool hovered: plusHover.hovered
        readonly property bool pressed: plusMouse.pressed
        readonly property real bar: newWorkspaceButton.width >= 40 ? 2 : 1.5
        readonly property color glyphColor: newWorkspaceButton.hovered ? Theme.primary : Theme.surfaceVariantText

        parent: section
        x: strip.row.buttonX
        y: strip.row.buttonY
        z: 0
        width: strip.row.buttonSize
        height: strip.row.buttonSize
        visible: strip.row.buttonSize > 0
        scale: newWorkspaceButton.pressed ? 0.96 : (newWorkspaceButton.hovered ? 1.04 : 1.0)

        Behavior on x {
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
            radius: Math.max(2, Theme.cornerRadius * Config.stripButtonFraction)
            color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, newWorkspaceButton.pressed ? 0.2 : (newWorkspaceButton.hovered ? 0.12 : 0))
            border.width: 1
            border.color: newWorkspaceButton.hovered ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.5) : Qt.rgba(Theme.outlineVariant.r, Theme.outlineVariant.g, Theme.outlineVariant.b, 0.4)

            Behavior on color {
                ColorAnimation {
                    duration: Theme.shortDuration
                    easing.type: Theme.standardEasing
                }
            }

            Behavior on border.color {
                ColorAnimation {
                    duration: Theme.shortDuration
                    easing.type: Theme.standardEasing
                }
            }
        }

        // the plus glyph: two thin rounded bars crossed, sized off the button
        Rectangle {
            anchors.centerIn: parent
            width: Math.round(parent.width * 0.35)
            height: newWorkspaceButton.bar
            radius: height / 2
            color: newWorkspaceButton.glyphColor
        }

        Rectangle {
            anchors.centerIn: parent
            width: newWorkspaceButton.bar
            height: Math.round(parent.height * 0.35)
            radius: width / 2
            color: newWorkspaceButton.glyphColor
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
            onClicked: Overview.createWorkspace(strip.monName)
        }
    }

    // the tile section: the viewport, the gap and the pinned add button, down
    // to the bottom of the scroll bar. the viewport, the button, the wheel
    // area and the bar are its children (each sets parent: section), because
    // qt delivers hover to the topmost hovered item and its ancestors only: a
    // hovered child (a tile's or the button's or the bar's HoverHandler) stops
    // it reaching siblings behind. as a sibling behind them, this handler lost
    // hover over every tile, and over the bar it flipped the bar hidden and
    // disabled, which dropped the bar's hover and showed it again, every event.
    // as their ancestor it stays hovered over all of them. passive, so it
    // never takes a click, a drag or a drop
    Item {
        id: section

        // on the device pixel grid at rest (strip.gridOffset), which puts the
        // viewport and its layer there too
        x: strip.areaX + strip.gridOffset.x
        y: strip.areaY + strip.gridOffset.y
        width: Math.max(view.width, strip.row.buttonX + strip.row.buttonSize)
        height: scrollBar.y + scrollBar.height

        HoverHandler {
            id: sectionHover
            enabled: Overview.interactive
        }
    }

    // shift + wheel and horizontal wheel/touchpad scroll while overflowing.
    // no buttons and no hover, so clicks, hovers and drops pass straight through
    MouseArea {
        parent: section
        x: 0
        y: 0
        z: 1
        width: view.width
        height: scrollBar.y + scrollBar.height
        enabled: strip.overflow
        acceptedButtons: Qt.NoButton
        onWheel: wheel => strip.wheelScroll(wheel)
    }

    // a thin rounded bar under the tiles, only while the row overflows. it sits
    // in the gap below the strip area, so nothing is laid out around it and the
    // exposé never moves when it fades in or out
    Item {
        id: scrollBar

        readonly property bool active: barHover.hovered || barMouse.dragging
        // only on overflow, and only while the tile section is hovered, the
        // bar itself is dragged or a window drag is over the section
        readonly property bool revealed: strip.overflow && Overview.interactive && (sectionHover.hovered || barMouse.dragging || strip.dragOver)
        readonly property real thickness: scrollBar.active ? 6 : 4
        readonly property real handleW: Math.min(scrollBar.width, Math.max(24, scrollBar.width * view.width / Math.max(1, view.contentWidth)))
        readonly property real handleX: strip.maxScroll > 0 ? (view.contentX / strip.maxScroll) * (scrollBar.width - scrollBar.handleW) : 0

        parent: section
        x: 0
        y: strip.row.tileY + strip.row.tileH + 2
        z: 2
        width: view.width
        height: 14
        // opacity only: the bar's box never changes, so nothing moves when it
        // fades, and a hidden bar takes no clicks
        opacity: scrollBar.revealed ? 1 : 0
        visible: scrollBar.opacity > 0
        enabled: scrollBar.revealed

        Behavior on opacity {
            NumberAnimation {
                duration: 150
                easing.type: Theme.standardEasing
            }
        }

        Rectangle {
            id: track
            width: parent.width
            height: scrollBar.thickness
            y: (scrollBar.height - track.height) / 2
            radius: track.height / 2
            // the highlight colour, light and translucent
            color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.16)

            Behavior on height {
                NumberAnimation {
                    duration: Theme.shortDuration
                    easing.type: Theme.standardEasing
                }
            }
        }

        Rectangle {
            x: scrollBar.handleX
            y: track.y
            width: scrollBar.handleW
            height: track.height
            radius: track.radius
            // the strip highlight's colour (Theme.primary), nearly solid at
            // rest and solid while hovered or dragged
            color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, scrollBar.active ? 1 : 0.8)

            Behavior on color {
                ColorAnimation {
                    duration: Theme.shortDuration
                    easing.type: Theme.standardEasing
                }
            }
        }

        HoverHandler {
            id: barHover
        }

        // the handle drags; a press on the track pages by most of a view
        MouseArea {
            id: barMouse

            property bool dragging: false
            property real grabOffset: 0

            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            preventStealing: true
            onPressed: mouse => {
                if (mouse.x >= scrollBar.handleX && mouse.x <= scrollBar.handleX + scrollBar.handleW) {
                    barMouse.dragging = true;
                    barMouse.grabOffset = mouse.x - scrollBar.handleX;
                    strip.stopScroll();
                } else {
                    const page = view.width * 0.9;
                    strip.scrollTo(strip.userBase() + (mouse.x < scrollBar.handleX ? -page : page), true);
                }
            }
            onPositionChanged: mouse => {
                if (!barMouse.dragging)
                    return;
                const room = scrollBar.width - scrollBar.handleW;
                if (room > 0)
                    strip.scrollTo((mouse.x - barMouse.grabOffset) / room * strip.maxScroll, false);
            }
            onReleased: barMouse.dragging = false
            onCanceled: barMouse.dragging = false
            onWheel: wheel => strip.wheelScroll(wheel)
        }
    }
}
