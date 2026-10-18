// simulator only: a background layer with the same wallpaper the overview's
// backdrop paints, so the nested desktop looks like the real one and the
// backdrop mapping is not a hard cut in the recording. SIM_WALLPAPER is the
// image path (run.sh reads it from DankMaterialShell's session.json).
//
// with SIM_COVER not "0" it also answers the wallpaper cover contract, so the
// overview's cover client can be tested against a capable wallpaper. a client
// asks in $XDG_RUNTIME_DIR/eco-cover-<screen>.json for the window to move to
// the top layer and is answered in eco-cover-state-<screen>.json. unlike the
// real wallpaper this skips the client pid check and the 10 min cap, since sim
// runs are short. with SIM_COVER "0" nothing is read or written.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: win
            required property var modelData
            readonly property bool coverEnabled: Quickshell.env("SIM_COVER") !== "0"
            readonly property string coverDir: Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000"
            property bool coverActive: false
            property real coverSeq: 0
            property bool ackPending: false
            property int ackFrames: 0

            function coverRequest(text) {
                let req = null;
                try {
                    req = JSON.parse(text);
                } catch (e) {
                    return;
                }
                if (!req || typeof req.cover !== "boolean" || typeof req.at !== "number")
                    return;
                // a re-read of a handled request, or a leftover from an earlier run
                if (req.at === coverSeq || Date.now() - req.at >= 10000)
                    return;
                coverSeq = req.at;
                coverSet(req.cover);
            }

            function coverSet(top) {
                if (coverActive === top) {
                    if (!ackPending)
                        writeState();
                    return;
                }
                coverActive = top;
                ackFrames = 0;
                ackPending = true;
                // this window is static, so a frame has to be forced for the
                // compositor to see the new layer
                if (anchor.Window.window)
                    anchor.Window.window.update();
            }

            function writeState() {
                stateFile.setText(JSON.stringify({ "top": coverActive, "at": Date.now(), "seq": coverSeq, "pid": Quickshell.processId }));
            }

            screen: modelData
            color: "#1a1a1a"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: coverActive ? WlrLayer.Top : WlrLayer.Background
            WlrLayershell.namespace: "eco:wallpaper"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            anchors { top: true; bottom: true; left: true; right: true }

            Item { id: anchor }

            // two afterAnimating signals before the ack, so the swap that answers
            // is never a frame from before the layer change was sent
            Connections {
                target: anchor.Window.window
                enabled: win.coverEnabled && win.ackPending
                function onAfterAnimating() {
                    win.ackFrames++;
                    anchor.Window.window.update();
                }
                function onFrameSwapped() {
                    if (win.ackFrames < 2)
                        return;
                    win.ackPending = false;
                    win.writeState();
                }
            }

            FileView {
                id: requestFile
                path: win.coverEnabled ? win.coverDir + "/eco-cover-" + win.modelData.name + ".json" : ""
                watchChanges: true
                blockLoading: false
                printErrors: false
                onFileChanged: reload()
                onLoaded: win.coverRequest(text())
                // a deleted request means cover false
                onLoadFailed: {
                    if (win.coverActive)
                        win.coverSet(false);
                }
            }

            FileView {
                id: stateFile
                path: win.coverEnabled ? win.coverDir + "/eco-cover-state-" + win.modelData.name + ".json" : ""
                preload: false
                atomicWrites: true
                printErrors: false
                // its presence tells a client this wallpaper can cover
                Component.onCompleted: if (win.coverEnabled) win.writeState()
            }

            Image {
                anchors.fill: parent
                source: Quickshell.env("SIM_WALLPAPER").length ? "file://" + Quickshell.env("SIM_WALLPAPER") : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: false
            }
        }
    }
}
