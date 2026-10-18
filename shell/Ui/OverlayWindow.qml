// one overlay per screen. it is mapped for the whole of preparing..closing and
// hidden the rest of the time, so nothing of it renders while the overview is closed.

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Core
import qs.Debug

PanelWindow { // qmllint disable uncreatable-type
    id: win

    required property var modelData

    readonly property var hyprMonitor: Hyprland.monitorFor(win.modelData)
    readonly property string monitorName: win.hyprMonitor ? win.hyprMonitor.name : (win.modelData ? win.modelData.name : "")
    // the snapshot version, not Overview.dataVersion: one dependency, so a
    // refresh rebuilds this model exactly once. virtualWorkspacesVersion is a
    // second, independent dependency: the plus button changes it without
    // touching the snapshot at all
    readonly property var mon: Overview.modelFor(win.monitorName, HyprState.snapshot.version, Overview.virtualWorkspacesVersion)

    // ultrawide: cap the content to height * maxContentAspect and centre it
    readonly property real contentW: Config.maxContentAspect > 0 ? Math.min(win.width, win.height * Config.maxContentAspect) : win.width
    readonly property real contentX: Math.round((win.width - win.contentW) / 2)
    readonly property real margin: Math.round(Math.min(win.contentW, win.height) * Config.marginFraction)
    readonly property real stripY: Config.stripTopMargin
    readonly property real stripH: win.height * Config.stripHeightFraction
    readonly property real exposeY: win.stripY + win.stripH + win.margin
    // the tiles sample the clip only once it has a frame; until then they show the still
    readonly property WallpaperVideo wallPlayer: wallVideo.item as WallpaperVideo
    readonly property bool wallLive: win.wallPlayer !== null && win.wallPlayer.ready && !win.wallPlayer.failed
    // the tiles' clip renders at the proxy's own size, cropped to the
    // screen's aspect the way the full clip is cropped on the backdrop. the
    // fallback only covers the moment before the size is known
    readonly property size wallProxySize: Wallpaper.proxySize.width > 0 && Wallpaper.proxySize.height > 0 ? Wallpaper.proxySize : Qt.size(1280, 360)
    readonly property real wallAspect: win.width > 0 && win.height > 0 ? win.width / win.height : win.wallProxySize.width / win.wallProxySize.height
    readonly property size wallTexSize: Qt.size(Math.max(1, Math.round(Math.min(win.wallProxySize.width, win.wallProxySize.height * win.wallAspect))), Math.max(1, Math.round(Math.min(win.wallProxySize.height, win.wallProxySize.width / win.wallAspect))))

    screen: win.modelData
    color: "transparent"
    visible: Overview.active
    exclusionMode: ExclusionMode.Ignore

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    // a tile switch close (Overview.inputReleased): an empty input region, so
    // the pointer reaches the windows under the rest of the close. the layer
    // stays ondemand rather than none (see keyboardFocus): the switch dispatch
    // has already moved the keyboard to the arriving workspace
    readonly property Region passThrough: Region {}
    mask: Overview.inputReleased ? win.passThrough : null

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "synopsis"
    // never None while we are mapped: hyprland's layer commit handler reacts to
    // exclusive -> none by refocusing the last window, which drags the monitor
    // back to that window's workspace (tuning.md 2026-09-13, focus handoff).
    // exclusive -> ondemand only drops us out of m_exclusiveLSes, so a window
    // focus dispatched afterwards is accepted instead of refused.
    // the one exception is before the first exclusive: the layer maps as None
    // and stays None until the opaque backdrop has a frame on screen, because
    // mapping with any other interactivity grabs the keyboard and deactivates
    // the window still visible around the preparing thumbs (tuning.md, the
    // keyboard waits for the backdrop). none -> exclusive grabs; none ->
    // ondemand (a close before that) refocuses nothing.
    WlrLayershell.keyboardFocus: Overview.keyboardExclusive ? WlrKeyboardFocus.Exclusive : (Overview.keyboardTaken ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None)

    onVisibleChanged: {
        if (win.visible)
            content.forceActiveFocus();
    }

    Item {
        id: content
        anchors.fill: parent
        focus: true
        // escape and enter belong to the desktop once a tile switch close runs
        Keys.enabled: !Overview.inputReleased

        readonly property var qwin: Window.window

        // keepalive speck: one pixel, opacity just above zero so the item is still
        // rendered but invisible. not tunable from config on purpose.
        readonly property int keepaliveSize: 1
        readonly property real keepaliveOpacity: 0.004
        readonly property int keepaliveTurnMs: Theme.longDuration * 4

        Keys.onEscapePressed: function (event) {
            Overview.close();
            event.accepted = true;
        }

        Keys.onReturnPressed: function (event) {
            Overview.confirm();
            event.accepted = true;
        }

        Keys.onEnterPressed: function (event) {
            Overview.confirm();
            event.accepted = true;
        }

        // a video wallpaper's clip for the strip tiles. textures cannot cross
        // windows, so the overlay runs its own player. it plays the small
        // proxy (Wallpaper.proxyUrl), not the full clip, so it costs a sliver
        // of the decoder eco needs, and its seek is a few small frames, so it
        // starts from preparing and the tiles are live for the whole flight.
        // the clip renders once per frame into one proxy-size offscreen
        // texture and every tile draws that texture as one quad. a
        // ShaderEffect that samples it updates the layer itself, so the
        // source stays invisible
        Loader {
            id: wallVideo
            width: win.wallTexSize.width
            height: win.wallTexSize.height
            z: -1
            active: Wallpaper.live && Overview.active && Wallpaper.proxyUrl !== ""
            sourceComponent: WallpaperVideo {
                source: Wallpaper.proxyUrl
                monitorName: win.monitorName
            }
        }

        ShaderEffectSource {
            id: wallTex
            visible: false
            live: true
            hideSource: true
            smooth: true
            sourceItem: win.wallPlayer
            textureSize: win.wallTexSize
        }

        Scrim {
            anchors.fill: parent
        }

        Expose {
            id: expose
            anchors.fill: parent
            // above the strip while a thumb is dragged, handing off an accepted
            // drop or flying back from a rejected one (Overview.dragLayerHold),
            // and while a tile switch close slides the arriving windows in at
            // full size over the fading strip (Expose.flatClose)
            z: (Overview.dragAddress !== "" || Overview.dragLayerHold > 0 || expose.flatClose) ? 2 : 0
            mon: win.mon
            progress: Overview.progress
            areaX: win.contentX + win.margin
            areaY: win.exposeY
            areaW: win.contentW - win.margin * 2
            areaH: Math.max(0, win.height - win.exposeY - win.margin)
            screenW: win.width
            margin: win.margin
        }

        WorkspaceStrip {
            id: strip
            width: parent.width
            height: parent.height
            z: 1
            mon: win.mon
            progress: Overview.progress
            areaX: win.contentX + win.margin
            areaY: win.stripY
            areaW: win.contentW - win.margin * 2
            areaH: win.stripH
            wallpaperTex: win.wallLive ? wallTex : null
        }

        // idle tiles are refreshed by hand; only the active tile and the exposé are live
        Timer {
            interval: Math.max(1, Math.round(1000 / Math.max(1, Config.idleCaptureHz)))
            repeat: true
            running: Overview.active
            onTriggered: strip.captureIdle()
        }

        // a capture only advances when the output commits, so something must always
        // be moving while we are open (tuning.md 2026-09-13, capture cadence)
        Rectangle {
            id: keepalive
            width: content.keepaliveSize
            height: content.keepaliveSize
            color: Theme.primary
            opacity: content.keepaliveOpacity

            NumberAnimation on rotation {
                from: 0
                to: 360
                duration: content.keepaliveTurnMs
                loops: Animation.Infinite
                running: Overview.active
            }
        }

        // the window's own frame swaps: the first one is the open latency and the
        // prepare breakdown's firstFrame, and the next one after the layer drops
        // to OnDemand is the earliest point a window focus can be accepted
        // (tuning.md 2026-09-14, the focus dispatch waits for the ondemand commit)
        Connections {
            target: content.qwin
            enabled: Overview.awaitingFirstFrame || Overview.awaitingFocusCommit

            function onFrameSwapped() {
                if (Overview.awaitingFirstFrame)
                    Overview.noteFirstFrame();
                if (Overview.awaitingFocusCommit)
                    Overview.noteFocusCommitFrame();
            }
        }

        // every pointer position over the overlay, for the hover seed: a thumb
        // mouse area only reports its own enter and exit, so movement elsewhere
        // (or before the areas are enabled) would never release it
        HoverHandler {
            id: overlayHover
            onPointChanged: {
                if (overlayHover.hovered)
                    Overview.notePointer(content.qwin, overlayHover.point.scenePosition.x, overlayHover.point.scenePosition.y);
            }
        }

        FrameLog {
            screenName: win.monitorName
            qwin: content.qwin
        }
    }
}
