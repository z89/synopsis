pragma ComponentBehavior: Bound

// one workspace: the wallpaper with this workspace's windows composed on top,
// in hyprland's own stacking order.

import QtQuick
import Quickshell.Widgets
import qs.Core

Item {
    id: tile

    property var ws: null
    property var mon: null
    property bool current: false

    readonly property int wsId: tile.ws ? tile.ws.id : 0
    readonly property string wsName: tile.ws ? tile.ws.name : ""
    readonly property real tileScale: (tile.mon && tile.mon.w > 0) ? (tile.width / tile.mon.w) : 1
    readonly property bool dropTarget: Overview.dragAddress !== "" && Overview.dropWorkspaceId === tile.wsId
    readonly property bool hovered: hover.hovered
    readonly property bool liveTile: tile.current || tile.hovered

    function thumbCapture(item) {
        if (item)
            item.captureOnce();
    }

    function captureIdle() {
        for (let i = 0; i < thumbs.count; i++)
            tile.thumbCapture(thumbs.itemAt(i));
    }

    ClippingRectangle {
        id: clip
        anchors.fill: parent
        radius: Theme.cornerRadius
        color: Theme.surfaceContainer

        Image {
            anchors.fill: parent
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
            source: Theme.wallpaperPath.length > 0 ? ("file://" + Theme.wallpaperPath) : ""
        }

        Repeater {
            id: thumbs
            model: tile.ws ? tile.ws.windows : []

            delegate: WindowThumb {
                required property var modelData

                win: modelData
                interactive: false
                gated: false
                wantLive: tile.liveTile
                thumbScale: tile.tileScale
                geoX: modelData.x * tile.tileScale
                geoY: modelData.y * tile.tileScale
                geoW: modelData.w * tile.tileScale
                geoH: modelData.h * tile.tileScale
            }
        }
    }

    Rectangle {
        anchors.fill: parent
        color: "transparent"
        radius: Theme.cornerRadius
        border.width: tile.dropTarget ? Theme.spacingXS : (tile.current || tile.hovered ? Theme.spacingXXS : Theme.borderWidth)
        border.color: tile.dropTarget ? Theme.secondary : (tile.current ? Theme.primary : Theme.outline)
    }

    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Theme.spacingXS
        width: name.implicitWidth + Theme.spacingM
        height: name.implicitHeight + Theme.spacingXS
        radius: height / 2
        color: Theme.surfaceContainerHigh

        Text {
            id: name
            anchors.centerIn: parent
            color: tile.current ? Theme.primary : Theme.surfaceTextMedium
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeSmall
            text: tile.wsName
        }
    }

    HoverHandler {
        id: hover
        enabled: Overview.interactive
    }

    MouseArea {
        anchors.fill: parent
        enabled: Overview.interactive
        acceptedButtons: Qt.LeftButton
        onClicked: Overview.activateWorkspace(tile.wsId, tile.wsName)
    }

    DropArea {
        anchors.fill: parent
        keys: ["synopsis-window"]
        onEntered: Overview.setDropTarget(tile.wsId, tile.wsName)
        onExited: Overview.clearDropTarget(tile.wsId)
    }
}
