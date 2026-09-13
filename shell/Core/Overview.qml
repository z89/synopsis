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
    // the thumb of the window being activated: drawn above the others for the
    // return flight, matching the raise hyprland does underneath the backdrop
    property string raisedAddress: ""

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
        // a close that never took off has thumbs that never passed the gate:
        // reversing it would fly captureless boxes over the backdrop
        if (root.state === "closing" && root.progress <= 0)
            root.finishClose(true);
        if (root.state === "closing") {
            // reverse the same flight from wherever it is
            root.closeAfterSlide = false;
            settle.stop();
            root.cancelFocus();
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

    // ---- focus handoff ---------------------------------------------------

    // hyprland refuses a window focus while a layer holds exclusive keyboard
    // focus (CFocusState::rawWindowFocus, "Refusing a keyboard focus to a window
    // because of an exclusive ls"), and when such a layer drops to none its
    // commit handler refocuses the last window, which pulls a just-switched
    // workspace straight back. so the overlay goes exclusive -> ondemand
    // (OverlayWindow) and every dispatch is confirmed against hyprland's own
    // events: activewindowv2 for a window, workspacev2 for a workspace. the
    // wayland commit and the ipc dispatch are not ordered against each other,
    // so an unconfirmed dispatch is simply sent again.
    property string focusKind: ""
    property string focusTarget: ""
    property string focusName: ""
    property bool focusRaise: false
    property int focusAttempts: 0
    readonly property bool focusPending: root.focusKind !== ""

    function requestFocus(kind, target, name, raise) {
        root.cancelFocus();
        root.focusKind = kind;
        root.focusTarget = "" + target;
        root.focusName = name || "";
        root.focusRaise = !!raise;
        root.focusAttempts = 0;
        // the layer has to stop being exclusive or the focus is refused; the
        // commit can still land after the dispatch, which is what the retry covers
        root.wantsFocus = false;
        // dispatching what hyprland already has would emit no event at all and
        // burn every retry (fuzz, a workspace tile for the active workspace)
        if (root.focusSatisfied()) {
            root.noteFocusConfirmed();
            return;
        }
        root.sendFocus();
    }

    // hyprland's own live view: activewindowv2 for the window, workspacev2 for
    // the active workspace of the focused monitor
    function focusSatisfied() {
        if (root.focusKind === "window")
            return HyprState.focusedAddress !== "" && HyprState.focusedAddress === root.focusTarget;
        if (root.focusKind === "workspace")
            return HyprState.activeWorkspaceId === parseInt(root.focusTarget, 10);
        return false;
    }

    property bool focusRecomputed: false

    function sendFocus() {
        if (!root.focusPending)
            return;
        // the window closed under us: recompute once, then give up
        if (root.focusKind === "window" && !root.findWindow(root.focusTarget)) {
            const retry = !root.focusRecomputed;
            const alt = retry ? root.closeFocusTarget() : "";
            console.warn("[synopsis] focus target gone " + root.focusTarget + (alt !== "" ? " -> " + alt : " giving up"));
            root.cancelFocus();
            if (alt !== "") {
                root.requestFocus("window", alt, "", false);
                root.focusRecomputed = true;
            }
            return;
        }
        root.focusAttempts++;
        if (root.focusKind === "window")
            HyprState.focusWindow(root.focusTarget);
        else
            HyprState.focusWorkspace(parseInt(root.focusTarget, 10), root.focusName);
        focusRetry.restart();
    }

    function cancelFocus() {
        focusRetry.stop();
        root.focusRecomputed = false;
        root.focusKind = "";
        root.focusTarget = "";
        root.focusName = "";
        root.focusRaise = false;
        root.focusAttempts = 0;
    }

    function noteFocusConfirmed() {
        const raise = root.focusRaise;
        const addr = root.focusTarget;
        if (Config.frameLog)
            console.warn("[synopsis] " + Date.now() + " focus confirmed " + root.focusKind + " " + addr + " tries=" + root.focusAttempts);
        root.cancelFocus();
        // a floating window is raised only once hyprland agrees it is focused,
        // matching the raise the return flight draws
        if (raise)
            HyprState.raiseWindow(addr);
    }

    Timer {
        id: focusRetry
        interval: Config.focusRetryMs
        repeat: false
        onTriggered: {
            if (!root.focusPending)
                return;
            if (root.focusSatisfied()) {
                root.noteFocusConfirmed();
                return;
            }
            if (root.focusAttempts >= Math.max(1, Config.focusRetries)) {
                console.warn("[synopsis] focus unconfirmed " + root.focusKind + " " + root.focusTarget + " after " + root.focusAttempts + " tries");
                root.cancelFocus();
                return;
            }
            if (Config.frameLog)
                console.warn("[synopsis] " + Date.now() + " focus retry " + root.focusKind + " " + root.focusTarget + " #" + (root.focusAttempts + 1));
            root.sendFocus();
        }
    }

    Connections {
        target: Hyprland

        function onRawEvent(event) {
            if (!root.focusPending)
                return;
            if (root.focusKind === "window") {
                if (event.name === "activewindowv2" && HyprState.normAddress(event.data) === root.focusTarget)
                    root.noteFocusConfirmed();
                return;
            }
            if (event.name === "workspacev2") {
                const id = parseInt(("" + event.data).split(",")[0], 10);
                if (id === parseInt(root.focusTarget, 10))
                    root.noteFocusConfirmed();
            }
        }
    }

    // what has to hold the keyboard once the overlay is gone. "" means the
    // window hyprland already has focused is on the active workspace of the
    // focused monitor, so nothing needs dispatching.
    function closeFocusTarget() {
        const mon = HyprState.focusedMonitor();
        if (!mon)
            return "";
        // a scratchpad is open on this monitor: whatever holds the keyboard
        // there must keep it, a dispatch would drop the special workspace
        const sw = mon.specialWorkspace || {};
        if ((sw.id !== undefined ? sw.id : 0) !== 0)
            return "";
        const aw = mon.activeWorkspace || {};
        const snapId = (aw.id !== undefined) ? aw.id : 0;
        // the event-fed id is live; the snapshot can be one debounce behind,
        // and a keybind switch followed straight by escape lands inside it
        const activeId = HyprState.activeWorkspaceId !== 0 ? HyprState.activeWorkspaceId : snapId;
        const focused = HyprState.focusedAddress;
        if (focused !== "") {
            const c = root.findWindow(focused);
            const wsId = (c && c.workspace && c.workspace.id !== undefined) ? c.workspace.id : 0;
            // focus already on a special workspace, or already where it belongs
            if (wsId < 0 || (c && wsId === activeId))
                return "";
        }
        return HyprState.lastFocusedOn(activeId);
    }

    // ---- activation ------------------------------------------------------

    function activateWindow(address, workspaceId, workspaceName, floating) {
        if (!address)
            return;
        root.raisedAddress = address;
        root.requestFocus("window", HyprState.normAddress(address), "", !!floating);
        root.close();
    }

    // the overlay stays up. the refresh that reports the new active workspace
    // starts the slide and the close together, so the thumbs slide in and land
    // on the real windows.
    function activateWorkspace(id, name) {
        if (!root.active)
            return;
        root.awaitingSwitch = true;
        root.switchTargetId = id;
        switchWatchdog.restart();
        // the real switch happens hidden behind the backdrop: make it
        // instant so nothing is still moving when the overlay drops
        HyprState.setAnimations(false);
        root.requestFocus("workspace", id, name, false);
    }

    // called by the expose of the monitor whose active workspace just changed.
    // true when this is the switch a tile click asked for: the flight runs back to
    // the real rects while the slide brings the new windows in.
    function noteWorkspaceSwitch(id) {
        if (!root.awaitingSwitch || id !== root.switchTargetId)
            return false;
        root.awaitingSwitch = false;
        root.switchTargetId = 0;
        switchWatchdog.stop();
        // the warp happens on hyprland's next animation tick; give it a few frames before re-enabling
        animRestore.restart();
        console.warn("[synopsis] switch landed id=" + id + " closing with slide");
        root.beginClose();
        return true;
    }

    property bool awaitingSwitch: false
    property int switchTargetId: 0

    // the switch never arrived: close the ordinary way
    Timer {
        id: switchWatchdog
        interval: Config.flightMs + 200
        repeat: false
        onTriggered: {
            if (!root.awaitingSwitch)
                return;
            console.warn("[synopsis] switch timeout id=" + root.switchTargetId);
            root.awaitingSwitch = false;
            root.switchTargetId = 0;
            HyprState.setAnimations(true);
            root.close();
        }
    }

    // lookups for the event-driven test hooks (shell.qml custom events)
    function findWindow(address) {
        const a = HyprState.normAddress(address);
        const clients = HyprState.snapshot.clients;
        for (let i = 0; i < clients.length; i++) {
            const c = clients[i];
            if (c && HyprState.normAddress(c.address) === a)
                return c;
        }
        return null;
    }

    function findWorkspace(id) {
        const ws = HyprState.snapshot.workspaces;
        for (let i = 0; i < ws.length; i++)
            if (ws[i] && ws[i].id === id)
                return ws[i];
        return null;
    }

    function activateWorkspaceById(id) {
        if (isNaN(id))
            return;
        const ws = root.findWorkspace(id);
        root.activateWorkspace(id, ws ? (ws.name || "") : "");
    }

    function activateWindowByAddress(address) {
        const c = root.findWindow(address);
        if (!c)
            return;
        const wsId = c.workspace ? c.workspace.id : 0;
        const wsName = c.workspace ? (c.workspace.name || "") : "";
        root.activateWindow(HyprState.normAddress(c.address), wsId, wsName, !!c.floating);
    }

    function moveWindowByAddress(address, workspaceId) {
        const c = root.findWindow(address);
        if (!c || isNaN(workspaceId))
            return;
        const ws = root.findWorkspace(workspaceId);
        root.moveWindow(HyprState.normAddress(c.address), workspaceId, ws ? (ws.name || "") : "");
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
            else if (root.slidesRunning > 0)
                root.closeAfterSlide = true;
            else
                root.finishClose();
        }
    }

    // a tile click closes while the exposé slides; the overlay must not hide
    // until the slide has landed or its last frames snap
    property int slidesRunning: 0
    property bool closeAfterSlide: false

    function noteSlideFinished() {
        if (root.closeAfterSlide && root.slidesRunning <= 0 && root.state === "closing") {
            root.closeAfterSlide = false;
            // hyprland's own workspace spring is still finishing behind the
            // backdrop; hold the settled frame until it has landed
            settle.restart();
        }
    }

    Timer {
        id: settle
        interval: Config.settleMs
        repeat: false
        onTriggered: {
            if (root.state === "closing")
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

    // while preparing, the backdrop is transparent and every thumb sits exactly
    // over its own real window, so the only honest thing to paint is nothing.
    // a workspace switch or a move between the toggle and the first flight
    // frame (a keybind right after the toggle keybind) makes every row a lie
    // until the next refresh lands: hide them all until it does.
    property bool prepareDirty: false

    Connections {
        target: Hyprland

        function onRawEvent(event) {
            if (root.state !== "preparing")
                return;
            if (event.name === "workspacev2" || event.name === "focusedmonv2" || event.name === "movewindowv2" || event.name === "activespecial")
                root.prepareDirty = true;
        }
    }

    Connections {
        target: HyprState

        // the refresh that carries the change has rebuilt every model by now
        function onRefreshed() {
            root.prepareDirty = false;
        }
    }

    function beginPrepare() {
        root.cancelFocus();
        root.raisedAddress = "";
        root.setState("preparing");
        root.progress = 0;
        root.wantsFocus = true;
        root.prepareDirty = false;
        Hyprland.refreshToplevels();
        HyprState.applyConfig(true, Config.hiddenFps);
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

    Timer {
        id: animRestore
        interval: Config.focusHandoffMs * 3
        repeat: false
        onTriggered: HyprState.setAnimations(true)
    }

    function beginClose() {
        // nothing has been painted over the desktop yet: drop the overlay
        // without a flight, the closing state would only show empty thumbs
        const fromPreparing = root.state === "preparing";
        root.closeAfterSlide = false;
        settle.stop();
        root.setState("closing");
        root.wantsFocus = false;
        // a tile click has already asked for a focus: keep it. otherwise decide
        // now what holds the keyboard afterwards, so a workspace switched by an
        // external keybind is not undone by hyprland refocusing the old window
        if (!root.focusPending) {
            const target = root.closeFocusTarget();
            if (target !== "")
                root.requestFocus("window", target, "", false);
        }
        root.awaitingFirstFrame = false;
        root.awaitingSwitch = false;
        root.switchTargetId = 0;
        switchWatchdog.stop();
        stagger.stop();
        gate.stop();
        watchdog.stop();
        prepareWatchdog.stop();
        refreshTimer.stop();
        if (fromPreparing) {
            root.finishClose();
            return;
        }
        root.runFlight(0);
    }

    // reopening: open() is reversing a close that never flew, so the render fps
    // it is about to raise again is not worth two config evals
    function finishClose(reopening) {
        root.closeAfterSlide = false;
        animRestore.stop();
        // a retry must never outlive the overlay. the layer unmaps right after
        // this, and hyprland refocuses whatever holds the keyboard then, so a
        // request still in flight gets one last dispatch before it is dropped
        if (root.focusPending) {
            if (Config.frameLog)
                console.warn("[synopsis] " + Date.now() + " focus still pending at finishClose: " + root.focusKind + " " + root.focusTarget);
            root.sendFocus();
            root.cancelFocus();
        }
        // deferred from beginClose: hyprland's config apply path stalls a frame
        // and the close flight has no frame to spare. one request, not two
        if (reopening)
            HyprState.setAnimations(true);
        else
            HyprState.applyConfig(true, Config.restFps);
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
        // thumbs registered during the closing flight restarted the stagger; it must
        // not run on into the closed state and re-attach everything at once (#1123)
        stagger.stop();
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
            // the exposé thumbs first: they sit over real windows that the
            // backdrop is about to hide, the strip tiles can come later
            const list = root.thumbs;
            let given = 0;
            for (let pass = 0; pass < 2 && given < 3; pass++) {
                for (let i = 0; i < list.length && given < 3; i++) {
                    if (!list[i].attached && (pass === 1 || list[i].gated)) {
                        list[i].attached = true;
                        given++;
                    }
                }
            }
            if (given === 0) {
                stagger.stop();
                root.attachPending = false;
                if (root.state === "preparing" && root.gateDeadline === 0)
                    root.gateDeadline = Date.now() + Config.gateTimeoutMs;
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
                // a thumb that never reported content: name it, this is the
                // frame the window would vanish from behind the backdrop
                const late = [];
                const all = root.thumbs;
                for (let k = 0; k < all.length; k++) {
                    const t = all[k];
                    if (t.gated && !t.ready)
                        late.push((t.win ? t.win.cls : "?") + "/" + (t.win ? t.win.workspaceId : 0) + " source=" + t.hasSource + " content=" + t.ready);
                }
                console.warn("[synopsis] gate deadline with " + late.length + " unready thumbs: " + late.join(", "));
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
            // nothing a refresh could show survives the close flight, and a
            // rebuilt model mid-flight costs frames
            if (root.active && root.state !== "closing" && !refreshTimer.running)
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

    // what the strip and the expose actually render: ids, names, window addresses
    // and rects, in stack order. the active workspace is deliberately in neither,
    // so switching workspace never rebuilds a tile, a thumb or a capture.
    function _rectKey(w) {
        return w.address + "@" + Math.round(w.x) + "," + Math.round(w.y) + "," + Math.round(w.w) + "," + Math.round(w.h);
    }

    function _listSignature(list) {
        const parts = [];
        for (let i = 0; i < list.length; i++)
            parts.push(root._rectKey(list[i]));
        return parts.join("|");
    }

    function _stripSignature(wsList) {
        const parts = [];
        for (let i = 0; i < wsList.length; i++)
            parts.push(wsList[i].id + ":" + wsList[i].name + "=" + root._listSignature(wsList[i].windows));
        return parts.join(";");
    }

    // one screen's view of the world, rebuilt whole, never patched.
    // version is the binding dependency on HyprState.snapshot.
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
        console.warn("[synopsis] model " + key + " ok=" + built.ok + " " + built.w + "x" + built.h + " active=" + built.activeId + " workspaces=" + built.workspaces.length + " expose=" + built.expose.length);
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
            specialId: 0,
            workspaces: [],
            expose: [],
            wsSig: "",
            exposeSig: ""
        };
        if (!monitorName)
            return out;

        const snap = HyprState.snapshot;
        const monitors = snap.monitors;
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
        out.specialId = specialId;

        // workspaces of this monitor
        const mine = {};
        const wsList = [];
        const workspaces = snap.workspaces;
        for (let j = 0; j < workspaces.length; j++) {
            const ws = workspaces[j];
            if (!ws || ws.monitor !== monitorName)
                continue;
            mine[ws.id] = true;
            if (ws.id < 0 && !Config.showSpecialWorkspaces)
                continue;
            // no "current" flag here on purpose: a tile compares its id with
            // mon.activeId, so a switch does not change the tile objects at all
            wsList.push({
                id: ws.id,
                name: ws.name || ("" + ws.id),
                windows: []
            });
        }
        wsList.sort(function (a, b) {
            return a.id - b.id;
        });

        // windows, from the compositor's own client vector
        const map = root.toplevelMap();
        const clients = snap.clients;
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
        out.wsSig = root._stripSignature(wsList);
        out.exposeSig = root._listSignature(expose);
        return out;
    }
}
