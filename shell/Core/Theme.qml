pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME") || ""

    // ---- defaults -----------------------------------------------------

    readonly property var _defaultDark: ({
        "background": "#111318",
        "error": "#ffb4ab",
        "error_container": "#93000a",
        "inverse_on_surface": "#2f3036",
        "inverse_primary": "#3b608f",
        "inverse_surface": "#e2e2e9",
        "on_background": "#e2e2e9",
        "on_error": "#690005",
        "on_error_container": "#ffdad6",
        "on_primary": "#00315b",
        "on_primary_container": "#d3e3ff",
        "on_secondary": "#243141",
        "on_secondary_container": "#d7e3f8",
        "on_surface": "#e2e2e9",
        "on_surface_variant": "#c4c6d0",
        "on_tertiary": "#3a2947",
        "on_tertiary_container": "#f1dbff",
        "outline": "#8e9099",
        "outline_variant": "#43474e",
        "primary": "#a8c8ff",
        "primary_container": "#00315b",
        "scrim": "#000000",
        "secondary": "#bbc7db",
        "secondary_container": "#3a4757",
        "shadow": "#000000",
        "surface": "#111318",
        "surface_bright": "#37393e",
        "surface_container": "#1d2024",
        "surface_container_high": "#282a2f",
        "surface_container_highest": "#33353a",
        "surface_container_low": "#191c20",
        "surface_container_lowest": "#0c0e13",
        "surface_dim": "#111318",
        "surface_tint": "#a8c8ff",
        "surface_variant": "#43474e",
        "tertiary": "#d5bce4",
        "tertiary_container": "#523f5f"
    })

    // ---- raw file contents ---------------------------------------------

    property bool dmsPresent: false
    property bool _warnedColors: false
    property bool _warnedSettings: false
    property bool _warnedSession: false

    property var _colorsData: null
    property var _pendingPalette: null
    property bool _firstColorsLoad: true

    property string _fontFamily: "Inter"
    property string _monoFontFamily: "JetBrainsMono Nerd Font"
    property int _cornerRadius: 12
    property int _animationSpeed: 1
    property real _fontScale: 1.0
    property real _popupTransparency: 1.0
    property bool _matugenSmartMode: false

    property bool _sessionIsLightMode: false
    property string _sessionWallpaperPath: ""

    // ---- animation duration table (copied from dms Common/Theme.qml) ---
    // index 0 None, 1 Short (default), 2 Medium, 3 Long
    readonly property var _animationDurations: [
        { "short": 0, "medium": 0, "long": 0 },
        { "short": 75, "medium": 150, "long": 250 },
        { "short": 150, "medium": 300, "long": 500 },
        { "short": 225, "medium": 450, "long": 750 }
    ]

    // ---- palette (atomic flip) ------------------------------------------

    property var p: _defaultDark

    readonly property bool isLight: {
        if (_matugenSmartMode && _colorsData && _colorsData.mode !== undefined)
            return _colorsData.mode === "light";
        return _sessionIsLightMode;
    }

    readonly property color primary: p.primary
    readonly property color onPrimary: p.on_primary
    readonly property color primaryContainer: p.primary_container
    readonly property color onPrimaryContainer: p.on_primary_container
    readonly property color secondary: p.secondary
    readonly property color secondaryContainer: p.secondary_container
    readonly property color onSecondaryContainer: p.on_secondary_container
    readonly property color tertiary: p.tertiary
    readonly property color tertiaryContainer: p.tertiary_container
    readonly property color background: p.background
    readonly property color surface: p.surface
    readonly property color surfaceDim: p.surface_dim
    readonly property color surfaceBright: p.surface_bright
    readonly property color surfaceContainerLowest: p.surface_container_lowest
    readonly property color surfaceContainerLow: p.surface_container_low
    readonly property color surfaceContainer: p.surface_container
    readonly property color surfaceContainerHigh: p.surface_container_high
    readonly property color surfaceContainerHighest: p.surface_container_highest
    readonly property color surfaceVariant: p.surface_variant
    readonly property color surfaceText: p.on_surface
    readonly property color surfaceVariantText: p.on_surface_variant
    readonly property color surfaceTextMedium: Qt.rgba(surfaceText.r, surfaceText.g, surfaceText.b, 0.7)
    readonly property color outline: p.outline
    readonly property color outlineVariant: p.outline_variant
    readonly property color error: p.error
    readonly property color onError: p.on_error
    readonly property color scrim: p.scrim
    readonly property color shadow: p.shadow
    readonly property color inversePrimary: p.inverse_primary

    property int paletteVersion: 0
    readonly property int paletteFlipMs: 500

    signal paletteApplied()

    // ---- misc tokens ------------------------------------------------------

    readonly property int cornerRadius: _cornerRadius
    readonly property var _durations: _animationDurations[_animationSpeed] || _animationDurations[1]
    readonly property int shortDuration: _durations.short
    readonly property int mediumDuration: _durations.medium
    readonly property int longDuration: _durations.long
    readonly property int standardEasing: Easing.OutCubic
    readonly property int emphasizedEasing: Easing.OutQuart

    readonly property string fontFamily: _fontFamily
    readonly property string monoFontFamily: _monoFontFamily

    readonly property int fontSizeSmall: Math.round(_fontScale * 12)
    readonly property int fontSizeMedium: Math.round(_fontScale * 14)
    readonly property int fontSizeLarge: Math.round(_fontScale * 16)
    readonly property int fontSizeXLarge: Math.round(_fontScale * 20)

    readonly property int borderWidth: 1
    readonly property int outlineWidth: 2

    readonly property int spacingXXS: 2
    readonly property int spacingXS: 4
    readonly property int spacingS: 8
    readonly property int spacingM: 12
    readonly property int spacingL: 16
    readonly property int spacingXL: 24

    readonly property real popupTransparency: _popupTransparency
    readonly property string wallpaperPath: _sessionWallpaperPath

    // ---- palette application ---------------------------------------------

    function _resolvedPaletteFrom(data) {
        if (!data || !data.colors)
            return null;
        var lightMode = false;
        if (_matugenSmartMode && data.mode !== undefined)
            lightMode = data.mode === "light";
        else
            lightMode = _sessionIsLightMode;
        var picked = lightMode ? data.colors.light : data.colors.dark;
        return picked || null;
    }

    function _applyPendingPalette() {
        if (!_pendingPalette)
            return;
        p = _pendingPalette;
        _pendingPalette = null;
        paletteVersion = paletteVersion + 1;
        paletteApplied();
    }

    Timer {
        id: applyHoldTimer
        interval: 600
        repeat: false
        onTriggered: root._applyPendingPalette()
    }

    // ---- dms-colors.json --------------------------------------------------

    FileView {
        id: colorsFile
        path: root.home + "/.cache/DankMaterialShell/dms-colors.json"
        watchChanges: true
        blockLoading: false

        onLoaded: {
            try {
                var data = JSON.parse(colorsFile.text());
                var palette = root._resolvedPaletteFrom(data);
                if (palette) {
                    root._colorsData = data;
                    root.dmsPresent = true;
                    if (root._firstColorsLoad) {
                        root._firstColorsLoad = false;
                        root.p = palette;
                        root.paletteVersion = root.paletteVersion + 1;
                        root.paletteApplied();
                    } else {
                        root._pendingPalette = palette;
                        applyHoldTimer.restart();
                    }
                } else if (!root._warnedColors) {
                    root._warnedColors = true;
                    console.warn("Theme: dms-colors.json missing colors, using defaults");
                }
            } catch (e) {
                if (!root._warnedColors) {
                    root._warnedColors = true;
                    console.warn("Theme: failed to parse dms-colors.json:", e);
                }
            }
        }

        onFileChanged: colorsFile.reload()

        onLoadFailed: function (error) {
            if (!root._warnedColors) {
                root._warnedColors = true;
                console.warn("Theme: dms-colors.json not available, using defaults");
            }
        }
    }

    // ---- palette-applied.stamp ---------------------------------------------

    FileView {
        id: stampFile
        path: root.home + "/.cache/DankMaterialShell/palette-applied.stamp"
        watchChanges: true
        blockLoading: false

        onFileChanged: {
            stampFile.reload();
            applyHoldTimer.stop();
            root._applyPendingPalette();
        }
    }

    // ---- settings.json ------------------------------------------------------

    FileView {
        id: settingsFile
        path: root.home + "/.config/DankMaterialShell/settings.json"
        watchChanges: true
        blockLoading: false

        function _parse() {
            try {
                var data = JSON.parse(settingsFile.text());
                root._fontFamily = data.fontFamily || "Inter";
                root._monoFontFamily = data.monoFontFamily || "JetBrainsMono Nerd Font";
                root._cornerRadius = data.cornerRadius !== undefined ? data.cornerRadius : 12;
                root._animationSpeed = data.animationSpeed !== undefined ? data.animationSpeed : 1;
                root._fontScale = data.fontScale !== undefined ? data.fontScale : 1.0;
                root._popupTransparency = data.popupTransparency !== undefined ? data.popupTransparency : 1.0;
                root._matugenSmartMode = data.matugenSmartMode === true;
            } catch (e) {
                if (!root._warnedSettings) {
                    root._warnedSettings = true;
                    console.warn("Theme: failed to parse settings.json:", e);
                }
            }
        }

        onLoaded: settingsFile._parse()
        // reload() is async; onLoaded does the parse once the new text is in
        onFileChanged: settingsFile.reload()
        onLoadFailed: function (error) {
            if (!root._warnedSettings) {
                root._warnedSettings = true;
                console.warn("Theme: settings.json not available, using defaults");
            }
        }
    }

    // ---- session.json ------------------------------------------------------

    FileView {
        id: sessionFile
        path: root.home + "/.local/state/DankMaterialShell/session.json"
        watchChanges: true
        blockLoading: false

        function _parse() {
            try {
                var data = JSON.parse(sessionFile.text());
                root._sessionIsLightMode = data.isLightMode === true;
                root._sessionWallpaperPath = data.wallpaperPath || "";
            } catch (e) {
                if (!root._warnedSession) {
                    root._warnedSession = true;
                    console.warn("Theme: failed to parse session.json:", e);
                }
            }
        }

        onLoaded: sessionFile._parse()
        // reload() is async; onLoaded does the parse once the new text is in
        onFileChanged: sessionFile.reload()
        onLoadFailed: function (error) {
            if (!root._warnedSession) {
                root._warnedSession = true;
                console.warn("Theme: session.json not available, using defaults");
            }
        }
    }
}
