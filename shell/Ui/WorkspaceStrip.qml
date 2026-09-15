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
    readonly property real maxScroll: Math.max(0, strip.row.contentWidth - strip.row.viewportWidth)

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

    opacity: strip.progress
    // off the top edge at rest, in place at full progress
    y: (strip.progress - 1) * (strip.areaY + strip.areaH)

    onWsSigChanged: strip.syncTiles()
    onTileScaleChanged: strip.publishTileScale()
    onActiveCellChanged: Qt.callLater(strip.placeHighlight)
    onRowChanged: Qt.callLater(strip.clampScroll)
    onOverflowChanged: {
        if (Config.frameLog) {
            console.warn("[synopsis] " + Date.now() + " strip overflow " + (strip.overflow ? "on " : "off ") + strip.monName + " tiles=" + tileList.count + " w=" + strip.row.tileW.toFixed(1) + " h=" + strip.row.tileH.toFixed(1));
            console.warn("[synopsis] " + Date.now() + " strip overflow " + (strip.overflow ? "on " : "off ") + strip.monName + " tiles=" + tileList.count + " viewport=" + strip.row.viewportWidth.toFixed(1) + " button=" + strip.row.buttonX.toFixed(1) + " size=" + strip.row.buttonSize.toFixed(1) + " area=" + strip.areaW.toFixed(1) + " gap=" + strip.buttonGap.toFixed(1));
        }
        if (!strip.overflow)
            strip.scrollTo(0, true);
    }
    Component.onCompleted: {
        strip.syncTiles();
        strip.publishTileScale();
        strip.placeHighlight();
    }

    Connections {
        target: Overview

        function onStateChanged() {
            const s = Overview.state;
            // on open the active workspace's tile is scrolled into view at once
            if (s === "preparing" || s === "opening")
                Qt.callLater(strip.revealActive);
            if (Config.frameLog && (s === "open" || s === "closing"))
                console.warn("[synopsis] " + Date.now() + " strip tile w=" + strip.row.tileW.toFixed(1) + " h=" + strip.row.tileH.toFixed(1) + " tiles=" + tileList.count + " on " + strip.monName + " (" + s + ")");
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
        for (let r = tileList.count - 1; r >= 0; r--)
            if (!wanted[tileList.get(r).tileId])
                tileList.remove(r);
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
                tileList.insert(i, {
                    tileId: id,
                    fresh: animate
                });
                inserted = id;
            }
        }
        strip.tilesRevision++;
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

    // where the view is heading: the running animation's end, else where it is
    function scrollTarget() {
        return scrollAnim.running ? scrollAnim.to : view.contentX;
    }

    // clamped to the row; animated only while open, so opening and closing
    // never scroll under their own flight
    function scrollTo(x, animate) {
        const target = Math.max(0, Math.min(x, strip.maxScroll));
        if (!animate || !Overview.interactive) {
            scrollAnim.stop();
            view.contentX = target;
            return;
        }
        if (scrollAnim.running && Math.abs(scrollAnim.to - target) < 0.5)
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

    // the smallest scroll that shows [left, right] with a gap of margin
    function reveal(left, right, animate) {
        const pad = Config.stripGap;
        const viewportW = strip.row.viewportWidth;
        let x = strip.scrollTarget();
        if (right + pad > x + viewportW)
            x = right + pad - viewportW;
        if (left - pad < x)
            x = left - pad;
        strip.scrollTo(x, animate);
    }

    function clampScroll() {
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
        strip.revealId = 0;
        const c = index >= 0 ? strip.row.tiles[index] : null;
        if (!c)
            return;
        strip.reveal(c.x, c.x + c.w, true);
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
            strip.scrollTo(strip.scrollTarget() - wheel.pixelDelta.x, false);
            return;
        }
        const delta = horizontal ? wheel.angleDelta.x : wheel.angleDelta.y;
        strip.scrollTo(strip.scrollTarget() - delta / 120 * (strip.row.tileW + Config.stripGap), true);
    }

    // the highlight is placed here rather than bound, so each move picks its own
    // timing: staying on the same workspace while the row re-centres or
    // resizes follows the tiles (their duration and easing), moving to another
    // workspace travels like the exposé slide. deferred with callLater so an
    // activeId and a layout change from one model rebuild land as one move
    function placeHighlight() {
        const c = strip.activeCell;
        const id = (c && strip.activeIndex >= 0 && strip.activeIndex < tileList.count) ? tileList.get(strip.activeIndex).tileId : 0;
        const sameTile = id !== 0 && id === highlight.placedId;
        highlight.moveMs = sameTile ? Theme.shortDuration : Config.switchMs;
        highlight.moveEasing = sameTile ? Theme.standardEasing : Config.switchCurve;
        highlight.placedId = id;
        if (!c)
            return;
        highlight.x = c.x;
        highlight.y = c.y;
        highlight.width = c.w;
        highlight.height = c.h;
    }

    // itemAt() is typed QQuickItem; an untyped parameter keeps the call unchecked
    function tileCapture(item) {
        if (item)
            item.captureIdle();
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

    Timer {
        interval: 16
        repeat: true
        running: strip.edgeSpeed !== 0
        onTriggered: strip.scrollTo(view.contentX + strip.edgeSpeed, false)
    }

    // the row. not interactive itself: tile clicks, window drags and drops
    // keep working, and the clip keeps tiles scrolled out of view from taking
    // pointer or drop events
    Flickable {
        id: view

        x: strip.areaX
        y: strip.areaY
        width: strip.row.viewportWidth
        height: strip.areaH
        contentWidth: strip.row.contentWidth
        contentHeight: height
        interactive: false
        flickableDirection: Flickable.HorizontalFlick
        boundsBehavior: Flickable.StopAtBounds
        // the row scrolled under a held drag (edge auto-scroll, a scroll
        // animation) with no pointer event: re-probe at the last position
        onContentXChanged: {
            if (Overview.dragAddress !== "")
                Overview.dragRetarget();
        }
        clip: true

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

        // the one marker for the current workspace. placeHighlight sets its geometry
        // and the timing of each move
        Rectangle {
            id: highlight

            property int placedId: 0
            property int moveMs: Config.switchMs
            property int moveEasing: Config.switchCurve

            visible: strip.activeCell !== null && strip.activeCell.w > 0
            color: "transparent"
            radius: Theme.cornerRadius
            border.width: Theme.spacingXXS
            border.color: Theme.primary

            Behavior on x {
                // snaps while the strip is off screen (preparing, opening, closed) and
                // travels only when it can be seen: open, and the close after a tile click
                enabled: Overview.interactive || Overview.state === "closing"
                NumberAnimation {
                    duration: highlight.moveMs
                    easing.type: highlight.moveEasing
                }
            }

            Behavior on y {
                enabled: Overview.interactive || Overview.state === "closing"
                NumberAnimation {
                    duration: highlight.moveMs
                    easing.type: highlight.moveEasing
                }
            }

            Behavior on width {
                enabled: Overview.interactive || Overview.state === "closing"
                NumberAnimation {
                    duration: highlight.moveMs
                    easing.type: highlight.moveEasing
                }
            }

            Behavior on height {
                enabled: Overview.interactive || Overview.state === "closing"
                NumberAnimation {
                    duration: highlight.moveMs
                    easing.type: highlight.moveEasing
                }
            }
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

        x: strip.areaX + strip.row.buttonX
        y: strip.areaY + strip.row.buttonY
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

    // shift + wheel and horizontal wheel/touchpad scroll while overflowing.
    // no buttons and no hover, so clicks, hovers and drops pass straight through
    MouseArea {
        x: view.x
        y: view.y
        width: view.width
        height: scrollBar.y + scrollBar.height - view.y
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
        readonly property real thickness: scrollBar.active ? 6 : 4
        readonly property real handleW: Math.min(scrollBar.width, Math.max(24, scrollBar.width * view.width / Math.max(1, view.contentWidth)))
        readonly property real handleX: strip.maxScroll > 0 ? (view.contentX / strip.maxScroll) * (scrollBar.width - scrollBar.handleW) : 0

        x: view.x
        y: view.y + strip.row.tileY + strip.row.tileH + 2
        width: view.width
        height: 14
        opacity: strip.overflow ? 1 : 0
        visible: scrollBar.opacity > 0
        enabled: strip.overflow && Overview.interactive

        Behavior on opacity {
            NumberAnimation {
                duration: Theme.shortDuration
                easing.type: Theme.standardEasing
            }
        }

        Rectangle {
            id: track
            width: parent.width
            height: scrollBar.thickness
            y: (scrollBar.height - track.height) / 2
            radius: track.height / 2
            color: Qt.rgba(Theme.outlineVariant.r, Theme.outlineVariant.g, Theme.outlineVariant.b, 0.15)

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
            color: scrollBar.active ? Theme.primary : Theme.outlineVariant

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
                    scrollAnim.stop();
                } else {
                    const page = view.width * 0.9;
                    strip.scrollTo(strip.scrollTarget() + (mouse.x < scrollBar.handleX ? -page : page), true);
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
