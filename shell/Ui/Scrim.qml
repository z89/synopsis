import QtQuick
import qs.Core

Rectangle {
    id: scrim

    color: Theme.scrim
    opacity: Config.scrimOpacity * Overview.progress

    MouseArea {
        anchors.fill: parent
        enabled: Overview.interactive
        acceptedButtons: Qt.LeftButton
        onClicked: Overview.close()
    }
}
