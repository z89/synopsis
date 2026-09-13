"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

function loadLayout() {
    const filePath = path.join(__dirname, "..", "shell", "Core", "Layout.js");
    let src = fs.readFileSync(filePath, "utf8");
    src = src.replace(/^\.pragma library\s*\n/, "");
    const sandbox = {};
    const context = vm.createContext(sandbox);
    vm.runInNewContext(src + "\nthis.computeExpose = computeExpose; this.computeStrip = computeStrip;", context, { filename: filePath });

    // Values crossing the vm boundary belong to a different realm (their Array/Object
    // are not === the host's), which trips up assert.deepStrictEqual on otherwise
    // identical structures. Round-trip through JSON to normalise to host-realm POJOs.
    const toHostRealm = (value) => JSON.parse(JSON.stringify(value));

    return {
        computeExpose: (...args) => toHostRealm(sandbox.computeExpose(...args)),
        computeStrip: (...args) => toHostRealm(sandbox.computeStrip(...args)),
    };
}

const { computeExpose, computeStrip } = loadLayout();

const EPS = 0.5;

function rectsOverlap(a, b) {
    const ax2 = a.x + a.w;
    const ay2 = a.y + a.h;
    const bx2 = b.x + b.w;
    const by2 = b.y + b.h;
    const overlapW = Math.min(ax2, bx2) - Math.max(a.x, b.x);
    const overlapH = Math.min(ay2, by2) - Math.max(a.y, b.y);
    return overlapW > EPS && overlapH > EPS;
}

function assertInsideArea(rect, area, msg) {
    assert.ok(rect.x >= area.x - EPS, `${msg}: x within left bound`);
    assert.ok(rect.y >= area.y - EPS, `${msg}: y within top bound`);
    assert.ok(rect.x + rect.w <= area.x + area.w + EPS, `${msg}: right edge within area`);
    assert.ok(rect.y + rect.h <= area.y + area.h + EPS, `${msg}: bottom edge within area`);
}

function assertAspectPreserved(win, result, msg) {
    const origW = win.w > 0 ? win.w : 1;
    const origH = win.h > 0 ? win.h : 1;
    const origAspect = origW / origH;
    const newAspect = result.w / result.h;
    const rel = Math.abs(newAspect - origAspect) / origAspect;
    assert.ok(rel < 0.01, `${msg}: aspect preserved within 1% (orig ${origAspect}, new ${newAspect})`);
}

const areas = {
    ultrawide: { x: 60, y: 260, w: 5120 - 120, h: 1440 - 260 - 60 },
    fhd: { x: 0, y: 0, w: 1920, h: 1080 },
};

const fixtures = {
    one: [{ id: "a", x: 0, y: 0, w: 800, h: 600 }],
    twoSideBySide: [
        { id: "a", x: 0, y: 0, w: 800, h: 600 },
        { id: "b", x: 900, y: 0, w: 800, h: 600 },
    ],
    fiveMixed: [
        { id: "a", x: 0, y: 0, w: 400, h: 300 },
        { id: "b", x: 500, y: 0, w: 1200, h: 800 },
        { id: "c", x: 0, y: 400, w: 600, h: 400 },
        { id: "d", x: 700, y: 900, w: 300, h: 900 },
        { id: "e", x: 1200, y: 900, w: 900, h: 300 },
    ],
    twelve: Array.from({ length: 12 }, (_, i) => ({
        id: `w${i}`,
        x: (i % 4) * 500,
        y: Math.floor(i / 4) * 400,
        w: 400 + (i % 3) * 100,
        h: 300 + (i % 2) * 150,
    })),
    fullscreenAndTiny: [
        { id: "full", x: 0, y: 0, w: 5120, h: 1440 },
        { id: "tiny", x: 100, y: 100, w: 200, h: 150 },
    ],
    extremeAspect: [
        { id: "wide", x: 0, y: 0, w: 4000, h: 200 },
        { id: "tall", x: 0, y: 300, w: 200, h: 4000 },
    ],
    overlapping: [
        { id: "a", x: 0, y: 0, w: 400, h: 300 },
        { id: "b", x: 0, y: 0, w: 400, h: 300 },
    ],
    zeroSize: [
        { id: "a", x: 0, y: 0, w: 0, h: 0 },
        { id: "b", x: 100, y: 0, w: 0, h: 200 },
        { id: "c", x: 200, y: 0, w: 300, h: 0 },
    ],
};

const maxScale = 0.95;

for (const areaName of Object.keys(areas)) {
    const area = areas[areaName];
    for (const fixtureName of Object.keys(fixtures)) {
        const windows = fixtures[fixtureName];

        test(`computeExpose ${fixtureName} @ ${areaName}: invariants`, () => {
            const result = computeExpose(windows, area, { spacing: 24, maxScale });

            assert.equal(result.length, windows.length, "same length as input");
            for (let i = 0; i < windows.length; i++) {
                assert.equal(result[i].id, windows[i].id, "same order (id match) as input");
            }

            for (let i = 0; i < result.length; i++) {
                assertInsideArea(result[i], area, `${fixtureName}[${i}]`);
                assertAspectPreserved(windows[i], result[i], `${fixtureName}[${i}]`);
                assert.ok(result[i].scale <= maxScale + 1e-9, "scale <= maxScale");
            }

            const scales = result.map((r) => r.scale);
            for (let i = 1; i < scales.length; i++) {
                assert.ok(Math.abs(scales[i] - scales[0]) < 1e-9, "scale identical for all windows");
            }

            for (let i = 0; i < result.length; i++) {
                for (let j = i + 1; j < result.length; j++) {
                    assert.ok(!rectsOverlap(result[i], result[j]), `no overlap between ${i} and ${j}`);
                }
            }

            const result2 = computeExpose(windows, area, { spacing: 24, maxScale });
            assert.deepEqual(result, result2, "deterministic across repeated calls");
        });
    }
}

test("computeExpose: n = 0 returns empty array", () => {
    const result = computeExpose([], areas.ultrawide, {});
    assert.deepEqual(result, []);
});

test("computeExpose: zero-height area does not throw and preserves length", () => {
    const area = { x: 40, y: 90, w: 1200, h: 0 };
    const windows = fixtures.fiveMixed;
    const result = computeExpose(windows, area, { spacing: 24, maxScale });

    assert.equal(result.length, windows.length, "same length as input");
    for (let i = 0; i < windows.length; i++) {
        assert.equal(result[i].id, windows[i].id, "same order (id match) as input");
        assert.equal(result[i].w, 0, "zero width");
        assert.equal(result[i].h, 0, "zero height");
        assert.equal(result[i].scale, 0, "zero scale");
        assert.equal(result[i].x, area.x, "placed at area origin x");
        assert.equal(result[i].y, area.y, "placed at area origin y");
    }
});

test("computeExpose: topmost original window is not placed in the bottom row when 2+ rows form", () => {
    // twelve windows, mixed sizes: force multiple rows in a small-ish area
    const windows = fixtures.twelve;
    const area = { x: 0, y: 0, w: 1400, h: 1000 };
    const result = computeExpose(windows, area, { spacing: 24, maxScale });

    // topmost original window by vertical centre
    let topIdx = 0;
    let topCentre = Infinity;
    windows.forEach((w, i) => {
        const c = w.y + w.h / 2;
        if (c < topCentre) {
            topCentre = c;
            topIdx = i;
        }
    });

    const maxY = Math.max(...result.map((r) => r.y));
    const rowsExist = new Set(result.map((r) => Math.round(r.y))).size > 1;
    if (rowsExist) {
        assert.ok(result[topIdx].y < maxY + EPS ? result[topIdx].y <= maxY : true, "sanity check ran");
        assert.notEqual(Math.round(result[topIdx].y), Math.round(maxY), "topmost original window is not in the bottom row");
    }
});

test("computeStrip: n = 0 returns empty tiles", () => {
    const result = computeStrip(0, 16 / 9, areas.ultrawide, {});
    assert.deepEqual(result, { tiles: [], tileHeightRatio: 0 });
});

test("computeStrip: n = 1 centres a single tile", () => {
    const area = { x: 0, y: 0, w: 1000, h: 500 };
    const result = computeStrip(1, 16 / 9, area, { gap: 24 });
    assert.equal(result.tiles.length, 1);
    const t = result.tiles[0];
    assert.ok(Math.abs(t.x + t.w / 2 - (area.x + area.w / 2)) < EPS, "centred horizontally");
    assert.ok(Math.abs(t.y + t.h / 2 - (area.y + area.h / 2)) < EPS, "centred vertically");
});

for (const n of [2, 5, 8]) {
    test(`computeStrip: n = ${n} tiles fit area, equal size, gapped, centred`, () => {
        const area = { x: 40, y: 20, w: 1600, h: 300 };
        const gap = 30;
        const result = computeStrip(n, 16 / 9, area, { gap });

        assert.equal(result.tiles.length, n);

        const w0 = result.tiles[0].w;
        const h0 = result.tiles[0].h;
        for (const t of result.tiles) {
            assert.ok(Math.abs(t.w - w0) < EPS, "equal width");
            assert.ok(Math.abs(t.h - h0) < EPS, "equal height");
            assertInsideArea(t, area, "strip tile inside area");
        }

        for (let i = 1; i < result.tiles.length; i++) {
            const prev = result.tiles[i - 1];
            const cur = result.tiles[i];
            const actualGap = cur.x - (prev.x + prev.w);
            assert.ok(Math.abs(actualGap - gap) < EPS, "gap respected");
        }

        const totalWidth = n * w0 + gap * (n - 1);
        const expectedStartX = area.x + (area.w - totalWidth) / 2;
        assert.ok(Math.abs(result.tiles[0].x - expectedStartX) < EPS, "row centred horizontally");

        const expectedY = area.y + (area.h - h0) / 2;
        assert.ok(Math.abs(result.tiles[0].y - expectedY) < EPS, "row centred vertically");

        assert.ok(result.tileHeightRatio > 0 && result.tileHeightRatio <= 1, "tileHeightRatio in (0, 1]");
    });
}

test("computeStrip: shrinks to fit when tiles would overflow the area width", () => {
    const area = { x: 0, y: 0, w: 500, h: 1000 };
    const result = computeStrip(10, 16 / 9, area, { gap: 10, maxTileHeight: 900 });
    const totalWidth = result.tiles.reduce((sum, t) => sum + t.w, 0) + 10 * (result.tiles.length - 1);
    assert.ok(totalWidth <= area.w + EPS, "shrunk row fits within area width");
});
