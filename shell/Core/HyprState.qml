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
    property int dataVersion: 0
    property bool lastRequestEmpty: false

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
        const req = requestComponent.createObject(root, {
            request: payload,
            callback: callback || null
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

        function check() {
            if (got.monitors === null || got.workspaces === null || got.clients === null)
                return;
            if (called)
                return;
            called = true;
            root.lastRequestEmpty = got.monitors.length === 0;
            root.monitors = got.monitors;
            root.workspaces = got.workspaces;
            root.clients = got.clients;
            root.dataVersion++;
            console.warn("[synopsis] refresh monitors=" + got.monitors.length + " workspaces=" + got.workspaces.length + " clients=" + got.clients.length);
            root.refreshed();
            if (done)
                done();
        }

        root.send("j/monitors", function (t) {
            got.monitors = root.parseJson(t) || [];
            check();
        });
        root.send("j/workspaces", function (t) {
            got.workspaces = root.parseJson(t) || [];
            check();
        });
        root.send("j/clients", function (t) {
            got.clients = root.parseJson(t) || [];
            check();
        });
    }

    // ---- stacking ------------------------------------------------------

    function clientIndex() {
        const index = {};
        const list = root.clients;
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

    // hidden windows only paint while render_unfocused_fps is high (tuning.md 2026-09-13)
    function setRenderFps(fps) {
        const n = Math.max(1, Math.min(120, Math.round(fps)));
        if (Hyprland.usingLua)
            root.send("eval hl.config({ misc = { render_unfocused_fps = " + n + " } })", null);
        else
            root.send("keyword misc:render_unfocused_fps " + n, null);
    }

    // ---- events --------------------------------------------------------

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
            if (root.dirtyEvents[event.name] !== undefined)
                root.modelsDirty();
        }
    }
}
