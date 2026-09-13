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
    readonly property var mon: Overview.modelFor(win.monitorName, Overview.dataVersion)

    // ultrawide: cap the content to height * maxContentAspect and centre it
    readonly property real contentW: Config.maxContentAspect > 0 ? Math.min(win.width, win.height * Config.maxContentAspect) : win.width
    readonly property real contentX: Math.round((win.width - win.contentW) / 2)
    readonly property real margin: Math.round(Math.min(win.contentW, win.height) * Config.marginFraction)
    readonly property real stripY: Config.stripTopMargin
    readonly property real stripH: win.height * Config.stripHeightFraction
    readonly property real exposeY: win.stripY + win.stripH + win.margin

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

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "synopsis"
    WlrLayershell.keyboardFocus: Overview.wantsFocus ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    onVisibleChanged: {
        if (win.visible)
            content.forceActiveFocus();
    }

    Item {
        id: content
        anchors.fill: parent
        focus: true

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

        Scrim {
            anchors.fill: parent
        }

        Expose {
            id: expose
            anchors.fill: parent
            z: Overview.dragAddress !== "" ? 2 : 0
            mon: win.mon
            progress: Overview.progress
            areaX: win.contentX + win.margin
            areaY: win.exposeY
            areaW: win.contentW - win.margin * 2
            areaH: Math.max(0, win.height - win.exposeY - win.margin)
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

        Connections {
            target: content.qwin
            enabled: Overview.awaitingFirstFrame || Overview.awaitingFocusDrop

            function onFrameSwapped() {
                if (Overview.awaitingFirstFrame)
                    Overview.noteFirstFrame();
                if (Overview.awaitingFocusDrop)
                    Overview.noteFocusDropFrame();
            }
        }

        FrameLog {
            screenName: win.monitorName
            qwin: content.qwin
        }
    }
}
