import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Core

// the opaque wallpaper that hides the real windows while the overview is up
// (the still), or nothing at all while eco covers them with its own window.
// it lives on the top layer, sorted beneath the dms bar by the synopsis-backdrop
// layer rule, so the bar and notifications stay visible between it and the scrim
PanelWindow { // qmllint disable uncreatable-type
    id: win

    required property var modelData

    // the same name OverlayWindow resolves, so the focused monitor's backdrop
    // can be told apart (Overview.noteBackdropFrame)
    readonly property var hyprMonitor: Hyprland.monitorFor(win.modelData)
    readonly property string monitorName: win.hyprMonitor ? win.hyprMonitor.name : (win.modelData ? win.modelData.name : "")

    // eco lifts its own wallpaper window over the desktop on request (the
    // cover files, Wallpaper.coverRequestPath), which hides the real windows
    // with the clip it is already playing. its ack stands in for the still's
    // first frame, and the still only shows when the ack misses this screen's
    // own timer (coverMiss), its first painted frame then standing in for the
    // ack. without a live eco behind a state file this window is the plain
    // opaque backdrop it always was

    // eco's state file loaded the last time it was read, and the process it
    // names is still running
    property bool capable: false
    // the pid from the last state file read, 0 when it had none
    property int _statePid: 0
    // the at of the last request written, which eco's ack echoes as seq
    property real coverSeq: 0
    // a cover asked for and not yet given back. Overview holds the close
    // while any backdrop has one (coverHolds)
    property bool coverRequested: false
    // this open asked for the cover, the ack arrived, and the latched
    // fallback to the still when it came too late
    property bool coverThisOpen: false
    property bool coverAcked: false
    property bool coverFellBack: false
    readonly property bool coverHidesStill: win.coverThisOpen && !win.coverFellBack
    property real coverOpenAt: 0
    // cover false went out and its ack is awaited
    property bool _coverReleasing: false
    property bool _coverCleared: false
    // the last ack handled, as a pair: a safety drop reuses the seq of the
    // request it already acked as top
    property real _coverAckedSeq: 0
    property bool _coverAckedTop: false
    // the state before the current one, for the preparing to opening edge
    property string _lastState: "closed"

    onCoverRequestedChanged: Overview.coverHolds += win.coverRequested ? 1 : -1

    Component.onCompleted: win._lastState = Overview.state

    Component.onDestruction: {
        coverMiss.stop();
        if (win.coverRequested) {
            Overview.coverHolds -= 1;
            Overview.noteCoverDropped();
        }
    }

    function coverLog(text: string) {
        if (Config.frameLog)
            console.warn("[synopsis] " + Date.now() + " cover " + win.monitorName + " " + text);
    }

    function writeCover(cover: bool) {
        // strictly increasing, so two requests in one ms keep their own acks
        const at = Math.max(Date.now(), win.coverSeq + 1);
        win.coverSeq = at;
        coverRequest.setText(JSON.stringify({
            cover: cover,
            at: at,
            pid: Quickshell.processId
        }));
        win.coverLog("request " + cover + " seq " + at);
    }

    function requestCover() {
        coverRelease.stop();
        win._coverReleasing = false;
        win.coverThisOpen = true;
        win.coverAcked = false;
        win.coverFellBack = false;
        win.coverOpenAt = Date.now();
        win.writeCover(true);
        win.coverRequested = true;
        coverMiss.restart();
    }

    function releaseCover() {
        win._coverReleasing = true;
        win.writeCover(false);
        coverRelease.restart();
    }

    function coverDropped() {
        coverMiss.stop();
        coverRelease.stop();
        win._coverReleasing = false;
        // coverHolds drops on this change, before Overview counts them
        win.coverRequested = false;
        Overview.noteCoverDropped();
    }

    function fallBackToStill() {
        coverMiss.stop();
        if (win.coverFellBack)
            return;
        win.coverFellBack = true;
        win.coverLog("fallback still after " + Math.round(Date.now() - win.coverOpenAt) + " ms");
    }

    // capable only while the pid in the state file runs, so a state file
    // left by a wallpaper that is gone costs nothing
    function checkCoverPid(pid: int) {
        win._statePid = pid;
        if (pid <= 0) {
            win.capable = false;
            coverProc.path = "";
            return;
        }
        const p = "/proc/" + pid + "/comm";
        if (coverProc.path === p)
            coverProc.reload();
        else
            coverProc.path = p;
    }

    function readCoverState() {
        // a request left by a crash would keep the desktop covered
        if (!win._coverCleared) {
            win._coverCleared = true;
            if (!win.coverRequested)
                win.writeCover(false);
        }
        let j = null;
        try {
            j = JSON.parse(coverState.text());
        } catch (e) {
            j = null;
        }
        if (!j || typeof j !== "object") {
            win.checkCoverPid(0);
            return;
        }
        const pid = Number(j.pid);
        win.checkCoverPid(Number.isInteger(pid) && pid > 0 ? pid : 0);
        const seq = Number(j.seq);
        const top = j.top === true;
        if (seq === 0) {
            // eco restarted, so whatever it covered is down. nothing to do
            // unless a cover is held. not deduped: it only acts while one is
            if (top || !win.coverRequested)
                return;
            win.coverLog("ack top false seq 0 after " + Math.round(Date.now() - win.coverSeq) + " ms");
            if (!win._coverReleasing && win.coverThisOpen)
                win.fallBackToStill();
            // the new eco reads the request still on disk, which asks for
            // top, and nothing here would give that cover back
            if (!win._coverReleasing)
                win.writeCover(false);
            win.coverDropped();
            return;
        }
        if (!(seq > 0) || seq !== win.coverSeq || (seq === win._coverAckedSeq && top === win._coverAckedTop))
            return;
        win._coverAckedSeq = seq;
        win._coverAckedTop = top;
        win.coverLog("ack top " + top + " seq " + seq + " after " + Math.round(Date.now() - seq) + " ms");
        if (!win.coverRequested)
            return;
        if (win._coverReleasing) {
            if (!top)
                win.coverDropped();
        } else if (top) {
            coverMiss.stop();
            win.coverAcked = true;
            Overview.noteBackdropFrame(false, win.monitorName);
        } else {
            // eco dropped the cover on its own (its safety limits), so the
            // still takes over and there is nothing left to give back
            win.fallBackToStill();
            win.coverDropped();
        }
    }

    Connections {
        target: Overview

        function onStateChanged() {
            const from = win._lastState;
            const to = Overview.state;
            win._lastState = to;
            if (to === "preparing") {
                coverMiss.stop();
                win.coverThisOpen = false;
                win.coverAcked = false;
                win.coverFellBack = false;
                // a wallpaper started or gone since the last open is seen now
                coverState.reload();
                if (coverProc.path !== "")
                    coverProc.reload();
            } else if (to === "opening" && from === "preparing") {
                if (Config.coverViaWallpaper && win.capable && win.monitorName !== "")
                    win.requestCover();
            } else if (to === "closed") {
                coverMiss.stop();
                win.coverThisOpen = false;
                if (win.coverRequested && !win._coverReleasing)
                    win.releaseCover();
            }
        }

        function onCoverRelease() {
            if (win.coverRequested && !win._coverReleasing)
                win.releaseCover();
        }
    }

    // this screen's wait for eco's top ack. a miss shows the still, and its
    // first painted frame (onFrameSwapped below) lets the flight go, inside
    // Overview's own 100ms fallback
    Timer {
        id: coverMiss
        interval: 70
        repeat: false
        onTriggered: {
            if (win.coverThisOpen && !win.coverAcked)
                win.fallBackToStill();
        }
    }

    // the cap on the wait for eco's drop ack, inside Overview's own cap
    Timer {
        id: coverRelease
        interval: 80
        repeat: false
        onTriggered: {
            if (win.coverRequested && win._coverReleasing)
                win.coverDropped();
        }
    }

    FileView {
        id: coverRequest
        path: win.monitorName === "" ? "" : Wallpaper.coverRequestPath(win.monitorName)
        preload: false
        blockLoading: false
        atomicWrites: true
        printErrors: false
    }

    FileView {
        id: coverState
        path: win.monitorName === "" ? "" : Wallpaper.coverStatePath(win.monitorName)
        blockLoading: false
        watchChanges: true
        printErrors: false
        onFileChanged: coverState.reload()
        onLoaded: win.readCoverState()
        onLoadFailed: win.checkCoverPid(0)
    }

    // the wallpaper process named by the state file, read only to see that
    // it exists
    FileView {
        id: coverProc
        blockLoading: false
        watchChanges: false
        printErrors: false
        onLoaded: win.capable = win._statePid > 0
        onLoadFailed: win.capable = false
    }

    visible: Overview.active
    exclusionMode: ExclusionMode.Ignore
    screen: win.modelData
    color: "transparent"

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "synopsis-backdrop"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // the first frame swapped with the still shown is what lets the overlay
    // take the keyboard (Overview.backdropShown), unless eco's cover ack did it
    // first. a still that failed to load counts too,
    // since the plain cover beneath it is opaque. the swap commits this surface
    // before the overlay's interactivity change goes out on the same connection,
    // so hyprland has the backdrop before any window loses focus
    Connections {
        target: wallpaper.qwin
        enabled: Overview.awaitingBackdropFrame

        function onFrameSwapped() {
            if (wallpaper.visible && (wallpaper.status === Image.Ready || wallpaper.status === Image.Error || String(wallpaper.source) === ""))
                Overview.noteBackdropFrame(false, win.monitorName);
        }
    }

    // covers the real windows whatever happens to the still (a missing
    // poster, an unreadable file, an empty path)
    Rectangle {
        anchors.fill: parent
        color: Theme.background
        visible: wallpaper.visible
    }

    Image {
        id: wallpaper

        readonly property var qwin: Window.window

        anchors.fill: parent
        source: Wallpaper.stillUrl
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        // transparent only while preparing, when the thumbs sit exactly over the
        // real windows. opaque for every other state, including the whole of
        // closing: a tile click reaches progress 0 while the exposé slide is
        // still running, and the real windows must not show under moving thumbs.
        // hidden too while eco's wallpaper covers them (coverHidesStill)
        visible: Overview.active && Overview.state !== "preparing" && !win.coverHidesStill
    }
}
