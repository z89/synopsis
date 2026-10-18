import QtQuick
import QtMultimedia
import Quickshell.Io
import qs.Core

// one silent, looping player for the tiles' small proxy of a video
// wallpaper. its owner creates and destroys it through a Loader gated on the
// overview, so the decoder exists only while the overview is open. no
// AudioOutput, so it never makes a sound. it starts where eco's own player has
// got to (the playhead file eco keeps per screen), so the tiles show the same
// moment as the wallpaper and opening the overview does not make the clip jump
Item {
    id: video

    // a file URL (Wallpaper.proxyUrl)
    property string source: ""
    // the hyprland monitor name, which picks eco's playhead file
    property string monitorName: ""
    readonly property bool ready: video._ready
    readonly property bool failed: video._failed

    property bool _ready: false
    property bool _failed: false
    // eco's playhead as read on completion, null when it does not apply
    property var _anchor: null
    // play() went out (on the first loaded status)
    property bool _started: false
    // when the seek and play went out, 0 when no seek was made
    property real _seekAt: 0
    property real _seekFrom: -1
    property real _seekTarget: -1
    // the first frame landed ahead of eco's playhead and the clip is paused
    // until eco catches up. frames that still arrive meanwhile are ignored
    property bool _aligning: false
    // play() went out after the alignment pause, so the next frame is ready
    property bool _resumed: false

    // how far ahead of eco's playhead the seek aims. the proxy's short gops
    // seek in 13 to 38 ms uncontended, and a frame that lands early waits for
    // eco exactly while one that lands late shows as a jump back, so the aim
    // errs early
    readonly property int _aheadMs: 60

    function _fail() {
        firstFrameTimeout.stop();
        alignTimer.stop();
        video._failed = true;
    }

    function _becomeReady() {
        firstFrameTimeout.stop();
        video._aligning = false;
        video._ready = true;
    }

    // the playhead file per the contract with eco: ignored unless it names the
    // clip shown here and knows the duration. the age limit is in _anchorPos
    function _readAnchor() {
        if (video.monitorName === "")
            return null;
        let a = null;
        try {
            const text = playhead.text();
            if (!text)
                return null;
            a = JSON.parse(text);
        } catch (e) {
            return null;
        }
        if (!a || typeof a !== "object" || a.path !== Wallpaper.path)
            return null;
        const duration = Number(a.duration);
        const position = Number(a.position);
        const at = Number(a.at);
        const rate = a.rate === undefined ? 1 : Number(a.rate);
        if (!(duration > 0) || !isFinite(position) || !isFinite(at) || !isFinite(rate))
            return null;
        return {
            position: position,
            duration: duration,
            rate: rate,
            playing: a.playing === true,
            at: at
        };
    }

    // where eco's player is at now, -1 when the anchor is missing or stale.
    // only a playing anchor goes stale: eco writes nothing while paused, and a
    // paused position does not move however old the file is
    function _anchorPos(now) {
        const a = video._anchor;
        if (!a)
            return -1;
        if (!a.playing)
            return a.position;
        if (now - a.at > 30000)
            return -1;
        const p = (a.position + (now - a.at) * a.rate) % a.duration;
        return p < 0 ? p + a.duration : p;
    }

    // the first loaded status: seek ahead of eco's playhead by the expected
    // seek latency, so the first frame lands at or just past where eco's
    // player is by then. a paused clip is not moving, so it gets no lead
    function _start() {
        video._started = true;
        const now = Date.now();
        const pos = video._anchorPos(now);
        if (pos >= 0) {
            const d = video._anchor.duration;
            const ahead = video._anchor.playing ? video._aheadMs : 0;
            video._seekFrom = Math.round(pos);
            video._seekTarget = Math.round((pos + ahead) % d);
            video._seekAt = now;
            player.position = video._seekTarget;
        } else {
            video._anchor = null;
        }
        player.play();
    }

    Component.onCompleted: {
        if (video.source === "")
            return;
        // tmpfs and about 100 bytes, so the blocking read costs nothing here
        video._anchor = video._readAnchor();
        player.source = video.source;
        firstFrameTimeout.start();
    }

    Component.onDestruction: {
        firstFrameTimeout.stop();
        alignTimer.stop();
        player.stop();
        // unloads the media and frees the decoder
        player.source = "";
    }

    // a player that never becomes ready fails like a load error, so the still
    // is never left waiting on it. it runs until ready, not until the first
    // frame, so a resume that never delivers a frame fails over too
    Timer {
        id: firstFrameTimeout
        interval: 4000
        repeat: false
        onTriggered: {
            if (!video._ready)
                video._fail();
        }
    }

    // the wait for eco's playhead to reach the paused first frame. play()
    // after that pause shows the next frame at once (measured under 1 ms on
    // the ffmpeg backend, no re-seek), so the wait is the whole offset
    Timer {
        id: alignTimer
        repeat: false
        onTriggered: {
            if (video._ready || video._failed)
                return;
            // set before play(), in case the frame comes out inside it
            video._aligning = false;
            video._resumed = true;
            player.play();
        }
    }

    MediaPlayer {
        id: player
        loops: MediaPlayer.Infinite
        videoOutput: output

        onErrorOccurred: video._fail()
        onMediaStatusChanged: {
            if (video._started || video._failed)
                return;
            if (player.mediaStatus === MediaPlayer.LoadedMedia || player.mediaStatus === MediaPlayer.BufferedMedia)
                video._start();
        }
    }

    // eco's playhead for this screen, read once on completion
    FileView {
        id: playhead
        path: video.monitorName === "" ? "" : Wallpaper.playheadPath(video.monitorName)
        blockLoading: true
        watchChanges: false
        printErrors: false
    }

    VideoOutput {
        id: output
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectCrop
    }

    Connections {
        target: output.videoSink

        function onVideoFrameChanged() {
            if (video._ready || video._failed || player.playbackState === MediaPlayer.StoppedState)
                return;
            // an empty frame (queued by a stop) has no size. QVideoFrame is not
            // reachable from QML, videoSize is
            const size = output.videoSink.videoSize;
            if (!size || size.width <= 0 || size.height <= 0)
                return;
            // a frame between the alignment pause and the resume is the old one
            if (video._aligning)
                return;
            if (video._resumed) {
                video._becomeReady();
                return;
            }
            let wait = 0;
            if (video._seekAt > 0) {
                const now = Date.now();
                const l = now - video._seekAt;
                // how far this frame is ahead of eco's playhead, the short way
                // round the loop
                let e = 0;
                const pos = video._anchor.playing ? video._anchorPos(now) : -1;
                if (pos >= 0) {
                    const d = video._anchor.duration;
                    e = ((video._seekTarget - pos) % d + d) % d;
                    if (e > d / 2)
                        e -= d;
                }
                // early is fixed by waiting. late shows as it is, a second
                // seek would only be later still
                if (e > 8)
                    wait = Math.round(e);
                if (Config.frameLog)
                    console.warn("[synopsis] " + now + " video " + video.monitorName + " seek anchor " + video._seekFrom + " target " + video._seekTarget + " landed " + player.position + " latency " + l + " offset " + Math.round(e) + " wait " + wait);
            }
            if (wait > 0) {
                // pausing after the first frame is safe, pausing before it
                // stalls readiness (eco)
                video._aligning = true;
                player.pause();
                alignTimer.interval = wait;
                alignTimer.start();
                return;
            }
            video._becomeReady();
            // eco's clip is paused, so this one holds its frame. pausing before
            // the first frame stalls readiness (eco), pausing after it is fine
            if (video._anchor && !video._anchor.playing)
                player.pause();
        }
    }
}
