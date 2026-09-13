import QtQuick
import qs.Core

Item {
    id: scrim

    // the opaque wallpaper lives in BackdropWindow (a lower layer) so the bar shows through the tint
    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
        opacity: Config.scrimOpacity * Overview.progress
    }

    MouseArea {
        anchors.fill: parent
        enabled: Overview.interactive
        acceptedButtons: Qt.LeftButton
        onClicked: Overview.close()
    }
}
