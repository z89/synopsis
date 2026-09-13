.pragma library

// windows: array of { id: string, x: number, y: number, w: number, h: number }  real rects, logical px, any origin
// area:    { x, y, w, h }  the region to fill
// opts:    { spacing: 24, maxScale: 0.95 }  (all optional, these defaults)
// returns: array, same length and order as windows, of { id, x, y, w, h, scale }
function computeExpose(windows, area, opts) {
    var spacing = (opts && typeof opts.spacing === "number") ? opts.spacing : 24;
    var maxScale = (opts && typeof opts.maxScale === "number") ? opts.maxScale : 0.95;

    if (!windows || windows.length === 0) {
        return [];
    }

    // degenerate area (a monitor smaller than the margins, or a strip not laid out
    // yet): place everything at the origin with no size rather than scoring NaN
    if (!area || !(area.w > 0) || !(area.h > 0)) {
        var originX = (area && area.x) || 0;
        var originY = (area && area.y) || 0;
        return windows.map(function (win0) {
            return { id: win0.id, x: originX, y: originY, w: 0, h: 0, scale: 0 };
        });
    }

    // normalise degenerate sizes to 1x1, keep original index for output ordering
    var norm = windows.map(function (win, idx) {
        var w = (win.w > 0) ? win.w : 1;
        var h = (win.h > 0) ? win.h : 1;
        return { index: idx, id: win.id, x: win.x, y: win.y, w: w, h: h };
    });

    if (norm.length === 1) {
        var only = norm[0];
        var fit = Math.min(area.w / only.w, area.h / only.h);
        var scale1 = Math.min(maxScale, fit);
        var outW = only.w * scale1;
        var outH = only.h * scale1;
        var outX = area.x + (area.w - outW) / 2;
        var outY = area.y + (area.h - outH) / 2;
        return [{ id: only.id, x: outX, y: outY, w: outW, h: outH, scale: scale1 }];
    }

    // sort by vertical centre, tie by x
    var sorted = norm.slice().sort(function (a, b) {
        var ca = a.y + a.h / 2;
        var cb = b.y + b.h / 2;
        if (ca !== cb) return ca - cb;
        return a.x - b.x;
    });

    var totalWidth = 0;
    for (var wi = 0; wi < sorted.length; wi++) {
        totalWidth += sorted[wi].w;
    }

    var best = null;
    var bestScore = -Infinity;

    var maxRows = sorted.length;
    for (var numRows = 1; numRows <= maxRows; numRows++) {
        var idealRowWidth = totalWidth / numRows;

        var rows = [];
        var currentRow = [];
        var rowWidth = 0;

        for (var i = 0; i < sorted.length; i++) {
            var win2 = sorted[i];
            if (currentRow.length === 0) {
                currentRow.push(win2);
                rowWidth = win2.w;
            } else {
                var newWidth = rowWidth + win2.w;
                var keepSameRow = Math.abs(newWidth - idealRowWidth) < Math.abs(rowWidth - idealRowWidth);
                if (keepSameRow) {
                    currentRow.push(win2);
                    rowWidth = newWidth;
                } else {
                    rows.push(currentRow);
                    currentRow = [win2];
                    rowWidth = win2.w;
                }
            }
        }
        if (currentRow.length > 0) {
            rows.push(currentRow);
        }

        // sort each row by x
        for (var r = 0; r < rows.length; r++) {
            rows[r] = rows[r].slice().sort(function (a, b) { return a.x - b.x; });
        }

        // measure layout
        var rowHeights = rows.map(function (row) {
            var maxH = 0;
            for (var k = 0; k < row.length; k++) {
                if (row[k].h > maxH) maxH = row[k].h;
            }
            return maxH;
        });
        var rowWidths = rows.map(function (row) {
            var sum = 0;
            for (var k2 = 0; k2 < row.length; k2++) {
                sum += row[k2].w;
            }
            return sum + spacing * (row.length - 1);
        });

        var layoutHeight = rowHeights.reduce(function (a, b) { return a + b; }, 0) + spacing * (rows.length - 1);
        var layoutWidth = Math.max.apply(null, rowWidths);

        var scale = Math.min(area.w / layoutWidth, area.h / layoutHeight, maxScale);

        var usedArea = layoutWidth * scale * (layoutHeight * scale);
        var totalArea = (area.w * area.h) || 1;
        var space = 1 - (usedArea / totalArea);

        var score = scale - 0.1 * space;

        if (score > bestScore) {
            bestScore = score;
            best = { rows: rows, rowHeights: rowHeights, rowWidths: rowWidths, layoutWidth: layoutWidth, layoutHeight: layoutHeight, scale: scale };
        } else if (numRows >= 2) {
            // GNOME stops early once a candidate scores worse than the previous best,
            // but only after evaluating at least numRows = 1 and 2.
            break;
        }
    }

    // place
    var result = new Array(norm.length);
    var totalHeight = best.layoutHeight * best.scale;
    var blockY = area.y + (area.h - totalHeight) / 2;

    var cursorY = blockY;
    for (var ri = 0; ri < best.rows.length; ri++) {
        var row = best.rows[ri];
        var rowH = best.rowHeights[ri] * best.scale;
        var rowW = best.rowWidths[ri] * best.scale;
        var cursorX = area.x + (area.w - rowW) / 2;

        for (var ci = 0; ci < row.length; ci++) {
            var win3 = row[ci];
            var w3 = win3.w * best.scale;
            var h3 = win3.h * best.scale;
            var y3 = cursorY + (rowH - h3) / 2;
            result[win3.index] = { id: win3.id, x: cursorX, y: y3, w: w3, h: h3, scale: best.scale };
            cursorX += w3 + spacing * best.scale;
        }
        cursorY += rowH + spacing * best.scale;
    }

    return result;
}

// n: tile count; aspect: monitor width/height; area: { x, y, w, h }
// opts: { gap: 24, maxTileHeight: area.h }  (optional)
// returns: { tiles: [ { x, y, w, h } ] (length n), tileHeightRatio: h / area.h }
function computeStrip(n, aspect, area, opts) {
    var gap = (opts && typeof opts.gap === "number") ? opts.gap : 24;
    var maxTileHeight = (opts && typeof opts.maxTileHeight === "number") ? opts.maxTileHeight : area.h;

    if (!n || n <= 0) {
        return { tiles: [], tileHeightRatio: 0 };
    }

    var height = Math.min(maxTileHeight, area.h);
    var width = height * aspect;

    var totalWidth = n * width + gap * (n - 1);
    if (totalWidth > area.w) {
        var availableForTiles = area.w - gap * (n - 1);
        width = availableForTiles / n;
        height = width / aspect;
        totalWidth = n * width + gap * (n - 1);
    }

    var startX = area.x + (area.w - totalWidth) / 2;
    var y = area.y + (area.h - height) / 2;

    var tiles = [];
    var x = startX;
    for (var i = 0; i < n; i++) {
        tiles.push({ x: x, y: y, w: width, h: height });
        x += width + gap;
    }

    return { tiles: tiles, tileHeightRatio: height / area.h };
}
