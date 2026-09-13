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
    // clicks are accepted through the opening flight too, so the first clicks
    // after the keybind are not swallowed: the flight is reversible, so a thumb
    // or a tile hit during it is honoured. dragging still waits for interactive,
    // it needs a layout that has stopped moving.
    readonly property bool clickable: root.state === "open" || root.state === "opening"
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
    // the scale a window is drawn at inside a strip tile, published by the strip.
    // a dragged thumb shrinks to it so the strip stays visible under the drag
    property real dropTileScale: 0

    // a tile clicked during preparing or opening was held back until the
    // exposé stopped moving: dispatch it now, on the frame we become open
    onStateChanged: {
        if (root.state === "open" && root.pendingWorkspaceId !== 0) {
            const id = root.pendingWorkspaceId;
            const nm = root.pendingWorkspaceName;
            root.pendingWorkspaceId = 0;
            root.pendingWorkspaceName = "";
            if (Config.frameLog)
                console.warn("[synopsis] " + Date.now() + " pending switch dispatch " + id);
            root.activateWorkspace(id, nm);
        }
    }

    // "state" is a plain property here (Singleton is not an Item); its own
    // stateChanged signal is what FrameLog and the ui listen to.
    function setState(name) {
        if (root.state !== name)
            root.state = name;
    }

    // ---- input coalescing -------------------------------------------------

    // a held keybind repeats at 25-40 Hz and a double click sends two presses:
    // the second one is not a second intent, and acting on it restarts an open
    // that has painted nothing yet (recording 20260914-020010, ten toggles in
    // 1.56 s, every one of them restarting an invisible preparing phase).
    // one timestamp per verb, not one for all of them: a keybind open followed
    // by escape or enter inside the window is two different intents, and a
    // shared timestamp swallowed the close. the stamp is also written only when
    // the verb actually moved the state machine, so a no-op open while open
    // does not push the next close out of reach.
    property var lastInputAt: ({
            toggle: 0,
            open: 0,
            close: 0,
            confirm: 0
        })

    function acceptInput(verb) {
        const now = Date.now();
        const prev = root.lastInputAt[verb] || 0;
        // <=, not <: hyprland's default repeat_rate 25 delivers a held key every
        // exactly 40 ms, so a strictly-less test with a 40 ms window coalesced
        // nothing at all
        if (now - prev <= Config.inputCoalesceMs) {
            if (Config.frameLog)
                console.warn("[synopsis] " + now + " coalesced " + verb);
            return false;
        }
        return true;
    }

    // called after the verb ran, with the state it found on entry: an intent
    // that changed nothing was not an intent
    function noteInput(verb, before) {
        if (root.state === before)
            return;
        root.lastInputAt[verb] = Date.now();
    }

    // ---- public actions -------------------------------------------------

    // the public verbs are coalesced; everything inside the state machine calls
    // openNow/closeNow so one accepted intent is never counted twice
    function open() {
        if (!root.acceptInput("open"))
            return;
        const before = root.state;
        root.openNow();
        root.noteInput("open", before);
    }

    function openNow() {
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
            root.pinnedActive = null;
            root.closeAfterSlide = false;
            settle.stop();
            root.cancelFocus();
            root.setState("opening");
            root.wantsFocus = true;
            restFpsDefer.stop();
            HyprState.setRenderFps(Config.hiddenFps);
            root.runFlight(1);
            watchdog.restart();
            return;
        }
        root.beginPrepare();
    }

    function close() {
        if (!root.acceptInput("close"))
            return;
        const before = root.state;
        root.closeNow();
        root.noteInput("close", before);
    }

    function closeNow() {
        if (root.state === "closed" || root.state === "closing")
            return;
        root.beginClose();
    }

    function toggle() {
        if (!root.acceptInput("toggle"))
            return;
        const before = root.state;
        // during preparing this is the cancel path: beginClose sees fromPreparing,
        // drops the layer with no flight and leaves no request applying to it
        if (root.state === "closed" || root.state === "closing")
            root.openNow();
        else
            root.closeNow();
        root.noteInput("toggle", before);
    }

    // enter the workspace currently shown, same as clicking the active tile:
    // closing already hands focus to a window on the active workspace
    function confirm() {
        if (!root.acceptInput("confirm"))
            return;
        const before = root.state;
        if (root.state === "open" || root.state === "opening")
            root.closeNow();
        root.noteInput("confirm", before);
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

    // the wayland commit that turns the layer from Exclusive into OnDemand and
    // the ipc dispatch are not ordered against each other, and a window focus
    // sent before that commit is refused (every window-click close in recording
    // 20260914-020010 confirmed on the retry, tries=2, 61 ms late). the commit
    // rides on the overlay's next frame, so the first window dispatch waits for
    // that frame (OverlayWindow.onFrameSwapped) or for Config.focusCommitMs,
    // whichever is first. the retry stays as the fallback.
    property bool exclusiveDropPending: false
    property bool awaitingFocusCommit: false
    property real focusCommitAt: 0

    onWantsFocusChanged: {
        if (root.wantsFocus) {
            root.exclusiveDropPending = false;
            root.awaitingFocusCommit = false;
            focusCommit.stop();
        } else {
            root.exclusiveDropPending = true;
        }
    }

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
        root.sendFocusWhenCommitted();
    }

    function sendFocusWhenCommitted() {
        if (!root.focusPending)
            return;
        // a workspace dispatch is never refused by an exclusive layer (tries=1 at
        // +1-3 ms in every recording): it keeps the immediate path
        if (root.focusKind !== "window" || !root.exclusiveDropPending || Config.focusCommitMs <= 0) {
            root.sendFocus();
            return;
        }
        root.awaitingFocusCommit = true;
        root.focusCommitAt = Date.now();
        focusCommit.restart();
        if (Config.frameLog)
            console.warn("[synopsis] " + root.focusCommitAt + " focus deferred window " + root.focusTarget + " for ondemand commit");
    }

    function focusCommitDone(why) {
        if (!root.awaitingFocusCommit)
            return;
        root.awaitingFocusCommit = false;
        root.exclusiveDropPending = false;
        focusCommit.stop();
        if (Config.frameLog)
            console.warn("[synopsis] " + Date.now() + " focus commit " + why + " after " + Math.round(Date.now() - root.focusCommitAt) + " ms");
        root.sendFocus();
    }

    // the overlay swapped a frame, so its ondemand commit is with hyprland
    function noteFocusCommitFrame() {
        root.focusCommitDone("frame");
    }

    Timer {
        id: focusCommit
        interval: Math.max(1, Config.focusCommitMs)
        repeat: false
        onTriggered: root.focusCommitDone("timer")
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

    // true when the pending request is the one the user asked for (a clicked
    // thumb or tile), false for the focus the close picks by itself. only the
    // second kind may be thrown away when the overlay goes down.
    property bool focusIsUserIntent: false

    // a user-intent focus that outlived the unmap (finishClose). while it is set
    // the chain is short (Config.focusRetriesClosed) and any sign that the user
    // went somewhere else abandons it: the overlay is gone, so a dispatch landing
    // 300 ms later would drag them off the workspace they just switched to.
    property bool focusPostClose: false
    property int focusClosedAttempts: 0
    // the workspace the target window was on when the overlay went down
    property int focusTargetWorkspaceId: 0

    function abandonFocus(reason) {
        if (Config.frameLog)
            console.warn("[synopsis] " + Date.now() + " focus abandoned " + reason);
        root.cancelFocus();
    }

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
        if (root.focusPostClose)
            root.focusClosedAttempts++;
        if (root.focusKind === "window")
            HyprState.focusWindow(root.focusTarget);
        else
            HyprState.focusWorkspace(parseInt(root.focusTarget, 10), root.focusName);
        focusRetry.restart();
    }

    function cancelFocus() {
        focusRetry.stop();
        focusCommit.stop();
        root.awaitingFocusCommit = false;
        root.focusRecomputed = false;
        root.focusKind = "";
        root.focusTarget = "";
        root.focusName = "";
        root.focusRaise = false;
        root.focusAttempts = 0;
        root.focusIsUserIntent = false;
        root.focusPostClose = false;
        root.focusClosedAttempts = 0;
        root.focusTargetWorkspaceId = 0;
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
            // after the unmap the overlay is no longer on screen to explain what
            // is moving the focus around: two tries, ~120 ms, then stop
            if (root.focusPostClose && root.focusClosedAttempts >= Math.max(1, Config.focusRetriesClosed)) {
                root.abandonFocus("retries exhausted after close " + root.focusKind + " " + root.focusTarget);
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
                const addr = HyprState.normAddress(event.name === "activewindowv2" ? event.data : "");
                if (event.name === "activewindowv2" && addr === root.focusTarget) {
                    root.noteFocusConfirmed();
                    return;
                }
                // the overlay is down: the user is driving now. an empty address
                // is the unmap itself losing the focus, not a choice, so only a
                // real other window counts.
                if (root.focusPostClose && root.state === "closed") {
                    if (event.name === "activewindowv2" && addr !== "" && root.focusAttempts > 0) {
                        root.abandonFocus("window " + addr + " focused instead of " + root.focusTarget);
                        return;
                    }
                    if (event.name === "workspacev2") {
                        const wsId = parseInt(("" + event.data).split(",")[0], 10);
                        if (!isNaN(wsId) && root.focusTargetWorkspaceId !== 0 && wsId !== root.focusTargetWorkspaceId) {
                            root.abandonFocus("workspace " + wsId + " entered, target is on " + root.focusTargetWorkspaceId);
                            return;
                        }
                    }
                }
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
        if (Config.frameLog)
            console.warn("[synopsis] " + Date.now() + " activate window " + HyprState.normAddress(address) + " during " + root.state + " progress=" + root.progress.toFixed(2));
        root.requestFocus("window", HyprState.normAddress(address), "", !!floating);
        root.focusIsUserIntent = true;
        // clicked during the opening flight: beginClose reverses the same flight
        // from wherever it is, so the thumb flies straight back to its window
        root.closeNow();
    }

    // the overlay stays up. the refresh that reports the new active workspace
    // starts the slide and the close together, so the thumbs slide in and land
    // on the real windows.
    // a switch asked for before the exposé has ever been still: the dispatch
    // would race the flight it is drawn over, and the close it triggers would
    // start before the open finished. hold it and send it the moment we are open.
    property int pendingWorkspaceId: 0
    property string pendingWorkspaceName: ""

    function activateWorkspace(id, name) {
        if (!root.active)
            return;
        if (root.state === "preparing" || root.state === "opening") {
            root.pendingWorkspaceId = id;
            root.pendingWorkspaceName = name || "";
            if (Config.frameLog)
                console.warn("[synopsis] " + Date.now() + " activate workspace " + id + " pending until open");
            return;
        }
        // a second tile click while the first switch is still in flight: the
        // old request is dropped whole (its workspacev2 would otherwise land
        // after the retarget and be ignored, hanging the close on the watchdog)
        // a newer dispatch for the same id: whatever arrives now is this one
        if (id === root.staleSwitchId)
            root.forgetStaleSwitch();
        root.rememberIntendedWorkspace(id);
        if (root.awaitingSwitch && root.switchTargetId !== id) {
            console.warn("[synopsis] switch retarget " + root.switchTargetId + " -> " + id);
            root.clearPendingSwitch();
        }
        root.awaitingSwitch = true;
        root.switchTargetId = id;
        switchWatchdog.restart();
        // the real switch happens hidden behind the backdrop: make it
        // instant so nothing is still moving when the overlay drops
        HyprState.setAnimations(false);
        root.requestFocus("workspace", id, name, false);
        root.focusIsUserIntent = true;
    }

    // called by the expose of the monitor whose active workspace just changed.
    // true when this is the switch a tile click asked for: the flight runs back to
    // the real rects while the slide brings the new windows in.
    function noteWorkspaceSwitch(id) {
        // the dispatch a keybind overrode was already on its way to hyprland:
        // this event is that dispatch landing, and the switch back it asks for
        // is the one to follow, not this one
        if (root.noteStaleSwitch(id))
            return false;
        if (!root.awaitingSwitch)
            return false;
        if (id !== root.switchTargetId) {
            // a keybind switched somewhere else while our tile click was in
            // flight: the user's switch wins. drop the pending one and let this
            // be an ordinary external switch, the overlay stays open and slides.
            console.warn("[synopsis] switch overridden target=" + root.switchTargetId + " got=" + id);
            // hyprland has our dispatch too: it lands a moment later and slides
            // the overview onto the workspace the user just left behind. remember
            // both ids for one gate timeout so that arrival can be undone.
            root.staleSwitchId = root.switchTargetId;
            root.staleSwitchUntil = Date.now() + Config.gateTimeoutMs;
            root.rememberIntendedWorkspace(id);
            root.clearPendingSwitch();
            animRestore.restart();
            return false;
        }
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

    // a tile-click switch that a keybind overrode: our dispatch is already with
    // hyprland and cannot be recalled, so when its workspacev2 arrives inside
    // the window below it is undone by switching back to where the user meant
    // to be. the event itself is never ignored, hyprland really did switch.
    property int staleSwitchId: 0
    property real staleSwitchUntil: 0
    property int intendedWorkspaceId: 0
    property string intendedWorkspaceName: ""

    function rememberIntendedWorkspace(id) {
        root.intendedWorkspaceId = id;
        const ws = root.findWorkspace(id);
        root.intendedWorkspaceName = ws ? (ws.name || "") : "";
    }

    function forgetStaleSwitch() {
        root.staleSwitchId = 0;
        root.staleSwitchUntil = 0;
    }

    // true when this event is the overridden dispatch landing
    function noteStaleSwitch(id) {
        if (root.staleSwitchId === 0)
            return false;
        if (Date.now() > root.staleSwitchUntil) {
            root.forgetStaleSwitch();
            return false;
        }
        if (id !== root.staleSwitchId)
            return false;
        const back = root.intendedWorkspaceId;
        const backName = root.intendedWorkspaceName;
        root.forgetStaleSwitch();
        if (back === 0 || back === id)
            return true;
        if (Config.frameLog)
            console.warn("[synopsis] " + Date.now() + " stale switch id=" + id + " landed, restoring " + back);
        // the dispatch only, not activateWorkspace: arming awaitingSwitch here
        // would make the workspace the user chose with their keybind look like a
        // tile click landing, and the overlay would close on it. a keybind
        // override keeps the overview open, so the workspacev2 this sends is
        // handled as the external switch it is: the exposé slides, nothing closes.
        HyprState.focusWorkspace(back, backName);
        return true;
    }

    // forget a tile-click switch: the request that would confirm it goes too,
    // or its retries outlive the switch they belong to
    function clearPendingSwitch() {
        root.awaitingSwitch = false;
        root.switchTargetId = 0;
        switchWatchdog.stop();
        if (root.focusKind === "workspace")
            root.cancelFocus();
    }

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
            root.closeNow();
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

    // called once the pointer has crossed the drag threshold, not on the press:
    // a plain click must not put the strip into drop mode or log a drag
    function beginDrag(address) {
        root.dragAddress = address;
        root.dropWorkspaceId = 0;
        root.dropWorkspaceName = "";
        if (Config.frameLog)
            console.warn("[synopsis] " + Date.now() + " drag begin " + address);
    }

    function setDropTarget(id, name) {
        root.dropWorkspaceId = id;
        root.dropWorkspaceName = name;
        if (Config.frameLog && root.dragAddress !== "")
            console.warn("[synopsis] " + Date.now() + " drag target " + id);
    }

    function clearDropTarget(id) {
        if (root.dropWorkspaceId === id) {
            root.dropWorkspaceId = 0;
            root.dropWorkspaceName = "";
        }
    }

    // returns true when the drop resolved into a move. it reads the drop target
    // before anything clears it, so the caller must call this before it drops
    // Drag.active: deactivating delivers DragLeave to the tile under the cursor
    // synchronously and would wipe the target first
    function endDrag(address, fromWorkspaceId) {
        const target = root.dropWorkspaceId;
        const targetName = root.dropWorkspaceName;
        const wasDragging = root.dragAddress !== "";
        root.dragAddress = "";
        root.dropWorkspaceId = 0;
        root.dropWorkspaceName = "";
        // a press that never crossed the threshold: a click, not a drag
        if (!wasDragging)
            return false;
        // onCanceled hands us no address while a tile still holds the drop
        // target: that is a cancel, not a move to it
        if (!address || target === 0 || target === fromWorkspaceId) {
            if (Config.frameLog)
                console.warn("[synopsis] " + Date.now() + " drag cancel");
            return false;
        }
        if (Config.frameLog)
            console.warn("[synopsis] " + Date.now() + " drag drop " + address + " -> " + target);
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

    // the deferred half of a cancelled prepare (see finishClose)
    Timer {
        id: restFpsDefer
        interval: Math.max(1, Config.restFpsDeferMs)
        repeat: false
        onTriggered: {
            if (root.active)
                return;
            if (Config.frameLog)
                console.warn("[synopsis] " + Date.now() + " deferred restFps " + Config.restFps);
            HyprState.setRenderFps(Config.restFps);
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

    // hyprland answers a request issued before a cancel long after it, and the
    // refresh and the eval both reply into closures. every beginPrepare and
    // every close bumps this; a reply, or the watchdog, whose captured
    // generation is not the live one belongs to a prepare nobody is waiting for
    // and is dropped. without it a stale refresh called prepareReady for the
    // *next* prepare and started its gate against the wrong snapshot.
    property int prepareGen: 0

    function bumpPrepareGen() {
        root.prepareGen = root.prepareGen + 1;
        return root.prepareGen;
    }

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

    // ---- prepare instrumentation ------------------------------------------

    // every hook below starts with prepareMeasuring, which is Config.frameLog
    // sampled once at beginPrepare: with frameLog off this costs one bool test
    // per hook and nothing else.
    property bool prepareMeasuring: false
    property bool prepareLogged: true
    property real prepareT0: 0
    property int prepareEvalMs: -1
    property int prepareRefreshMs: -1
    property int prepareBuildMs: -1
    property int prepareFirstFrameMs: -1
    property int prepareGateMs: -1

    function prepareBreakdown(force) {
        if (!root.prepareMeasuring || root.prepareLogged)
            return;
        if (!force && (root.prepareGateMs < 0 || root.prepareFirstFrameMs < 0))
            return;
        root.prepareLogged = true;
        console.warn("[synopsis] " + Date.now() + " prepare breakdown eval=" + root.prepareEvalMs + " refresh=" + root.prepareRefreshMs + " build=" + root.prepareBuildMs + " thumbs=" + root.thumbs.length + " firstFrame=" + root.prepareFirstFrameMs + " gate=" + root.prepareGateMs + " total=" + Math.round(Date.now() - root.prepareT0));
    }

    function beginPrepare() {
        const gen = root.bumpPrepareGen();
        root.prepareMeasuring = Config.frameLog;
        root.prepareLogged = !root.prepareMeasuring;
        root.prepareT0 = Date.now();
        root.prepareEvalMs = -1;
        root.prepareRefreshMs = -1;
        root.prepareBuildMs = -1;
        root.prepareFirstFrameMs = -1;
        root.prepareGateMs = -1;
        if (root.prepareMeasuring)
            console.warn("[synopsis] " + root.prepareT0 + " prepare begin");
        root.cancelFocus();
        root.pinnedActive = null;
        root.raisedAddress = "";
        root.pendingWorkspaceId = 0;
        root.pendingWorkspaceName = "";
        // a cancelled prepare left the render fps restore waiting: we are
        // opening again, so it never has to happen
        restFpsDefer.stop();
        root.setState("preparing");
        root.progress = 0;
        root.wantsFocus = true;
        root.prepareDirty = false;
        // the three j/ requests go out first. hyprland answers the request
        // socket in order and a config eval takes 35-70 ms to apply, which is
        // exactly how long j/monitors, j/workspaces and j/clients waited behind
        // it on every open in recording 20260914-020010 (all four replies at the
        // same instant, mid-session refreshes 0-2 ms). the eval only has to be
        // applied before a workspace switch is dispatched, and that cannot
        // happen before the overview is open. nothing is awaited either way:
        // both are in flight in the same tick, only the order changed.
        HyprState.refreshAll(function () {
            if (gen !== root.prepareGen)
                return;
            if (root.prepareMeasuring && root.prepareRefreshMs < 0)
                root.prepareRefreshMs = Math.round(Date.now() - root.prepareT0);
            root.prepareReady();
        });
        Hyprland.refreshToplevels();
        HyprState.applyConfig(true, Config.hiddenFps, root.prepareMeasuring ? function () {
            if (gen !== root.prepareGen)
                return;
            if (root.prepareEvalMs < 0)
                root.prepareEvalMs = Math.round(Date.now() - root.prepareT0);
        } : null);
        prepareWatchdog.gen = gen;
        prepareWatchdog.restart();
        if (root.prepareMeasuring)
            console.warn("[synopsis] " + Date.now() + " prepare sync end after " + Math.round(Date.now() - root.prepareT0) + " ms");
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
        if (root.prepareMeasuring && root.prepareGateMs < 0)
            root.prepareGateMs = Math.round(Date.now() - root.prepareT0);
        root.prepareBreakdown(true);
        root.setState("opening");
        root.runFlight(1);
        watchdog.restart();
    }

    Timer {
        id: prepareWatchdog
        // the generation beginPrepare started it for
        property int gen: 0
        interval: Config.flightMs + 200
        repeat: false
        onTriggered: {
            if (prepareWatchdog.gen !== root.prepareGen)
                return;
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
        // anything a prepare asked for belongs to a prepare that is over
        root.bumpPrepareGen();
        // nothing has been painted over the desktop yet: drop the overlay
        // without a flight, the closing state would only show empty thumbs
        const fromPreparing = root.state === "preparing";
        // freeze the workspace the flight is drawing: a switch that lands
        // inside the close would otherwise replace every thumb mid-flight
        root.pinnedActive = HyprState.activeByMonitor;
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
        root.pendingWorkspaceId = 0;
        root.pendingWorkspaceName = "";
        root.awaitingSwitch = false;
        root.switchTargetId = 0;
        switchWatchdog.stop();
        stagger.stop();
        gate.stop();
        watchdog.stop();
        prepareWatchdog.stop();
        refreshTimer.stop();
        if (fromPreparing) {
            if (root.prepareMeasuring) {
                console.warn("[synopsis] " + Date.now() + " cancel prepare after " + Math.round(Date.now() - root.prepareT0) + " ms eval=" + root.prepareEvalMs + " refresh=" + root.prepareRefreshMs + " build=" + root.prepareBuildMs + " firstFrame=" + root.prepareFirstFrameMs);
                root.prepareLogged = true;
                root.prepareMeasuring = false;
            }
            root.finishClose(false, true);
            return;
        }
        root.runFlight(0);
    }

    // reopening: open() is reversing a close that never flew, so the render fps
    // it is about to raise again is not worth two config evals
    function finishClose(reopening, cancelled) {
        root.closeAfterSlide = false;
        animRestore.stop();
        // nothing may still be applying to a closed overlay: beginClose bumped
        // prepareGen, so the refresh and the eval this prepare asked for reply
        // into a generation nobody waits for and neither one can start a gate
        // against a snapshot that belongs to the prepare before it
        root.prepareDirty = false;
        root.prepareMeasuring = false;
        root.pendingWorkspaceId = 0;
        root.pendingWorkspaceName = "";
        root.forgetStaleSwitch();
        // the layer unmaps right after this and hyprland refocuses whatever
        // holds the keyboard then, so a request still in flight is resolved now
        if (root.focusPending) {
            if (Config.frameLog)
                console.warn("[synopsis] " + Date.now() + " focus still pending at finishClose: " + root.focusKind + " " + root.focusTarget);
            // a window the user asked for, or one still waiting for the
            // ondemand commit: dispatching it here sends it while the layer is
            // still exclusive (refused) and cancelling it leaves nothing to
            // re-send, so a thumb clicked at the very start of the opening
            // flight ends with no focus at all. wantsFocus is already false and
            // the layer is going down, which is what makes the dispatch land,
            // so the deferred send (frame or focusCommitMs) and the retry chain
            // are left to finish; beginPrepare cancels them if the overview
            // opens again first.
            if (root.focusKind === "window" && (root.awaitingFocusCommit || root.focusIsUserIntent)) {
                root.wantsFocus = false;
                // from here the chain is short and abandonable: nothing is drawn
                // over the desktop any more, so a workspace the user switches to
                // meanwhile, or a window they focus themselves, ends it
                const target = root.findWindow(root.focusTarget);
                root.focusTargetWorkspaceId = (target && target.workspace && target.workspace.id !== undefined) ? target.workspace.id : 0;
                root.focusClosedAttempts = 0;
                root.focusPostClose = true;
                if (!root.awaitingFocusCommit)
                    root.sendFocus();
            } else {
                // the close picked this target itself and the intent is gone
                root.sendFocus();
                root.cancelFocus();
            }
        }
        // deferred from beginClose: hyprland's config apply path stalls a frame
        // and the close flight has no frame to spare. one request, not two
        if (reopening) {
            HyprState.setAnimations(true);
        } else if (cancelled && !HyprState.animationsSuppressed) {
            // a cancelled prepare painted nothing and never touched animations,
            // so the only thing to undo is the render fps. doing it here would
            // stall hyprland's request socket for 35-70 ms right where a
            // re-toggle wants it (recording 20260914-020010: the restFps eval at
            // t+0 made the next open's four requests all take 40 ms). defer it;
            // beginPrepare cancels the timer, so toggle spam costs no evals.
            restFpsDefer.restart();
        } else {
            HyprState.applyConfig(true, Config.restFps);
        }
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
        if (root.prepareMeasuring && root.prepareFirstFrameMs < 0) {
            root.prepareFirstFrameMs = Math.round(Date.now() - root.prepareT0);
            root.prepareBreakdown(false);
        }
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

    // the close flight draws the workspace the close started on. a keybind
    // switch landing inside it must not swap the thumbs out from under the
    // flight, so the live ids are pinned for the length of the close and
    // released when the overview is next prepared or the close is reversed.
    property var pinnedActive: null

    // HyprState.activeByMonitor is hyprland's live view; the snapshot's
    // activeWorkspace is as old as the request that fetched it. liveVersion is
    // the binding dependency, nothing more.
    function liveActiveId(monitorName, liveVersion): int {
        const map = root.pinnedActive !== null ? root.pinnedActive : HyprState.activeByMonitor;
        const id = map[monitorName];
        return (id === undefined) ? 0 : id;
    }

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
        // the first model built from the refresh that beginPrepare asked for
        if (root.prepareMeasuring && root.prepareBuildMs < 0 && root.prepareRefreshMs >= 0)
            root.prepareBuildMs = Math.round(Date.now() - root.prepareT0);
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
        // the event-fed id wins: a workspace switch reaches the strip and the
        // exposé on the event, one frame later, instead of waiting for a
        // refresh that reports the active workspace as of its own request time
        // (tuning.md 2026-09-13, event-driven active workspace)
        const liveId = root.liveActiveId(monitorName, HyprState.liveVersion);
        if (liveId !== 0 && liveId !== out.activeId) {
            out.activeId = liveId;
            out.activeName = "" + liveId;
            for (let a = 0; a < snap.workspaces.length; a++) {
                const w = snap.workspaces[a];
                if (w && w.id === liveId)
                    out.activeName = w.name || out.activeName;
            }
        }
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
