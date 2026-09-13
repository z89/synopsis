pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME") || ""

    property int hiddenFps: 60
    property int restFps: 1
    property real stripHeightFraction: 0.14
    property int stripGap: 24
    property int exposeSpacing: 24
    property real exposeMaxScale: 0.95
    property int flightMs: 260
    property string flightEasing: "OutCubic"
    property int switchMs: 450
    property string switchEasing: "InOutCubic"
    property int settleMs: 60
    property bool slideReverse: false
    property real scrimOpacity: 0.55
    property int idleCaptureHz: 12
    property bool showSpecialWorkspaces: false
    property bool followDms: true
    property bool frameLog: Quickshell.env("SYNOPSIS_FRAMELOG") === "1"
    // the open gate: how long the flight waits for thumbs to report content
    property int gateTimeoutMs: 250
    // how long a thumb shows its placeholder before it gives up on content
    property int hasContentTimeoutMs: 400
    property int focusRetryMs: 60
    property int focusRetries: 6
    // retries left once the overlay has unmapped: the chain must not outlive the
    // user's next move by much (focusRetriesClosed x focusRetryMs, ~120 ms)
    property int focusRetriesClosed: 2
    property real marginFraction: 0.04
    property real maxContentAspect: 2.0
    property int windowRounding: 16
    property int focusHandoffMs: 16
    property int stripTopMargin: 48
    property real dragOpacity: 0.6
    // track 1: slide spam awareness
    // floor for a slide shortened because switches arrive faster than switchMs
    property int switchMinMs: 140
    // a spammed slide lasts this much of the gap between the two switches
    property real switchSpamFactor: 1.2
    // track B: open/close responsiveness
    // how long the first window focus dispatch waits for the layer's
    // exclusive -> ondemand commit to reach hyprland (about two frames)
    property int focusCommitMs: 20
    // open/close/toggle/confirm arriving within this of the last accepted one
    // are dropped (inclusive: a held key repeats at exactly 1000/repeat_rate).
    // must exceed 1000/repeat_rate (40 ms at hyprland's default 25) and stay
    // under a deliberate double press (~100 ms)
    property int inputCoalesceMs: 50
    // how long a cancelled prepare waits before restoring render_unfocused_fps,
    // so a re-toggle does not queue behind that config eval
    property int restFpsDeferMs: 40

    // track C: slide polish
    // the clearance kept between the leaving and the arriving set during a
    // workspace slide. the two sets travel their own bounding width plus this,
    // never the whole screen, so on an ultrawide the midpoint still shows
    // windows instead of an empty backdrop
    property int slideGap: 96

    readonly property var _easingMap: ({
        "OutCubic": Easing.OutCubic,
        "OutQuart": Easing.OutQuart,
        "OutQuint": Easing.OutQuint,
        "InOutCubic": Easing.InOutCubic,
        "InOutQuart": Easing.InOutQuart,
        "InOutQuint": Easing.InOutQuint,
        "InOutSine": Easing.InOutSine,
        "OutExpo": Easing.OutExpo,
        "Linear": Easing.Linear
    })

    readonly property int easingCurve: _easingMap[flightEasing] !== undefined ? _easingMap[flightEasing] : Easing.OutCubic
    readonly property int switchCurve: _easingMap[switchEasing] !== undefined ? _easingMap[switchEasing] : Easing.OutQuint

    FileView {
        id: configFile
        path: root.home + "/.config/synopsis/config.json"
        watchChanges: true
        blockLoading: false

        function _apply(data) {
            if (data.hiddenFps !== undefined) root.hiddenFps = data.hiddenFps;
            if (data.restFps !== undefined) root.restFps = data.restFps;
            if (data.stripHeightFraction !== undefined) root.stripHeightFraction = data.stripHeightFraction;
            if (data.stripGap !== undefined) root.stripGap = data.stripGap;
            if (data.exposeSpacing !== undefined) root.exposeSpacing = data.exposeSpacing;
            if (data.exposeMaxScale !== undefined) root.exposeMaxScale = data.exposeMaxScale;
            if (data.flightMs !== undefined) root.flightMs = data.flightMs;
            if (data.flightEasing !== undefined) root.flightEasing = data.flightEasing;
            if (data.switchMs !== undefined) root.switchMs = data.switchMs;
            if (data.switchEasing !== undefined) root.switchEasing = data.switchEasing;
            if (data.settleMs !== undefined) root.settleMs = data.settleMs;
            if (data.slideReverse !== undefined) root.slideReverse = data.slideReverse;
            if (data.scrimOpacity !== undefined) root.scrimOpacity = data.scrimOpacity;
            if (data.idleCaptureHz !== undefined) root.idleCaptureHz = data.idleCaptureHz;
            if (data.showSpecialWorkspaces !== undefined) root.showSpecialWorkspaces = data.showSpecialWorkspaces;
            if (data.followDms !== undefined) root.followDms = data.followDms;
            if (Quickshell.env("SYNOPSIS_FRAMELOG") === "1") {
                root.frameLog = true;
            } else if (data.frameLog !== undefined) {
                root.frameLog = data.frameLog;
            }
            if (data.gateTimeoutMs !== undefined) root.gateTimeoutMs = data.gateTimeoutMs;
            if (data.hasContentTimeoutMs !== undefined) root.hasContentTimeoutMs = data.hasContentTimeoutMs;
            if (data.focusRetryMs !== undefined) root.focusRetryMs = data.focusRetryMs;
            if (data.focusRetries !== undefined) root.focusRetries = data.focusRetries;
            if (data.focusRetriesClosed !== undefined) root.focusRetriesClosed = data.focusRetriesClosed;
            if (data.marginFraction !== undefined) root.marginFraction = data.marginFraction;
            if (data.maxContentAspect !== undefined) root.maxContentAspect = data.maxContentAspect;
            if (data.windowRounding !== undefined) root.windowRounding = data.windowRounding;
            if (data.focusHandoffMs !== undefined) root.focusHandoffMs = data.focusHandoffMs;
            if (data.stripTopMargin !== undefined) root.stripTopMargin = data.stripTopMargin;
            if (data.dragOpacity !== undefined) root.dragOpacity = data.dragOpacity;
            // track 1: slide spam awareness
            if (data.switchMinMs !== undefined) root.switchMinMs = data.switchMinMs;
            if (data.switchSpamFactor !== undefined) root.switchSpamFactor = data.switchSpamFactor;
            // track B: open/close responsiveness
            if (data.focusCommitMs !== undefined) root.focusCommitMs = data.focusCommitMs;
            if (data.inputCoalesceMs !== undefined) root.inputCoalesceMs = data.inputCoalesceMs;
            if (data.restFpsDeferMs !== undefined) root.restFpsDeferMs = data.restFpsDeferMs;
            // track C: slide polish
            if (data.slideGap !== undefined) root.slideGap = data.slideGap;
        }

        function _parse() {
            try {
                var text = configFile.text();
                if (!text)
                    return;
                var data = JSON.parse(text);
                configFile._apply(data);
            } catch (e) {
                console.warn("Config: failed to parse config.json:", e);
            }
        }

        onLoaded: configFile._parse()
        // reload() is async; onLoaded does the parse once the new text is in
        onFileChanged: configFile.reload()
    }
}
