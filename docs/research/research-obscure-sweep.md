# Wide sweep: Mission-Control-style overview/exposé projects for Hyprland/wlroots

Date: 2026-09-13. Target env: Arch Linux, Hyprland 0.56.2 (Lua config runtime), Quickshell 0.3.1, DankMaterialShell 1.6, AMD GPU.

Method used: `gh search repos` (26 free-text queries + 2 topic dumps, logged in
`query_log.txt` / `gh_search_results.jsonl` / `topic_hyprland.json` /
`topic_hyprland-plugin.json`), WebSearch (site:github.com, site:codeberg.org,
site:gitlab.com, site:sourcehut.org/sr.ht, Reddit, AUR), AUR RPC API
(`aur.archlinux.org/rpc/v5/search|info`, since the AUR web UI is behind Anubis
anti-bot and blocked WebFetch), and `gh api graphql` / `gh issue view` for
Hyprland issue history. README facts below come from WebFetch summaries of the
GitHub repo page (not raw READMEs directly, since WebFetch on the repo page
reliably surfaces description/license/stars/README content together);
anything not fetched is marked unverified.

## TOP TIER — compositor/Lua plugins with a broad Mission Control feature set

### 1. gfhdhytghd/hymission
https://github.com/gfhdhytghd/hymission
"Mission Control-style overview with live compositor-side previews, scope-aware
collection, trackpad gestures, and workspace strip." C++23 Hyprland compositor
plugin, CMake, GPL-3.0, 128 stars, 322 commits on master. Explicit Lua config
(0.55+) integration examples. Features: live compositor-rendered previews,
exposé-style scope-aware collection (current/multi/all workspaces), group
drag-drop between workspaces with animated transitions, workspace-to-workspace
transitions without showing the native swipe animation, mouse+keyboard+trackpad
gestures (swipe/pinch), multi-monitor documented as core. Targets recent
Hyprland builds; needs matching dev headers. Alive, most feature-complete of
the sweep.

### 2. nsumbadze/hypr-radiant
https://github.com/nsumbadze/hypr-radiant
Surfaced via omacom/omarchy Discussion #7695 (author nsumbadze, posted
2026-08-21) before being found as a standalone repo. "A window overview for
Hyprland. One keybind shows every window on every workspace." C++23, CMake,
MIT, 8 stars, 229 commits. Multiple view modes — Stage, Wall, Carousel, Ribbon
— plus a separate "App Exposé" mode, SUPER+A opens it, drag-drop between
workspaces, 7 animation styles (Default/Snap/Glitch/Lightcycle/Silk/Reduced/Off),
3-4 finger trackpad gestures, reads Omarchy theme automatically (but is a
generic Hyprland plugin, not Omarchy-only). **Version pinned exactly to
Hyprland 0.55.2–0.56.2** plus Aquamarine 0.14.x / hyprutils 0.14.x /
hyprgraphics 0.5.x / hyprlang 0.6.x — matches the user's Hyprland 0.56.2
almost exactly. Author says mainly tested on Omarchy, not other distros yet.
Very new / very alive.

### 3. colonelpanic8/hyprwinview
https://github.com/colonelpanic8/hyprwinview
"Experimental Hyprland plugin providing both window and workspace overviews
from one loaded plugin." C++, CMake, BSD-3-Clause, 10 stars. Built on top of /
derived from Hyprtasking (the well-known raybbian/hyprtasking), adds a window
overview mode. Live previews, exposé grid, drag-drop (preserved from
Hyprtasking), animation modes (fade_scale/staggered/workspace_zoom/fade),
keyboard+vim nav+type-to-filter, multi-monitor aware grid sizing. Works with
Hyprland 0.54+, uses the Lua config API for modern versions. Pushed
2026-09-08, alive.

### 4. cybergaz/hyprscape
https://github.com/cybergaz/hyprscape
"A niri-style Overview for Hyprland's built-in scrolling layout." C++,
BSD-3-Clause, 5 stars, 21 commits. Hooks the renderer via C++ symbol mangling.
Live previews, exposé view, drag-drop between workspaces, configurable
animation curves (smooth/spring/custom), 4-finger swipe gesture, multi-monitor
implemented but "primarily tested on single output." **Locked to exact
Hyprland 0.56.x** — refuses to build/load otherwise, matching the user's
0.56.2. Caveat: purpose-built for Hyprland's scrolling layout, not the default
dwindle/master layouts.

### 5. sandwichfarm/hyprexpo ("the original hyprexpo fork")
https://github.com/sandwichfarm/hyprexpo
C++23, BSD-3-Clause, 106 stars, 199 commits. Important finding: **the official
hyprexpo plugin has been dropped from hyprwm/hyprland-plugins.** Verified via
`gh api repos/hyprwm/hyprland-plugins/contents/` on 2026-09-13 — current
contents are only borders-plus-plus, csgo-vulkan-fix, hyprbars, hyprfocus; no
hyprexpo directory. sandwichfarm's README states the upstream plugin "was
retired from the official ecosystem" and this fork "signaled continuation and
intends to chase Hyprland releases" (formerly called HyperExpo+). Master
branch targets **Hyprland v0.56.1/v0.56.2** exactly; a separate
`hyprland-git` branch tracks upstream dev. Features: live previews, drag-drop,
keyboard/number selection, Lua gestures, multi-monitor placement, labels,
configurable gaps/borders. Since this is now the de facto maintained
"hyprexpo," it deserves more than the one-line dedupe treatment.

### 6. fedsfarm/gloview
https://github.com/fedsfarm/gloview — "A better macOS Mission Control-style
overview plugin for Hyprland." C++, CMake, GPL-3.0, 85 stars, 27 commits.
Packaged in AUR as `gloview-git` (confirmed via AUR RPC, maintainer fedsfarm).
Layouts: rows/grid/natural. Live previews, exposé grid/row, drag-drop across
workspaces, ~360ms open/close animation, hover states, keyboard nav, "All
Workspaces" expo view. ABI must match running Hyprland exactly (no fixed
version stated beyond that).

### 7. yz778/hyprview
https://github.com/yz778/hyprview — "hyprland overview Plugin." C++, MIT, 68
stars, 37 commits, pushed 2026-09-10. NOT the same repo as cjber/hyprview
(confirmed distinct, see below). Six placement algorithms (grid/spiral/flow/
adaptive/wide/scale), workspace filtering, live previews, drag-drop (implied
via selection), open/close animation, 2-5 finger trackpad swipe, separate
overview per monitor. Version requirement not stated. Alive and fairly
popular for this niche.

## QUICKSHELL-NATIVE (directly relevant to the user's DankMaterialShell/Quickshell 0.3.1 stack)

### 8. Shanu-Kumawat/quickshell-overview
https://github.com/Shanu-Kumawat/quickshell-overview — "A standalone
workspace overview module for Hyprland using Quickshell." QML/Quickshell/Qt6,
GPL, **483 stars** (highest of the non-canonical finds), 42 commits, pushed
2026-08-18. Also packaged in AUR (`quickshell-overview-git`). Extracted from
end-4's illogical-impulse project as a standalone module. Live previews
(toggle live/event mode), exposé grid of all workspaces, drag-drop, smooth
animations, multi-monitor (experimental branch), keyboard (arrows/vim/number)
+ mouse-wheel nav. Needs Quickshell 0.2.0+, Qt6; distinct config syntax for
Hyprland 0.55+ vs 0.54-and-older.

### 9. dom0/qs-hyprview
https://github.com/dom0/qs-hyprview — "A supercharged, QML-based Window
Switcher/Exposé for Hyprland powered by Quickshell." QML/Qt6, GPL-3.0, 85
stars. 10 mathematical layout algorithms, live screencopy previews
(toggleable), exposé dashboard, pop-in/transition animation via native
Hyprland effects, "90% Safe Area" multi-monitor edge handling. No drag-drop or
gesture support mentioned. Needs quickshell in PATH; no pinned Hyprland
version.

### 10. thesleepingsage/hypr-overview
https://github.com/thesleepingsage/hypr-overview — "macOS Mission
Control-ish-style workspace overview for Hyprland." QML/Quickshell, GPL-3.0, 6
stars, 73 commits. Extracted/refactored from end-4/dots-hyprland (same lineage
as #8). Live previews with titles/icons, exposé grid, drag-drop + window
swap, keyboard arrow nav, multi-monitor, configurable-duration animation. No
explicit Hyprland version stated.

### 11. AndyWeiBoan/omarchy-mission-control
https://github.com/AndyWeiBoan/omarchy-mission-control — "A macOS-style
workspace overview for Omarchy, as a shell plugin." QML/Quickshell, MIT, 3
stars, 10 commits. Two-phase reveal (live full-size thumbnails animating down
into a compact exposé layout). Live previews, exposé, 3/4-finger swipe
gesture support, no drag-drop, no explicit multi-monitor. Pure QML, "no
external dependencies," writes nothing outside its own folder. Currently
going through Omarchy's plugin-marketplace verification (see issue #6533
below, opened 2026-09-12) — very fresh.

### 12. debba/omarchy-stage-manager
https://github.com/debba/omarchy-stage-manager — "a macOS-like Stage Manager
sidebar with live previews of every Hyprland window on the focused monitor."
QML, MIT, 2 stars, 1 commit. Not Mission Control proper (it's Stage Manager —
a persistent sidebar, not a full-screen spread), but adjacent and worth
knowing about. Live preview thumbnails with depth/soft-corner styling, app
grouping with stacked cards, hover/keyboard nav (arrows/Tab/Enter/Esc). No
drag-drop, no gestures, single-monitor only. **Explicitly requires Quickshell
0.3.1+** and `hyprland-toplevel-export-v1` — version match to the user's
Quickshell.

### 13-18. Lower-confidence Quickshell/AGS entries (found by name/description only, README not fetched — mark unverified beyond the description string)
- https://github.com/THEBOSS9345/hyprland-overview — "Tokyo Night workspace overview/switcher for Hyprland built with Quickshell," 0★.
- https://github.com/Yiin/hypr-overview — "AGS + Rust live window overview for Hyprland," 0★.
- https://github.com/zereaykut/Hyprland-Overview — "AGS like Overview application for Hyprland window manager," 0★.
- https://github.com/mylinuxforwork/ml4w-quickshell-overview — no description text returned by search, 1★ (likely ML4W's packaging of a quickshell overview module).
- https://github.com/flores666/hypr-quickshell — "A Quickshell desktop shell for Hyprland with a bar, dock, launcher, overview, media controls, notifications, and configs," 3★ (full shell, overview is one feature among many).
- https://github.com/lunanoir21/quickshell-quay — vertical app-launcher rail with live window previews per pinned app; closer to a dock/launcher than an exposé, 1★.

## OTHER APPROACHES (non-Hyprland-plugin, non-Quickshell)

### 19. ThiagoAVicente/hyprexpose (AUR: hyprexpose-git)
https://github.com/ThiagoAVicente/hyprexpose — found via AUR RPC
(`aur.archlinux.org/rpc/v5/info/hyprexpose-git`, maintainer "vcnt", URL field
points at this repo; NOT the same project as sandwichfarm's "hyprexpo").
"Lightweight workspace overview for Hyprland **and Sway** with real window
thumbnails." Rust, Cairo/Pango rendering, wlr-layer-shell overlay daemon
(SIGUSR1-triggered), MIT, 10 stars. This is the layer-shell-overlay +
screencopy approach the task description calls out specifically — genuinely
compositor-agnostic (Hyprland + Sway) rather than a Hyprland-only compositor
plugin. Live thumbnails via hyprland-toplevel-export on Hyprland (falls back
to colored rect+app-id on Sway), keyboard nav (arrows/hjkl), move active
window to another workspace with `m`. No animation, no true drag with the
mouse. Requires Hyprland >= 0.55 for the Lua-based IPC dispatch it uses.

### 20. senox78/hyprPanopticon
https://github.com/senox78/hyprPanopticon — "workspaces arranged on a
circle with live previews." Rust + GTK4 + gtk4-layer-shell, MIT, 2 stars, 38
commits. Standalone overlay (not a compositor plugin) using
hyprland-toplevel-export-v1 + JSON IPC. Unique circular/elliptical layout:
focused workspace at max size, others scaled down by cosine falloff around a
ring. Live previews, ring-rotation+scale animation, keyboard/mouse-wheel/click
nav, multi-monitor (shows every monitor's workspaces by default). No
drag-drop. Targets Hyprland 0.55.

### 21. ShakedGold/hyprmsn
https://github.com/ShakedGold/hyprmsn — "A 'Mission Control' like in macos
for Hyprland." Bash + eww, MIT, 53 stars. Daemon takes screenshots via grim on
focus-change (not continuously live), eww widget grid for click-to-focus,
optional Papirus-icon fallback instead of screenshots, multi-monitor via a
monitor parameter. Lower fidelity than the plugin-based options (screenshots,
not live compositor rendering) but simple/hackable and has real traction (53★).

### 22. Praczet/ags-hyprland
https://github.com/Praczet/ags-hyprland — AGS(GTK4/TSX) shell config with an
"Exposé-style window overview" among other features (clipboard history,
OSDs). MIT, 2 stars. **Archived 2026-07-09** — author states in the README
that development moved on to a new Quickshell-based shell called "Qreep";
did not verify Qreep separately (out of scope / tangential, flagged for
possible follow-up).

### 23. hyprland-community/pyprland "expose" module
https://hyprland-community.github.io/pyprland/expose.html (wiki page
redirects here) — pyprland itself is a fairly well-known Python
"batteries-included" plugin daemon (scratchpads etc.), but the expose feature
specifically is obscure/under-discussed. It does **not** do screencopy/live
thumbnails — it reparents every client on the focused screen onto a special
workspace `special:exposed` (a real Hyprland workspace you can style via
workspace rules) and toggling again restores focus. Static-icons/rearrange
category, not a visual exposé. `bind = $mainMod, B, exec, pypr expose`.

## Adjacent but not really exposé (flagged, not deep-dived)
- https://github.com/thrombe/hyprkool (86★) — KDE-activities + desktop-grid
  spatial navigation, not a screenshot overview.
- https://github.com/chpock/hyprdeck (10★) — tab-groups workspaces (one tile
  visible, rest behind as tabs), not a spread/exposé.
- https://github.com/siarhei-plusnin/hyprdeck (1★, different repo, self-
  described "vibeslopped Hyprland workspace overview plugin") — unverified,
  README not fetched.
- https://github.com/simonwinther/hyprspace (0★, pushed 2026-09-11) — "Live
  workspace overview and Alt+Tab switcher... interactive window previews and
  multi-monitor support." Confirmed via README: independent from
  KZDKM/Hyprspace (no shared code/attribution beyond crediting hyprview/
  hyprshell in NOTICE.md), installable via hyprpm/Nix. Live previews, exposé
  (Super+A), drag-drop, Alt+Tab cycling, multi-monitor. Would rank top-tier
  but has 0 stars and an unclear release/activity history — flagged rather
  than ranked, since freshness/stability could not be confirmed beyond the
  README.
- https://github.com/cjber/hyprview — "Float-grid workspace overview for
  Hyprland 0.55+." Confirmed DIFFERENT repo from yz778/hyprview. Lua module
  (not a compiled plugin) using only stock Hyprland dispatchers: floats tiled
  windows into a grid, unfloat restores scrolling-layout position. Live
  grid view yes, drag-drop not mentioned, no animation/gestures documented,
  works on rotated multi-monitor setups via logical coords. MIT, 2★.

## Well-known projects (per instructions, one line each, not deep-dived)
- https://github.com/hyprwm/hyprland-plugins (hyprexpo) — official, but now
  **removed from the repo** (see finding above); treat as defunct upstream.
- https://github.com/KZDKM/Hyprspace
- https://github.com/raybbian/hyprtasking (also in AUR as `hyprtasking`)
- https://github.com/DreamMaoMao/hycov (368★, archived per community reports)
- https://github.com/end-4/dots-hyprland
- Caelestia, Noctalia (https://github.com/noctalia-dev/noctalia, 10541★, general shell, not overview-specific)
- https://github.com/H3rmt/hyprswitch
- https://github.com/H3rmt/hyprshell

## Hyprland issue/discussion findings (maintainer stance)

1. **hyprwm/Hyprland#1902** — "Workspace overview and window dragging similar
   to Wayfire," opened 2023-03-28, closed 2024-04-03.
   - 2023-04-11 vaxerski: dismisses "cool to see" comments, states the
     feature "requires a pretty sizeable internal rendering rework, and once
     that would be done, plugins could be made for this."
   - 2023-04-12 yavko asks if it could be done with just layer-shell +
     screencopy + workspaces protocols (no core changes); vaxerski: "no."
   - 2023-04-12 vaxerski exposes `renderWorkspace`/workspace-transform
     hooks in a commit and posts a PoC screenshot: "if anyone wants to write
     themselves a plugin feel free."
   - Mid/late 2023: community (levnikmyskin, kim3339, DreamMaoMao) works
     through making the then-private render functions plugin-accessible
     (`#define private public` hack; vaxerski links a real example in
     hyprwinwrap). vaxerski names hycov (2023-11-06) as "the closest" existing
     attempt.
   - 2024-04-02/03 vaxerski posts a video of his own in-progress plugin,
     ships it as `hyprexpo` at hyprwm/hyprland-plugins, closes the issue.
   - 2024-04-12 KZDKM posts Hyprspace as an independent alternative
     ("started my project just a week before hyprexpose was released...
     doesn't rely on function hooks and allows dragging windows between
     workspaces").
   - **Takeaway**: core team's stance is "plugin territory only," achieved by
     exposing internal rendering hooks rather than building it in. This
     stance has not changed since.

2. **hyprwm/Hyprland#3951 / #3955** (duplicate pair) — "Gnome activities and
   macos mission control," opened+closed same day, 2023-11-25. vaxerski
   points to hycov, end-4/dots-hyprland (eww) and Aylur/dotfiles (ags) as
   existing community answers; no core feature planned.

3. **Confirmed via `gh api repos/hyprwm/hyprland-plugins/contents/`
   (2026-09-13)**: current plugin list is borders-plus-plus,
   csgo-vulkan-fix, hyprbars, hyprfocus — **hyprexpo is gone**. This
   corroborates sandwichfarm/hyprexpo's README claim that the official
   plugin was "retired from the official ecosystem," which is why several of
   the community forks/rewrites above (hymission, hypr-radiant, hyprwinview,
   hyprscape, gloview, hyprview, sandwichfarm's own continuation) exist: the
   original hyprexpo is effectively unmaintained/removed upstream and the
   niche has fragmented into many independent replacements over the last
   ~2-3 months (most of the finds above were pushed in Aug-Sep 2026).

4. **omacom/omarchy-plugin-marketplace#6313** — "[Plugin]: Mission Control"
   tracking issue for the marketplace listing.
   https://github.com/omacom/omarchy-plugin-marketplace/issues/6313

5. **omacom/omarchy-plugin-marketplace#6533** — "[Verify]:
   io.github.andyweiboan.missioncontrol — publish 1.0.2 (414a24b)," opened
   2026-09-12. Verification/publish request for AndyWeiBoan/omarchy-mission-
   control (#11 above). https://github.com/omacom/omarchy-plugin-marketplace/issues/6533

6. **omacom/omarchy#7695** — Discussion, "hypr-radiant — workspace overview
   for Hyprland / Omarchy," posted by nsumbadze 2026-08-21. Show-and-tell post
   that is the origin of #2 above (nsumbadze/hypr-radiant).
   https://github.com/omacom/omarchy/discussions/7695

No maintainer statement was found addressing the post-hyprexpo-removal
fragmentation directly (i.e., no comment from vaxerski explaining *why*
hyprexpo was dropped from hyprland-plugins) — flagged as an open question,
unverified beyond the repo-contents diff.

## AUR findings
AUR web UI (`aur.archlinux.org/packages?...`) is blocked by Anubis anti-bot
for WebFetch; used the AUR RPC JSON API instead
(`https://aur.archlinux.org/rpc/v5/search/<term>` and `.../info/<pkgname>`).
Packages found:
- `gloview-git` → fedsfarm/gloview (#6 above)
- `hyprexpose-git` → ThiagoAVicente/hyprexpose (#19 above)
- `quickshell-overview-git` → Shanu-Kumawat/quickshell-overview (#8 above)
- `hycov-git` → DreamMaoMao/hycov (well-known)
- `hyprtasking` → raybbian/hyprtasking (well-known)
- `hyprspace-git`, `hyprspaces`, `hyprspaces-tools`, `hyprspaces-waybar-bin`,
  `waybar-hyprspaces-fork-bin` — these are for a *different*, unrelated
  "hyprspaces" (paired-workspace waybar tooling), NOT KZDKM/Hyprspace or
  simonwinther/hyprspace / btijs/hyprspace / nine7nine/Hyprspace-n7n. Flagged
  to avoid confusion — did not chase the source repo, out of scope (it isn't
  an overview/exposé tool).
- No AUR package found for hymission, hypr-radiant, hyprwinview, hyprscape,
  hyprview, hyprmsn, or hyprPanopticon — install-from-source/hyprpm only for
  those, as far as this sweep found.
- X11-only `skippy-xd-git` ("similar to Overview and Exposé") exists but is
  out of scope (not Wayland).
- `tmux-expose` ("Mission Control-style tmux session switcher with live
  terminal previews") exists but is terminal-only, out of scope.

## Search queries that returned nothing useful (coverage notes)
`gh search repos` (repo search API appears to match name/description/topic
tokens narrowly, not full-text/README — WebSearch was far more productive for
phrase queries):
- "hyprland expose", "hyprland exposé", "hyprland mission control",
  "hyprland activities overview", "hyprland window spread",
  "hyprland lua plugin", "wayland mission control", "wlroots overview",
  "wayland workspace overview", "screencopy overview", "toplevel export
  overview", "ags overview hyprland", "eww overview hyprland", "gtk4 overview
  hyprland", "hyprland thumbnails workspaces", "hyprland live preview
  workspace", "hyprland drag window workspace" — all 0 gh-search hits despite
  several of these terms being satisfied by repos found through WebSearch
  instead (e.g. hyprmsn/gloview/hymission literally describe themselves as
  "Mission Control"-like but didn't surface under the `gh search repos
  "hyprland mission control"` query).

WebSearch:
- `site:codeberg.org` and `site:sr.ht`/`site:sourcehut.org` searches for
  "hyprland overview" surfaced only unrelated dotfiles/mirrors/setup guides —
  no dedicated overview/exposé project found on either forge.
- `site:gitlab.com` "hyprland overview" surfaced only the official Hyprland
  GitLab mirror and dotfiles/starter packages, nothing overview-specific.
- Reddit-scoped searches ("site:reddit.com", "r/hyprland ... 2026") did not
  return actual Reddit threads through this search tool (it appears to not
  index/return Reddit results directly) — could not verify r/hyprland or
  r/unixporn discussion threads at all; this is a real coverage gap, not a
  "nothing exists" result. Recommend a manual Reddit search if that
  discussion history matters.
