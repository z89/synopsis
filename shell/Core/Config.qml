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

    // tile click switch: the close flight and the workspace slide it starts
    // share this duration and the flight's easing, so the arriving set lands on
    // the real windows as the flight does. toggle/escape closes keep flightMs
    property int tileSwitchMs: 420

    // hyprland's workspace slide (docs/tuning.md, hyprland's workspace curve).
    // while this is on and the leaf is enabled, every exposé slide (keybind and
    // tile click) and the tile switch close flight run on the curve and length
    // of hyprland's workspacesIn leaf, so they end the way Super + Right does.
    // off, or with the leaf disabled, switchMs/switchEasing and tileSwitchMs apply
    property bool followHyprWorkspaceCurve: true
    // config.json "hyprWorkspaceCurve": {"type": "spring", "mass": 1,
    // "stiffness": 110, "dampening": 20} or {"type": "bezier", "points":
    // [x1, y1, x2, y2], "speed": 3.5}. set, it wins over what hyprland reports
    property var hyprWorkspaceCurveOverride: null
    // what HyprState read from hyprland; null until then, or when the read failed
    property var hyprWorkspaceCurveLive: null
    property bool hyprWorkspaceCurveLiveDone: false
    // the user's hyprland.lua as of 2026-09-15: workspacesIn and workspacesOut
    // are spring "gentle", mass 1, stiffness 110, dampening 20 (speed ignored)
    readonly property var hyprWorkspaceCurveDefault: ({
            type: "spring",
            name: "gentle",
            mass: 1,
            stiffness: 110,
            dampening: 20
        })
    // derived by _resolveWorkspaceCurve: the length in ms (a spring's settle
    // time, a bezier's speed * 100) and the progress table (curveAt)
    property int hyprWorkspaceMs: 911
    property var hyprWorkspaceLut: []
    // the spring behind hyprWorkspaceLut as {m, k, c}, null for a bezier. an
    // interrupted slide continues on it from each row's own offset and
    // velocity (Expose continueSlide), the way hyprland keeps a spring's
    // velocity when a switch lands on a running one
    property var hyprWorkspaceSpring: null
    property bool hyprWorkspaceEnabled: true
    property string hyprWorkspaceDesc: ""
    property string _wsCurveLogged: ""
    readonly property bool workspaceCurveActive: root.followHyprWorkspaceCurve && root.hyprWorkspaceEnabled && root.hyprWorkspaceLut.length > 1
    // the full slide length the exposé uses: a keybind slide before spam pacing
    // and travel scaling, and a tile switch (slide and close flight)
    readonly property int slideMs: root.workspaceCurveActive ? root.hyprWorkspaceMs : root.switchMs
    readonly property int tileSlideMs: root.workspaceCurveActive ? root.hyprWorkspaceMs : root.tileSwitchMs

    // window drag and drop onto the strip (docs/tuning.md, drag and drop).
    // a dragged thumb shrinks from its exposé size to exactly its size on the
    // nearest tile over the pointer's distance to the tiles at drag start;
    // this floors that distance, in tile heights
    property real dragShrinkDistance: 1
    // a drop counts only inside the tile inset by this fraction of the tile's
    // smaller side, never less than dropEdgeBufferMin px
    property real dropEdgeBuffer: 0.08
    property int dropEdgeBufferMin: 6
    // a floating window placed so that less than this fraction of its area
    // (or dropMinVisiblePx squared, whichever is larger) stays on the monitor
    // is a rejected drop
    property real dropMinVisible: 0.25
    property int dropMinVisiblePx: 48
    // the release animation of a rejected drop: the approach shrink reversed
    // while the thumb flies back to its exposé slot
    property int dragReturnMs: 450
    // an accepted drop: the thumb fades where it was released
    property int dropFadeMs: 120
    // how long a tile shows a dropped window at the dropped spot when no
    // refresh confirms the move
    property int dropPendingMs: 1500

    // workspace strip: every tile keeps the size the old layout gave
    // stripFixedCount tiles, capped so stripMaxVisible tiles plus the button
    // fit; more than stripMaxVisible scroll. the plus button is
    // stripButtonFraction of a tile's height. a window dragged within
    // stripScrollEdge px of the strip's side scrolls it. stripMaxVisible 7
    // means 7 tiles plus the button fit without scrolling; an 8th overflows
    // (2026-09-15: lowered from 10 so tiles run about 40% larger)
    property int stripFixedCount: 6
    property int stripMaxVisible: 7
    property real stripButtonFraction: 0.44
    property int stripScrollEdge: 48

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

    // ---- hyprland's workspace curve ---------------------------------------

    // the exposé slide and the flight animate a linear time fraction (Expose
    // slideT, Overview flightT) and map it through one of these tables, one
    // lookup per frame (curveAt). no QEasingCurve BezierSpline anywhere: a 24
    // segment spline on the slide and flight, written from JS or bound, crashed
    // quickshell in the sim (QV4 garbage collector / QObject::disconnect,
    // 2026-09-15), and the same build with plain easing types did not.
    // 1025 samples each, so linear interpolation stays under 0.1 px over 5120
    readonly property var flightLut: root._easingLut(root.flightEasing, "OutCubic")
    readonly property var switchLut: root._easingLut(root.switchEasing, "OutQuint")

    // the curves of _easingMap as QEasingCurve defines them, t in 0..1
    function _ease(name, t) {
        switch (name) {
        case "OutCubic":
            return 1 - Math.pow(1 - t, 3);
        case "OutQuart":
            return 1 - Math.pow(1 - t, 4);
        case "OutQuint":
            return 1 - Math.pow(1 - t, 5);
        case "InOutCubic":
            return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(2 - 2 * t, 3) / 2;
        case "InOutQuart":
            return t < 0.5 ? 8 * Math.pow(t, 4) : 1 - Math.pow(2 - 2 * t, 4) / 2;
        case "InOutQuint":
            return t < 0.5 ? 16 * Math.pow(t, 5) : 1 - Math.pow(2 - 2 * t, 5) / 2;
        case "InOutSine":
            return (1 - Math.cos(Math.PI * t)) / 2;
        case "OutExpo":
            // qeasingcurve's form: the 1.001 closes the jump to 1 at the end
            return t >= 1 ? 1 : 1.001 * (1 - Math.pow(2, -10 * t));
        case "Linear":
            return t;
        }
        return NaN;
    }

    // fn sampled at 1025 evenly spaced times, exactly 0 first and 1 last
    function _lut(fn) {
        const n = 1024;
        const out = new Array(n + 1);
        for (let i = 0; i <= n; i++)
            out[i] = fn(i / n);
        out[0] = 0;
        out[n] = 1;
        return out;
    }

    function _easingLut(name, fallback) {
        const key = isNaN(root._ease(name, 0.5)) ? fallback : name;
        return root._lut(function (u) {
            return root._ease(key, u);
        });
    }

    // eased value of a table at time fraction t: exactly 0 and 1 at the ends,
    // linear between neighbouring samples
    function curveAt(lut, t) {
        if (!(t > 0))
            return 0;
        if (t >= 1)
            return 1;
        const x = t * (lut.length - 1);
        const i = Math.floor(x);
        return lut[i] + (lut[i + 1] - lut[i]) * (x - i);
    }

    // d(curveAt)/dt of a table at time fraction t, per unit of t: the slope of
    // the segment t falls in. read once when a running slide is interrupted,
    // never per frame
    function curveSlope(lut, t) {
        if (!(t >= 0) || t >= 1)
            return 0;
        const n = lut.length - 1;
        const i = Math.min(n - 1, Math.floor(t * n));
        return (lut[i + 1] - lut[i]) * n;
    }

    // the time fraction of a table after which its residual |1 - e| stays
    // under half a pixel over travelPx: a slide or flight on it is cut there
    // and snaps to the end. a spring's tail (hyprland's settle epsilon) is
    // invisible and would only hold the overlay and its input longer. called
    // once per slide or flight start, never per frame
    function snapFrac(lut, travelPx) {
        const n = lut.length - 1;
        if (n < 1 || !(travelPx > 0))
            return 1;
        for (let i = n; i >= 0; i--) {
            if (Math.abs(1 - lut[i]) * travelPx >= 0.5)
                return Math.min(1, (i + 1) / n);
        }
        return 1;
    }

    // hyprutils' advanceSpring (src/animation/Spring.cpp, 0.14.2) as one
    // closed-form step from value 0 at rest towards 1: [value, velocity] after
    // t seconds. hyprland steps the same solution once per frame
    function _springAt(t, m, k, c) {
        const w0 = Math.sqrt(k / m);
        const g = c / (2 * m);
        if (g < w0) {
            const wd = Math.sqrt(w0 * w0 - g * g);
            const e = Math.exp(-g * t);
            const s = Math.sin(wd * t);
            return [1 - e * (Math.cos(wd * t) + (g / wd) * s), e * (w0 * w0 / wd) * s];
        }
        if (Math.abs(g - w0) <= Math.max(w0, 1) * 0.0001) {
            const e = Math.exp(-g * t);
            return [1 - e * (1 + g * t), e * g * g * t];
        }
        const r = Math.sqrt(g * g - w0 * w0);
        const r1 = -g + r;
        const r2 = -g - r;
        const a = r2 / (r1 - r2);
        const b = -1 - a;
        const e1 = Math.exp(r1 * t);
        const e2 = Math.exp(r2 * t);
        return [1 + a * e1 + b * e2, a * r1 * e1 + b * r2 * e2];
    }

    function _num(v, fallback) {
        const n = Number(v);
        return (v !== null && v !== undefined && isFinite(n)) ? n : fallback;
    }

    // HyprState's read of the workspacesIn leaf; null when it failed
    function setLiveWorkspaceCurve(spec) {
        root.hyprWorkspaceCurveLive = spec;
        root.hyprWorkspaceCurveLiveDone = true;
        root._resolveWorkspaceCurve();
    }

    // config.json override, else hyprland, else the parsed default. a spring
    // ignores the leaf's speed and lasts until hyprland calls it finished:
    // |1 - value| and |velocity| both within 0.001 (AnimatedVariable.cpp
    // getCurveStep). its shape is sampled into hyprWorkspaceLut (within 0.1 px
    // of the analytic curve over 5120 px). a bezier is its own control points
    // over speed * 100 ms (getPercent), tabulated the same way
    function _resolveWorkspaceCurve() {
        let spec = root.hyprWorkspaceCurveOverride;
        let source = "config";
        if (!spec || typeof spec !== "object") {
            spec = root.hyprWorkspaceCurveLive;
            source = "hyprland";
        }
        if (!spec || typeof spec !== "object") {
            spec = root.hyprWorkspaceCurveDefault;
            source = root.hyprWorkspaceCurveLiveDone ? "default(read failed)" : "default";
        }
        const enabled = spec.enabled !== false;
        let ms = 0;
        let lut = [];
        let spring = null;
        let desc = "";
        if (spec.type === "bezier") {
            const p = spec.points;
            const speed = root._num(spec.speed, 0);
            if (Array.isArray(p) && p.length === 4 && speed > 0) {
                const x1 = root._num(p[0], 0);
                const y1 = root._num(p[1], 0);
                const x2 = root._num(p[2], 1);
                const y2 = root._num(p[3], 1);
                // hyprland's BezierCurve: x is time, y progress. solve x(s) = u
                lut = root._lut(function (u) {
                    let lo = 0;
                    let hi = 1;
                    for (let it = 0; it < 40; it++) {
                        const q = (lo + hi) / 2;
                        if (3 * (1 - q) * (1 - q) * q * x1 + 3 * (1 - q) * q * q * x2 + q * q * q < u)
                            lo = q;
                        else
                            hi = q;
                    }
                    const s = (lo + hi) / 2;
                    return 3 * (1 - s) * (1 - s) * s * y1 + 3 * (1 - s) * s * s * y2 + s * s * s;
                });
                ms = Math.max(1, Math.round(speed * 100));
                desc = "bezier" + (spec.name ? ":" + spec.name : "") + " points=" + [x1, y1, x2, y2].join(",") + " speed=" + speed;
            }
        } else if (spec.type === "spring") {
            const known = spec.stiffness !== undefined && spec.dampening !== undefined;
            const d = root.hyprWorkspaceCurveDefault;
            const m = Math.max(root._num(known ? spec.mass : d.mass, 1), 0.0001);
            const k = Math.max(root._num(known ? spec.stiffness : d.stiffness, d.stiffness), 0.0001);
            const c = Math.max(root._num(known ? spec.dampening : d.dampening, d.dampening), 0);
            const valueEps = root._num(spec.valueEpsilon, 0.001);
            const velocityEps = root._num(spec.velocityEpsilon, 0.001);
            let settle = 1;
            for (; settle < 10000; settle++) {
                const s = root._springAt(settle / 1000, m, k, c);
                if (Math.abs(1 - s[0]) <= valueEps && Math.abs(s[1]) <= velocityEps)
                    break;
            }
            const secs = settle / 1000;
            // hyprland snaps the last <= 0.001 at the finish; scaling by the
            // settled value spreads it over the curve instead
            const end = root._springAt(secs, m, k, c)[0];
            lut = root._lut(function (u) {
                return root._springAt(u * secs, m, k, c)[0] / end;
            });
            ms = settle;
            spring = {
                m: m,
                k: k,
                c: c
            };
            desc = "spring" + (spec.name ? ":" + spec.name : "") + " mass=" + m + " stiffness=" + k + " dampening=" + c + (known ? "" : " (constants not found, default used)");
        }
        if (lut.length < 2)
            desc = "unusable " + JSON.stringify(spec);
        else
            root.hyprWorkspaceMs = ms;
        root.hyprWorkspaceEnabled = enabled;
        root.hyprWorkspaceSpring = lut.length < 2 ? null : spring;
        root.hyprWorkspaceLut = lut;
        desc += (spec.leaf ? " leaf=" + spec.leaf : "") + " source=" + source + (enabled ? "" : " disabled");
        if (!root.workspaceCurveActive)
            desc += " (inactive: switchMs/tileSwitchMs apply)";
        root.hyprWorkspaceDesc = desc;
        if (root.frameLog && root.hyprWorkspaceCurveLiveDone) {
            const line = desc + " ms=" + root.slideMs;
            if (line !== root._wsCurveLogged) {
                root._wsCurveLogged = line;
                console.warn("[synopsis] " + Date.now() + " workspace curve " + line);
            }
        }
    }

    Component.onCompleted: root._resolveWorkspaceCurve()

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
            // tile click switch
            if (data.tileSwitchMs !== undefined) root.tileSwitchMs = data.tileSwitchMs;
            // hyprland's workspace curve
            if (data.followHyprWorkspaceCurve !== undefined) root.followHyprWorkspaceCurve = data.followHyprWorkspaceCurve;
            if (data.hyprWorkspaceCurve !== undefined) root.hyprWorkspaceCurveOverride = data.hyprWorkspaceCurve;
            root._resolveWorkspaceCurve();
            // window drag and drop
            if (data.dragShrinkDistance !== undefined) root.dragShrinkDistance = data.dragShrinkDistance;
            if (data.dropEdgeBuffer !== undefined) root.dropEdgeBuffer = data.dropEdgeBuffer;
            if (data.dropEdgeBufferMin !== undefined) root.dropEdgeBufferMin = data.dropEdgeBufferMin;
            if (data.dropMinVisible !== undefined) root.dropMinVisible = data.dropMinVisible;
            if (data.dropMinVisiblePx !== undefined) root.dropMinVisiblePx = data.dropMinVisiblePx;
            if (data.dragReturnMs !== undefined) root.dragReturnMs = data.dragReturnMs;
            if (data.dropFadeMs !== undefined) root.dropFadeMs = data.dropFadeMs;
            if (data.dropPendingMs !== undefined) root.dropPendingMs = data.dropPendingMs;
            // workspace strip
            if (data.stripFixedCount !== undefined) root.stripFixedCount = data.stripFixedCount;
            if (data.stripMaxVisible !== undefined) root.stripMaxVisible = data.stripMaxVisible;
            if (data.stripButtonFraction !== undefined) root.stripButtonFraction = data.stripButtonFraction;
            if (data.stripScrollEdge !== undefined) root.stripScrollEdge = data.stripScrollEdge;
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
