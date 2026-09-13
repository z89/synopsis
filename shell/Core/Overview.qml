pragma Singleton

// the whole overview state. every window, tile and animation binds to this and
// nothing else keeps a copy of "open" (plan.md, state machine).

import QtQuick
import Quickshell
import Quickshell.Hyprland

Singleton {
    id: root

    // closed -> preparing -> opening -> open -> closing -> closed
    property string state: "closed"
    property real progress: 0
    readonly property bool active: root.state !== "closed"
    readonly property bool interactive: root.state === "open"
    property bool wantsFocus: false

    // a dragged thumb rides above every tile and the exposé
    readonly property int dragZ: 1000

    readonly property int dataVersion: HyprState.dataVersion

    property int lastOpenLatencyMs: -1
    property int openRequestedAt: 0
    property bool awaitingFirstFrame: false

    // drag state: one drag at a time, within one monitor
    property string dragAddress: ""
    property int dropWorkspaceId: 0
    property string dropWorkspaceName: ""

    // "state" is a plain property here (Singleton is not an Item); its own
    // stateChanged signal is what FrameLog and the ui listen to.
    function setState(name) {
        if (root.state !== name)
            root.state = name;
    }

    // ---- public actions -------------------------------------------------

    function open() {
        if (root.state === "open" || root.state === "opening" || root.state === "preparing")
            return;
        root.openRequestedAt = Date.now();
        root.awaitingFirstFrame = true;
        if (root.state === "closing") {
            // reverse the same flight from wherever it is
            root.setState("opening");
            root.wantsFocus = true;
            HyprState.setRenderFps(Config.hiddenFps);
            root.runFlight(1);
            watchdog.restart();
            return;
        }
        root.beginPrepare();
    }

    function close() {
        if (root.state === "closed" || root.state === "closing")
            return;
        root.beginClose();
    }

    function toggle() {
        if (root.state === "closed" || root.state === "closing")
            root.open();
        else
            root.close();
    }

    function dropFocus() {
        root.wantsFocus = false;
    }

    // dropFocus() only takes effect once the layer surface is committed, so the
    // dispatch has to wait a turn or hyprland focuses us straight back
    function activateWindow(address, workspaceId, workspaceName, floating) {
        if (!address)
            return;
        root.dropFocus();
        Qt.callLater(function () {
            HyprState.focusWindow(address);
            if (floating)
                HyprState.raiseWindow(address);
        });
        root.close();
    }

    function activateWorkspace(id, name) {
        root.dropFocus();
        Qt.callLater(function () {
            HyprState.focusWorkspace(id, name);
        });
        root.close();
    }

    function moveWindow(address, workspaceId, workspaceName) {
        if (!address)
            return;
        HyprState.moveToWorkspace(address, workspaceId, workspaceName);
        refreshTimer.restart();
    }

    // ---- drag -----------------------------------------------------------

    function beginDrag(address) {
        root.dragAddress = address;
        root.dropWorkspaceId = 0;
        root.dropWorkspaceName = "";
    }

    function setDropTarget(id, name) {
        root.dropWorkspaceId = id;
        root.dropWorkspaceName = name;
    }

    function clearDropTarget(id) {
        if (root.dropWorkspaceId === id) {
            root.dropWorkspaceId = 0;
            root.dropWorkspaceName = "";
        }
    }

    // returns true when the drop resolved into a move
    function endDrag(address, fromWorkspaceId) {
        const target = root.dropWorkspaceId;
        const targetName = root.dropWorkspaceName;
        root.dragAddress = "";
        root.dropWorkspaceId = 0;
        root.dropWorkspaceName = "";
        if (target === 0 || target === fromWorkspaceId)
            return false;
        root.moveWindow(address, target, targetName);
        return true;
    }

    // ---- flight ---------------------------------------------------------

    NumberAnimation {
        id: flight
        target: root
        property: "progress"
        duration: Config.flightMs
        easing.type: Config.easingCurve
        onFinished: {
            if (flight.to === 1)
                root.setState("open");
            else
                root.finishClose();
        }
    }

    function runFlight(to) {
        flight.stop();
        const distance = Math.abs(to - root.progress);
        flight.from = root.progress;
        flight.to = to;
        flight.duration = Math.max(1, Math.round(Config.flightMs * distance));
        flight.start();
    }

    // ---- preparing ------------------------------------------------------

    function beginPrepare() {
        root.setState("preparing");
        root.progress = 0;
        root.wantsFocus = true;
        Hyprland.refreshToplevels();
        HyprState.setRenderFps(Config.hiddenFps);
        prepareWatchdog.restart();
        HyprState.refreshAll(function () {
            root.prepareReady();
        });
    }

    // the layer is mapped here with the scrim at 0 and thumbs at their real rects,
    // so the first painted frame matches the desktop. also run by the watchdog when
    // refreshAll never calls back, otherwise the thumbs stay unattached.
    function prepareReady() {
        if (root.state !== "preparing")
            return;
        root.gateDeadline = 0;
        root.attachPending = true;
        stagger.restart();
        gate.restart();
    }

    function startFlight() {
        if (root.state !== "preparing")
            return;
        gate.stop();
        prepareWatchdog.stop();
        root.setState("opening");
        root.runFlight(1);
        watchdog.restart();
    }

    Timer {
        id: prepareWatchdog
        interval: Config.flightMs + 200
        repeat: false
        onTriggered: {
            root.prepareReady();
            root.startFlight();
        }
    }

    Timer {
        id: watchdog
        interval: Config.flightMs + 200
        repeat: false
        onTriggered: {
            if (root.state === "opening") {
                flight.stop();
                root.progress = 1;
                root.setState("open");
            }
        }
    }

    // ---- closing --------------------------------------------------------

    function beginClose() {
        root.setState("closing");
        root.wantsFocus = false;
        root.awaitingFirstFrame = false;
        stagger.stop();
        gate.stop();
        watchdog.stop();
        prepareWatchdog.stop();
        refreshTimer.stop();
        HyprState.setRenderFps(Config.restFps);
        root.runFlight(0);
    }

    function finishClose() {
        root.progress = 0;
        root.detachAll();
        root.dragAddress = "";
        root.dropWorkspaceId = 0;
        root.setState("closed");
    }

    // ---- thumb registry and capture stagger ------------------------------

    property var thumbs: []
    property bool attachPending: false
    property real gateDeadline: 0

    function registerThumb(thumb) {
        root.thumbs.push(thumb);
        if (root.active) {
            root.attachPending = true;
            stagger.restart();
        }
    }

    function unregisterThumb(thumb) {
        const i = root.thumbs.indexOf(thumb);
        if (i >= 0)
            root.thumbs.splice(i, 1);
    }

    function detachAll() {
        const list = root.thumbs;
        for (let i = 0; i < list.length; i++)
            list[i].attached = false;
        root.attachPending = false;
    }

    // quickshell #1123: never hand out capture sources in one burst (plan.md, capture)
    Timer {
        id: stagger
        interval: 8
        repeat: true
        onTriggered: {
            const list = root.thumbs;
            let given = 0;
            for (let i = 0; i < list.length && given < 3; i++) {
                if (!list[i].attached) {
                    list[i].attached = true;
                    given++;
                }
            }
            if (given === 0) {
                stagger.stop();
                root.attachPending = false;
                if (root.state === "preparing" && root.gateDeadline === 0)
                    root.gateDeadline = Date.now() + Config.hasContentTimeoutMs;
            }
        }
    }

    Timer {
        id: gate
        interval: 16
        repeat: true
        onTriggered: {
            if (root.state !== "preparing") {
                gate.stop();
                return;
            }
            if (root.attachPending)
                return;
            if (root.gateDeadline > 0 && Date.now() >= root.gateDeadline) {
                root.startFlight();
                return;
            }
            const list = root.thumbs;
            for (let i = 0; i < list.length; i++) {
                if (list[i].gated && !list[i].ready)
                    return;
            }
            root.startFlight();
        }
    }

    Timer {
        id: refreshTimer
        interval: 60
        repeat: false
        onTriggered: {
            if (root.active)
                HyprState.refreshAll(null);
        }
    }

    Connections {
        target: HyprState

        function onModelsDirty() {
            if (root.active && !refreshTimer.running)
                refreshTimer.start();
        }
    }

    // ---- measurement ------------------------------------------------------

    function noteFirstFrame() {
        if (!root.awaitingFirstFrame)
            return;
        root.awaitingFirstFrame = false;
        root.lastOpenLatencyMs = Date.now() - root.openRequestedAt;
    }

    function statsJson() {
        const list = root.thumbs;
        let live = 0;
        let sourced = 0;
        for (let i = 0; i < list.length; i++) {
            if (list[i].hasSource) {
                sourced++;
                if (list[i].liveNow)
                    live++;
            }
        }
        return JSON.stringify({
            state: root.state,
            progress: root.progress,
            screens: Quickshell.screens.length,
            thumbs: list.length,
            captured: sourced,
            live: live,
            lastOpenLatencyMs: root.lastOpenLatencyMs,
            usingLua: Hyprland.usingLua
        });
    }

    // ---- models -----------------------------------------------------------

    function toplevelMap() {
        const map = {};
        const model = Hyprland.toplevels;
        const values = model ? model.values : [];
        for (let i = 0; i < values.length; i++) {
            const tl = values[i];
            if (tl)
                map[HyprState.normAddress(tl.address)] = tl;
        }
        return map;
    }

    // last model handed out per screen, so an unchanged refresh returns the same
    // object and the Repeaters do not destroy and recreate every thumb (#1123)
    property var _modelCache: ({})

    function _modelSignature(model) {
        return JSON.stringify(model, function (key, value) {
            // version bumps on every refresh, and a toplevel only matters as present
            if (key === "version")
                return undefined;
            if (key === "toplevel")
                return value ? 1 : 0;
            return value;
        });
    }

    // one screen's view of the world, rebuilt whole, never patched.
    // version is the binding dependency on HyprState.dataVersion.
    function modelFor(monitorName, version) {
        const built = root._buildModel(monitorName, version);
        const key = monitorName || "";
        const sig = root._modelSignature(built);
        const cached = root._modelCache[key];
        if (cached && cached.sig === sig)
            return cached.model;
        root._modelCache[key] = {
            sig: sig,
            model: built
        };
        return built;
    }

    function _buildModel(monitorName, version) {
        const out = {
            ok: false,
            name: monitorName || "",
            version: version,
            x: 0,
            y: 0,
            w: 0,
            h: 0,
            scale: 1,
            activeId: 0,
            activeName: "",
            workspaces: [],
            expose: []
        };
        if (!monitorName)
            return out;

        const monitors = HyprState.monitors;
        let mon = null;
        for (let i = 0; i < monitors.length; i++) {
            if (monitors[i] && monitors[i].name === monitorName)
                mon = monitors[i];
        }
        if (!mon)
            return out;

        out.ok = true;
        out.x = mon.x || 0;
        out.y = mon.y || 0;
        out.scale = mon.scale || 1;
        out.w = (mon.width || 0) / out.scale;
        out.h = (mon.height || 0) / out.scale;
        const aw = mon.activeWorkspace || {};
        out.activeId = (aw.id !== undefined) ? aw.id : 0;
        out.activeName = aw.name || "";
        const sw = mon.specialWorkspace || {};
        const specialId = (sw.id !== undefined) ? sw.id : 0;

        // workspaces of this monitor
        const mine = {};
        const wsList = [];
        const workspaces = HyprState.workspaces;
        for (let j = 0; j < workspaces.length; j++) {
            const ws = workspaces[j];
            if (!ws || ws.monitor !== monitorName)
                continue;
            mine[ws.id] = true;
            if (ws.id < 0 && !Config.showSpecialWorkspaces)
                continue;
            wsList.push({
                id: ws.id,
                name: ws.name || ("" + ws.id),
                current: ws.id === out.activeId || (specialId !== 0 && ws.id === specialId),
                windows: []
            });
        }
        wsList.sort(function (a, b) {
            return a.id - b.id;
        });

        // windows, from the compositor's own client vector
        const map = root.toplevelMap();
        const clients = HyprState.clients;
        const byId = {};
        const entries = [];
        for (let k = 0; k < clients.length; k++) {
            const c = clients[k];
            if (!c || c.mapped === false)
                continue;
            const ws = c.workspace || {};
            const wsId = (ws.id !== undefined) ? ws.id : 0;
            if (mine[wsId] === undefined)
                continue;
            const at = c.at || [0, 0];
            const size = c.size || [0, 0];
            const address = HyprState.normAddress(c.address);
            entries.push({
                address: address,
                toplevel: map[address] || null,
                x: (at[0] || 0) - out.x,
                y: (at[1] || 0) - out.y,
                w: Math.max(1, size[0] || 0),
                h: Math.max(1, size[1] || 0),
                floating: c.floating === true,
                pinned: c.pinned === true,
                fullscreen: !!c.fullscreen,
                cls: c.class || "",
                title: c.title || "",
                workspaceId: wsId,
                workspaceName: ws.name || ("" + wsId)
            });
        }

        const order = HyprState.stackOrder(entries.map(function (e) {
            return e.address;
        }));
        const rank = {};
        for (let n = 0; n < order.length; n++)
            rank[order[n]] = n;
        entries.sort(function (a, b) {
            return rank[a.address] - rank[b.address];
        });

        for (let t = 0; t < wsList.length; t++)
            byId[wsList[t].id] = wsList[t];

        const expose = [];
        for (let e = 0; e < entries.length; e++) {
            const entry = entries[e];
            const bucket = byId[entry.workspaceId];
            if (bucket)
                bucket.windows.push(entry);
            const onActive = entry.workspaceId === out.activeId || (specialId !== 0 && entry.workspaceId === specialId);
            if (onActive || entry.pinned)
                expose.push(entry);
        }

        out.workspaces = wsList;
        out.expose = expose;
        return out;
    }
}
