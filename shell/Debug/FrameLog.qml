// console.log is dropped by quickshell's default log filter, so everything here is warn.

import QtQuick
import qs.Core

QtObject {
    id: root

    property string screenName: ""
    property var qwin: null
    property bool logState: false

    readonly property Connections frames: Connections {
        target: (Config.frameLog && root.qwin) ? root.qwin : null
        enabled: Config.frameLog && Overview.active

        function onFrameSwapped() {
            console.warn("[synopsis] frame " + root.screenName + " " + Date.now() + " " + Overview.progress.toFixed(3));
        }
    }

    readonly property Connections states: Connections {
        target: (root.logState && Config.frameLog) ? Overview : null

        function onStateChanged() {
            console.warn("[synopsis] state " + Date.now() + " " + Overview.state);
        }
    }
}
