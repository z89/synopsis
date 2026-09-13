pragma Singleton

// hyprland glue: one-shot request-socket reads, dispatch formatting, stacking order.
// nothing here knows about the ui or the state machine.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

Singleton {
    id: root

    // j/clients is the compositor's own window vector, which is the z order for floating
    // windows (plan.md "data", phase 0 check 8). focusHistoryID is the fallback.
    readonly property bool useClientOrder: true

    property var monitors: []
    property var workspaces: []
    property var clients: []

    // the same three lists in one object, published in a single property write.
    // a binding that read the three properties separately rebuilt its model
    // three times per refresh, twice of them on a half-updated world (59 ms of
    // an 89 ms refresh, measured 2026-09-13). everything a binding reads has to
    // come from here; monitors/workspaces/clients stay for imperative callers.
    property var snapshot: ({
            monitors: [],
            workspaces: [],
            clients: [],
            version: 0
        })

    property int dataVersion: 0
    property bool lastRequestEmpty: false

    // the window hyprland last reported as focused, normalised and empty for
    // "nothing focused". the close path uses it to decide what has to hold
    // focus once the overlay is gone (tuning.md 2026-09-13, focus handoff).
    property string focusedAddress: ""

    // the active workspace of the focused monitor, kept live from workspacev2
    // so a focus request can tell "already there" from "not confirmed yet"
    property int activeWorkspaceId: 0

    // hyprland's own live answer to "which workspace is each monitor showing",
    // monitor name -> workspace id, fed by workspacev2 and focusedmonv2.
    // the snapshot cannot answer it: j/monitors describes the world as of the
    // request, three round trips (~90 ms) before it is applied, so a burst of
    // switches replays its stale intermediates long after the user stopped
    // (tuning.md 2026-09-13, event-driven active workspace).
    property var activeByMonitor: ({})

    // bumped on every change of that map, from an event or from a refresh:
    // the single dependency a model build needs to follow a switch in one frame
    property int liveVersion: 0

    // every workspace event bumps this. a refresh reply is only allowed to
    // republish the map when no event arrived while it was in flight.
    property int eventSeq: 0

    signal refreshed
    signal modelsDirty

    // ---- addresses ----------------------------------------------------

    function normAddress(a) {
        if (!a)
            return "";
        const s = "" + a;
        return s.indexOf("0x") === 0 ? s.substring(2) : s;
    }

    function selector(address) {
        return "address:0x" + root.normAddress(address);
    }

    // ---- one shot requests --------------------------------------------

    Component {
        id: requestComponent

        QtObject {
            id: req

            property string request: ""
            property var callback: null
            property bool finished: false
            property bool started: false
            property string buffer: ""

            function finish(text) {
                if (req.finished)
                    return;
                req.finished = true;
                req.timer.stop();
                req.socket.connected = false;
                const cb = req.callback;
                req.callback = null;
                if (cb)
                    cb(text);
                Qt.callLater(function () {
                    req.destroy();
                });
            }

            function start() {
                req.started = true;
                req.timer.start();
                req.socket.path = Hyprland.requestSocketPath;
                req.socket.connected = true;
            }

            // a dead socket must not strand the state machine in preparing
            property Timer timer: Timer {
                interval: 500
                repeat: false
                onTriggered: req.finish("")
            }

            property Socket socket: Socket {
                id: sock

                // empty splitMarker delivers every chunk as it arrives (no end-of-stream needed)
                parser: SplitParser {
                    splitMarker: ""
                    onRead: function (data) {
                        req.buffer += data;
                    }
                }

                // hyprland closes the peer after replying; quickshell reports that as
                // PeerClosedError and streamFinished does not always follow, so the
                // disconnect itself completes the request with whatever was collected
                onConnectionStateChanged: {
                    if (sock.connected) {
                        sock.write(req.request);
                        sock.flush();
                    } else if (req.started) {
                        req.finish(req.buffer);
                    }
                }
            }
        }
    }

    function send(payload, callback) {
        const startedAt = Date.now();
        const req = requestComponent.createObject(root, {
            request: payload,
            callback: function (text) {
                if (Config.frameLog)
                    console.warn("[synopsis] " + Date.now() + " request " + payload.substring(0, 40) + " took " + (Date.now() - startedAt) + " ms");
                if (callback)
                    callback(text);
            }
        });
        if (!req) {
            if (callback)
                callback("");
            return;
        }
        req.start();
    }

    function parseJson(text) {
        if (!text || text.length === 0)
            return null;
        try {
            return JSON.parse(text);
        } catch (e) {
            console.warn("[synopsis] bad json from request socket: " + e);
            return null;
        }
    }

    function refreshAll(done) {
        const got = {
            monitors: null,
            workspaces: null,
            clients: null
        };
        let called = false;
        let parseMs = 0;
        const requestedAt = Date.now();
        // what hyprland had told us by the time the requests went out. the reply
        // describes the world as of now, so anything that arrives while it is in
        // flight is newer than everything in it.
        const seqAt = root.eventSeq;

        function parse(t) {
            const t0 = Date.now();
            const out = root.parseJson(t) || [];
            parseMs += Date.now() - t0;
            return out;
        }

        function check() {
            if (got.monitors === null || got.workspaces === null || got.clients === null)
                return;
            if (called)
                return;
            called = true;
            const t0 = Date.now();
            root.lastRequestEmpty = got.monitors.length === 0;
            // before the snapshot write, so one rebuild sees both. an
            // undisturbed refresh is the authority on which workspace each
            // monitor shows; a disturbed one is already out of date and the
            // events that disturbed it have set the map themselves.
            if (root.eventSeq === seqAt) {
                const live = {};
                for (let i = 0; i < got.monitors.length; i++) {
                    const m = got.monitors[i];
                    const aw = (m && m.activeWorkspace) ? m.activeWorkspace : {};
                    if (m && m.name && aw.id !== undefined && aw.id !== 0)
                        live[m.name] = aw.id;
                }
                if (!root.sameActiveMap(live, root.activeByMonitor)) {
                    root.activeByMonitor = live;
                    root.liveVersion++;
                }
            }
            root.monitors = got.monitors;
            root.workspaces = got.workspaces;
            root.clients = got.clients;
            // last, and alone: this is the one write the models rebuild on
            root.snapshot = {
                monitors: got.monitors,
                workspaces: got.workspaces,
                clients: got.clients,
                version: root.dataVersion + 1
            };
            // focusHistoryID 0 is hyprland's own "last window", which is exactly
            // what its refocus-on-unmap path would pick: resync every refresh,
            // events keep it current in between
            const fromClients = root.focusedFromClients();
            if (fromClients !== "")
                root.focusedAddress = fromClients;
            const fm = root.focusedMonitor();
            if (root.eventSeq === seqAt && fm && fm.activeWorkspace && fm.activeWorkspace.id !== undefined)
                root.activeWorkspaceId = fm.activeWorkspace.id;
            root.dataVersion++;
            console.warn("[synopsis] refresh monitors=" + got.monitors.length + " workspaces=" + got.workspaces.length + " clients=" + got.clients.length);
            const applyMs = Date.now() - t0;
            root.refreshed();
            if (done)
                done();
            if (Config.frameLog)
                console.warn("[synopsis] " + Date.now() + " refresh took " + (Date.now() - requestedAt) + " ms (parse " + parseMs + " apply " + applyMs + " notify " + (Date.now() - t0 - applyMs) + ")");
        }

        root.send("j/monitors", function (t) {
            got.monitors = parse(t);
            check();
        });
        root.send("j/workspaces", function (t) {
            got.workspaces = parse(t);
            check();
        });
        root.send("j/clients", function (t) {
            got.clients = parse(t);
            check();
        });
    }

    // hyprland numbers the focus history from the focused window (0)
    function focusedFromClients() {
        const list = root.snapshot.clients;
        for (let i = 0; i < list.length; i++) {
            const c = list[i];
            if (c && c.focusHistoryID === 0)
                return root.normAddress(c.address);
        }
        return "";
    }

    // the client on the given workspace that was focused most recently, or ""
    function lastFocusedOn(workspaceId): string {
        const list = root.snapshot.clients;
        let best = null;
        let bestFh = 1e9;
        for (let i = 0; i < list.length; i++) {
            const c = list[i];
            if (!c || c.mapped === false)
                continue;
            const ws = c.workspace || {};
            if (ws.id !== workspaceId)
                continue;
            const fh = (typeof c.focusHistoryID === "number") ? c.focusHistoryID : 9999;
            if (fh < bestFh) {
                bestFh = fh;
                best = c;
            }
        }
        return best ? root.normAddress(best.address) : "";
    }

    // the monitor hyprland reports as focused, or the first one
    function focusedMonitor(): var {
        const list = root.snapshot.monitors;
        for (let i = 0; i < list.length; i++) {
            if (list[i] && list[i].focused === true)
                return list[i];
        }
        return list.length ? list[0] : null;
    }

    function focusedMonitorName(): string {
        const m = root.focusedMonitor();
        return (m && m.name) ? m.name : "";
    }

    // which monitor a workspace id sits on, from the last snapshot. "" for a
    // workspace hyprland has only just created, which no snapshot has yet.
    function monitorOfWorkspace(id: int): string {
        const list = root.snapshot.workspaces;
        for (let i = 0; i < list.length; i++) {
            const ws = list[i];
            if (ws && ws.id === id)
                return ws.monitor || "";
        }
        return "";
    }

    // ---- live active workspaces -----------------------------------------

    function sameActiveMap(a, b): bool {
        for (const ka in a) {
            if (b[ka] !== a[ka])
                return false;
        }
        for (const kb in b) {
            if (a[kb] !== b[kb])
                return false;
        }
        return true;
    }

    // the map is replaced, never patched: a binding on activeByMonitor has to
    // see the change, and an unchanged value must not bump liveVersion or every
    // refresh would rebuild every model for nothing
    function setActiveWorkspace(monitorName, id) {
        if (!monitorName || !id)
            return;
        const cur = root.activeByMonitor;
        if (cur[monitorName] === id)
            return;
        const next = {};
        for (const k in cur)
            next[k] = cur[k];
        next[monitorName] = id;
        root.activeByMonitor = next;
        root.liveVersion++;
    }

    // ---- stacking ------------------------------------------------------

    function clientIndex() {
        const index = {};
        const list = root.snapshot.clients;
        for (let i = 0; i < list.length; i++) {
            const c = list[i];
            if (!c)
                continue;
            index[root.normAddress(c.address)] = {
                order: i,
                fh: (typeof c.focusHistoryID === "number") ? c.focusHistoryID : 9999,
                floating: c.floating === true,
                pinned: c.pinned === true
            };
        }
        return index;
    }

    // addresses in, addresses out, bottom of the stack first.
    function stackOrder(addresses) {
        const index = root.clientIndex();
        const useOrder = root.useClientOrder;
        const out = addresses.slice();
        out.sort(function (a, b) {
            const ea = index[root.normAddress(a)] || {
                order: 0,
                fh: 9999,
                floating: false,
                pinned: false
            };
            const eb = index[root.normAddress(b)] || {
                order: 0,
                fh: 9999,
                floating: false,
                pinned: false
            };
            const la = ea.pinned ? 2 : (ea.floating ? 1 : 0);
            const lb = eb.pinned ? 2 : (eb.floating ? 1 : 0);
            if (la !== lb)
                return la - lb;
            if (useOrder)
                return ea.order - eb.order;
            return eb.fh - ea.fh;
        });
        return out;
    }

    // ---- dispatch ------------------------------------------------------

    function luaWorkspaceArg(id, name) {
        if (id < 0)
            return JSON.stringify((name && name.length) ? name : ("special:" + (-id)));
        return "" + id;
    }

    function classicWorkspaceArg(id, name) {
        if (id < 0)
            return (name && name.length) ? name : ("special:" + (-id));
        return "" + id;
    }

    function run(lua, classic) {
        if (Config.frameLog)
            console.warn("[synopsis] " + Date.now() + " dispatch " + (Hyprland.usingLua ? lua : classic));
        Hyprland.dispatch(Hyprland.usingLua ? lua : classic);
    }

    function focusWindow(address) {
        const sel = root.selector(address);
        root.run("hl.dsp.focus({ window = \"" + sel + "\" })", "focuswindow " + sel);
    }

    function focusWorkspace(id, name) {
        root.run("hl.dsp.focus({ workspace = " + root.luaWorkspaceArg(id, name) + " })", "workspace " + root.classicWorkspaceArg(id, name));
    }

    function raiseWindow(address) {
        const sel = root.selector(address);
        root.run("hl.dsp.window.alter_zorder({ mode = \"top\", window = \"" + sel + "\" })", "alterzorder top," + sel);
    }

    // follow = false is the silent move (LuaBindingsDispatchers.cpp: silent = follow.has_value() && !*follow)
    function moveToWorkspace(address, id, name) {
        const sel = root.selector(address);
        root.run("hl.dsp.window.move({ workspace = " + root.luaWorkspaceArg(id, name) + ", follow = false, window = \"" + sel + "\" })", "movetoworkspacesilent " + root.classicWorkspaceArg(id, name) + "," + sel);
    }

    // the animation tick warps every running animation to its goal while
    // animations:enabled is off (AnimationManager.cpp tick, read live), so a
    // workspace switch we trigger behind the backdrop can be made instant
    property bool animationsSuppressed: false

    function setAnimations(on) {
        if (on === !root.animationsSuppressed)
            return;
        root.animationsSuppressed = !on;
        if (Hyprland.usingLua)
            root.send("eval hl.config({ animations = { enabled = " + (on ? "true" : "false") + " } })", null);
        else
            root.send("keyword animations:enabled " + (on ? "1" : "0"), null);
    }

    // one request instead of two: every config eval is a separate round trip
    // (~50 ms measured) and finishClose wants both values at once
    function applyConfig(animationsOn, fps) {
        const n = Math.max(1, Math.min(120, Math.round(fps)));
        root.animationsSuppressed = !animationsOn;
        if (Hyprland.usingLua) {
            root.send("eval hl.config({ animations = { enabled = " + (animationsOn ? "true" : "false") + " }, misc = { render_unfocused_fps = " + n + " } })", null);
            return;
        }
        root.send("keyword animations:enabled " + (animationsOn ? "1" : "0"), null);
        root.send("keyword misc:render_unfocused_fps " + n, null);
    }

    // hidden windows only paint while render_unfocused_fps is high (tuning.md 2026-09-13)
    function setRenderFps(fps) {
        const n = Math.max(1, Math.min(120, Math.round(fps)));
        if (Hyprland.usingLua)
            root.send("eval hl.config({ misc = { render_unfocused_fps = " + n + " } })", null);
        else
            root.send("keyword misc:render_unfocused_fps " + n, null);
    }

    // ---- events --------------------------------------------------------

    // workspacev2 is "<id>,<name>": that workspace is now the active one of the
    // monitor it belongs to. a workspace hyprland has just created is in no
    // snapshot yet, and the only monitor that can have summoned it is the
    // focused one.
    function noteWorkspace(data) {
        const id = parseInt(("" + data).split(",")[0], 10);
        if (!id)
            return;
        root.eventSeq++;
        const focused = root.focusedMonitorName();
        let name = root.monitorOfWorkspace(id);
        if (name === "")
            name = focused;
        root.setActiveWorkspace(name, id);
        // activeWorkspaceId is the focused monitor's, and only its
        if (name === "" || name === focused)
            root.activeWorkspaceId = id;
    }

    // focusedmonv2 is "<monitor>,<workspace name>": the workspace the keyboard
    // now follows, which is the one focusSatisfied has to compare against
    function noteFocusedMonitor(data) {
        const parts = data.split(",");
        const name = parts.length > 1 ? parts.slice(1).join(",") : "";
        if (name === "")
            return;
        root.eventSeq++;
        const list = root.snapshot.workspaces;
        for (let i = 0; i < list.length; i++) {
            const ws = list[i];
            if (ws && ws.name === name && (parts[0] === "" || ws.monitor === parts[0])) {
                root.activeWorkspaceId = ws.id;
                root.setActiveWorkspace(parts[0] !== "" ? parts[0] : (ws.monitor || ""), ws.id);
                return;
            }
        }
    }

    // the client vector must not keep handing out a window that is gone: a
    // focus request retrying against it would never be confirmed
    function noteWindowClosed(address) {
        if (address === "")
            return;
        if (root.focusedAddress === address)
            root.focusedAddress = "";
        const snap = root.snapshot;
        const kept = [];
        let dropped = false;
        for (let i = 0; i < snap.clients.length; i++) {
            const c = snap.clients[i];
            if (c && root.normAddress(c.address) === address)
                dropped = true;
            else
                kept.push(c);
        }
        if (!dropped)
            return;
        root.clients = kept;
        root.snapshot = {
            monitors: snap.monitors,
            workspaces: snap.workspaces,
            clients: kept,
            version: snap.version + 1
        };
    }

    readonly property var dirtyEvents: ({
            "openwindow": 1,
            "closewindow": 1,
            "movewindowv2": 1,
            "createworkspacev2": 1,
            "destroyworkspacev2": 1,
            "focusedmonv2": 1,
            "monitoradded": 1,
            "monitorremoved": 1,
            "activespecial": 1,
            "fullscreen": 1,
            "changefloatingmode": 1,
            "workspacev2": 1
        })

    Connections {
        target: Hyprland

        function onRawEvent(event) {
            if (event.name === "activewindowv2")
                root.focusedAddress = root.normAddress(event.data);
            else if (event.name === "workspacev2")
                root.noteWorkspace("" + event.data);
            else if (event.name === "focusedmonv2")
                root.noteFocusedMonitor("" + event.data);
            else if (event.name === "closewindow")
                root.noteWindowClosed(root.normAddress(event.data));
            if (root.dirtyEvents[event.name] !== undefined)
                root.modelsDirty();
        }
    }
}
