pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// the wallpaper as the overview draws it. a video wallpaper (eco) shows its
// poster as the still, frame 0 of the clip, and the tiles play a small proxy
// of the clip only while the overview is open. images pass through unchanged
Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME") || ""
    readonly property var videoExtensions: ["mp4", "mkv", "webm", "mov", "m4v"]

    readonly property string path: root.plain(Theme.wallpaperPath)
    readonly property bool isVideo: root.videoPath(root.path)
    // eco writes one poster per clip, named after the clip with its extension
    readonly property string posterDir: (Quickshell.env("XDG_CACHE_HOME") || (root.home + "/.cache")) + "/eco/posters"
    readonly property string stillPath: root.isVideo ? root.posterDir + "/" + root.path.substring(root.path.lastIndexOf("/") + 1) + ".jpg" : root.path
    readonly property string stillUrl: root.fileUrl(root.stillPath)
    readonly property string videoUrl: root.isVideo ? root.fileUrl(root.path) : ""
    // live video wanted: a video path and the config switch
    readonly property bool live: root.isVideo && Config.liveWallpaper

    // the tiles' small clip, from Scripts/wallpaper-proxy.sh. empty until
    // the script has run for the current path, so the tiles keep the still
    // meanwhile
    property string proxyUrl: ""
    property size proxySize: Qt.size(0, 0)
    // the clip the proxy was made from, so a stale proxy is never used
    property string proxyFor: ""

    // the path the running script was started for, and whether the path
    // moved on while it ran (it is never killed, so it finishes its cache
    // and the next run starts after it)
    property string _proxyRunFor: ""
    property bool _proxyPending: false
    property int _proxyExit: -1
    property bool _proxyOutDone: false
    property string _proxyWarnedFor: ""

    onPathChanged: root._proxyRefresh()
    onLiveChanged: root._proxyRefresh()
    Component.onCompleted: root._proxyRefresh()

    function _proxyClear() {
        root.proxyUrl = "";
        root.proxySize = Qt.size(0, 0);
        root.proxyFor = "";
    }

    function _proxyRefresh() {
        if (root.proxyFor !== root.path)
            root._proxyClear();
        if (!root.live || root.proxyFor === root.path)
            return;
        if (proxyProc.running) {
            root._proxyPending = root._proxyRunFor !== root.path;
            return;
        }
        root._proxyPending = false;
        root._proxyRunFor = root.path;
        root._proxyExit = -1;
        root._proxyOutDone = false;
        proxyProc.command = ["bash", root.plain(String(Qt.resolvedUrl("../Scripts/wallpaper-proxy.sh"))), root.path];
        proxyProc.running = true;
    }

    function _proxyWarn(why: string) {
        if (root._proxyWarnedFor === root._proxyRunFor)
            return;
        root._proxyWarnedFor = root._proxyRunFor;
        console.warn("[synopsis] wallpaper proxy failed for " + root._proxyRunFor + ": " + why);
    }

    // both the exit and the end of stdout, in whichever order they come
    function _proxyMaybeDone() {
        if (root._proxyExit < 0 || !root._proxyOutDone)
            return;
        const ranFor = root._proxyRunFor;
        const out = proxyOut.text.trim();
        if (root._proxyExit !== 0 || out === "") {
            if (ranFor === root.path)
                root._proxyWarn("exit " + root._proxyExit);
        } else if (ranFor === root.path && root.live) {
            // the same clip again finds the same json, which needs a reload
            if (proxyJson.path === out)
                proxyJson.reload();
            else
                proxyJson.path = out;
        }
        if (root._proxyPending)
            Qt.callLater(root._proxyRefresh);
    }

    function _proxyApply() {
        if (root._proxyRunFor !== root.path)
            return;
        let j = null;
        try {
            j = JSON.parse(proxyJson.text());
        } catch (e) {
            j = null;
        }
        // an older cache file may carry more fields, which are ignored
        if (!j || typeof j.proxy !== "string" || j.proxy === "" || !(Number(j.width) > 0) || !(Number(j.height) > 0)) {
            root._proxyWarn("unreadable " + proxyJson.path);
            return;
        }
        root.proxyUrl = root.fileUrl(j.proxy);
        root.proxySize = Qt.size(Number(j.width), Number(j.height));
        root.proxyFor = root._proxyRunFor;
    }

    // one short run per wallpaper. after the first it finds its cache and
    // exits at once, and it never runs on the overview's open path
    Process {
        id: proxyProc

        stdout: StdioCollector {
            id: proxyOut
            onStreamFinished: {
                root._proxyOutDone = true;
                root._proxyMaybeDone();
            }
        }

        onExited: function (exitCode, exitStatus) {
            root._proxyExit = exitStatus === 0 ? exitCode : 255;
            root._proxyMaybeDone();
        }
    }

    // off the open path, so a non-blocking load is fine
    FileView {
        id: proxyJson
        blockLoading: false
        watchChanges: false
        printErrors: false
        onLoaded: root._proxyApply()
        onLoadFailed: root._proxyWarn("unreadable " + proxyJson.path)
    }

    // a plain path for either a plain path or a file:// URL
    function plain(p: string): string {
        let s = p || "";
        if (s.startsWith("file://"))
            s = decodeURIComponent(s.substring(7));
        return s;
    }

    // false for "", colours ("#...") and anything without a video extension
    function videoPath(p: string): bool {
        if (!p || p.startsWith("#"))
            return false;
        const dot = p.lastIndexOf(".");
        if (dot < 0 || dot < p.lastIndexOf("/"))
            return false;
        return root.videoExtensions.indexOf(p.substring(dot + 1).toLowerCase()) >= 0;
    }

    // the file eco rewrites with its player's position for one screen
    function playheadPath(monitorName: string): string {
        return root.runtimeDir() + "/eco-playhead-" + monitorName + ".json";
    }

    // the cover request for one screen: asks eco to lift its wallpaper
    // window over the desktop (BackdropWindow)
    function coverRequestPath(monitorName: string): string {
        return root.runtimeDir() + "/eco-cover-" + monitorName + ".json";
    }

    // eco's answer to the cover request, and by its presence the sign that
    // eco can cover at all
    function coverStatePath(monitorName: string): string {
        return root.runtimeDir() + "/eco-cover-state-" + monitorName + ".json";
    }

    function runtimeDir(): string {
        return Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000";
    }

    // each path segment encoded, so spaces and # in a name still load
    function fileUrl(p: string): string {
        if (!p || p.startsWith("#"))
            return "";
        return "file://" + p.split("/").map(s => encodeURIComponent(s)).join("/");
    }
}
