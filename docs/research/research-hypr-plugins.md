# Hyprland Mission-Control-style plugin research (2026-09-13)

Target: Hyprland 0.56.2, Arch, AMD, Lua config runtime (hl.plugin.load).

## 1. hyprexpo (ORIGINAL) — hyprwm/hyprland-plugins
- Repo: https://github.com/hyprwm/hyprland-plugins (monorepo of official plugins)
- Current root listing (fetched live): borders-plus-plus, csgo-vulkan-fix, hyprbars, hyprfocus, hyprpm.toml, README.md, flake.nix/lock, .github, .clang-format, .gitignore, CMakeLists.txt, LICENSE — NO hyprexpo directory anymore.
- Repo stats: stars 1453, pushed 2026-09-04T23:06:23Z, archived:false, license BSD-3-Clause.
- REMOVAL: commit 3aa21f2e "all: drop unmaintained plugins (#663)" (merged 2026-05-12, same commit tagged for Hyprland 0.55.0 pin) deleted hyprexpo/*, hyprscrolling/*, hyprtrails/*, hyprwinwrap/*, xtra-dispatchers/* and hyprload.toml.
  - Commit: https://github.com/hyprwm/hyprland-plugins/commit/3aa21f2e
- Direct maintainer quote (vaxerski) on retirement, PR #507 discussion thread comment id 4433386463:
  > "I've dropped this plugin as I was doing a poor job maintaining it. If anyone wants to maintain a fork, be my guest."
  - https://github.com/hyprwm/hyprland-plugins/pull/507#issuecomment-4433386463
- hyprpm.toml (current, fetched live) only defines [borders-plus-plus], [csgo-vulkan-fix], [hyprbars], [hyprfocus] — hyprexpo entry gone entirely, pins run up to 0.56.2.
- Conclusion: **hyprexpo is dead upstream.** Not merged into core either (see section 9). All current usage is via community forks below.
- Open issues on the (frozen) hyprexpo code still exist in this repo (e.g. #578 "skip_empty=true still renders empty tiles", #504 "Hyprland crashes when opening many terminals rapidly", #628 "Release soon?") but no more fixes will land here.

## 2. sandwichfarm/hyprexpo — active continuation fork
- Repo: https://github.com/sandwichfarm/hyprexpo
- Stats: stars 106, pushed 2026-09-11T13:09:17Z, archived:false, license BSD-3-Clause, fork:false (detached/standalone repo, not a GitHub "fork" object).
- Description: "The original hyprexpo fork". Formerly "HyprExpo+ / hyprexpo-plus", born from PR https://github.com/hyprwm/hyprland-plugins/pull/507 (comprehensive keyboard nav / hover / multi-monitor / labels / gradient borders feature PR that was never merged upstream before retirement).
- hyprpm.toml commit_pins run through 0.53.0 → 0.56.2 explicitly:
  `["efb50993780079460b0cbed1363e2166a2de1d9f", "5891014c611e1bd56d0121143f0221d46b5c0967"]  # 0.56.2` (matches Hyprland's own 0.56.2 commit hash from hyprwm/hyprland-plugins pins, confirms real ABI pairing).
- since_hyprland = 6066 (same field style as official plugins).
- Very high commit/issue churn in Sept 2026 (issues #111-#133 nearly all opened+closed within days, titles read like automated/agentic maintenance, e.g. "Reconcile the landed repository cleanup into hyprland-git", "Guard HyprPM registrations and releases against temporary revisions") — sign of aggressive but possibly bot-assisted maintenance; worth independent verification of code quality.
- Feature set (README): workspace-grid exposé (NOT per-window exposé — grid of WORKSPACES, same model as original hyprexpo), keyboard selection (arrow/number/letter, submap-based), mouse hover highlight, drag_drop_enable option (default 1) to drag windows between workspace preview tiles, configurable gaps/borders/labels, multi-monitor placement (`workspace_method = center current`), Lua gesture config, fixed or dynamic grid (rows/columns), skip_empty.
- Explicitly documents Lua config usage: `hl.config({ plugin = { hyprexpo = {...} } })` and `hl.bind("SUPER + G", function() hl.plugin.hyprexpo.expo("toggle") end)` — confirms hl.plugin.<name>.<fn>() binding namespace works for this plugin under the Lua runtime.
- Native-scrolling-layout (niri-style column workspaces) gets an EXTRA "window-level scrolling overview" per README intro — this is the one place actual per-window (not just per-workspace) spreading happens, but only for scrolling-layout users; README explicitly says "This is intentionally not full Niri parity."
- Related fork also mentioned in its own README: https://github.com/colonelpanic8/hyprexpo

## 3. colonelpanic8/hyprexpo — parallel standalone fork
- Repo: https://github.com/colonelpanic8/hyprexpo
- Stats: stars 22, pushed 2026-06-11T13:54:04Z, archived:false, license BSD-3-Clause, desc "Standalone maintained fork of the HyprExpo Hyprland plugin".
- Last push predates the 0.56.0 release cycle activity seen elsewhere (0.56.0 pin work in hyprland-plugins happened ~2026-07-15 per hyprpm.toml commit dates) — compat with 0.56.2 UNVERIFIED, could not confirm hyprpm.toml pins beyond what's visible; did not fetch its hyprpm.toml.
- Config includes `preview_mode = live | cached` — explicit toggle between real-time render and cached/static thumbnail, notable since task asked specifically about live vs static rendering. Also keyboard nav, per-state border colors (current/hover/focus), window icons, labels (token/index/id modes).
- No drag-and-drop mentioned in the README excerpt fetched.

## 4. Hyprspace — KZDKM/Hyprspace
- Repo: https://github.com/KZDKM/Hyprspace
- Stats: stars 1285, pushed 2026-05-28T12:24:43Z, archived:false, license GPL-2.0.
- README carries an explicit maintainer note (still current at fetch time):
  > "This plugin is still maintained, ... However, I do not have as much time ... I could not guarantee new issues could be resolved promptly ... I could recommend giving niri a try ... It also has better workspace management..."
- **hyprpm.toml commit_pins stop at 0.50.1** (last pin entry: `["4e242d086e20b32951fdc0ebcbfb4d41b5be8dcc", "0a82e3724f929de8ad8fb04d2b7fa128493f24f7"] # 0.50.1`) — NO pins for 0.51 through 0.56.x, so `hyprpm add` will not resolve a matching build for Hyprland 0.56.2 as of the fetch.
- Open compat issues (unresolved at fetch time):
  - "Port to Hyprland 0.56.2" — https://github.com/KZDKM/Hyprspace/issues/240 (opened 2026-08-29)
  - "Hyprspace Hyprland 0.56.2 compatiblity" — https://github.com/KZDKM/Hyprspace/issues/241 (opened 2026-09-04)
  - "Migrate to V2 API + lua config + compositor and render fixes" — https://github.com/KZDKM/Hyprspace/issues/238 (opened 2026-07-08, still open) — confirms **no Lua-config support yet**, directly relevant to the user's Lua-runtime setup.
- Conclusion: real, popular, well-documented plugin, but **currently NOT compatible with Hyprland 0.56.x nor the Lua config runtime**, and author's own README steers users toward niri instead.
- Feature set (from README, historically): workspace-minimap overview panel, click workspace to switch, click+drag window to move it, drag window into a workspace tile to move it there (real drag-and-drop between workspaces), autoscroll/autodrag, animation (slide-in on "windows" curve), full touchpad gesture support (swipe open/close, scroll to pan), multi-monitor + monitor scaling tested, blacklisting/hiding empty or special workspaces, styling of panel/workspace colors and borders. This is workspace-level (Mission-Control "top strip"), not per-window exposé of the current workspace.
- Source layout: Globals.hpp, Input.cpp, Layout.cpp, Overview.cpp/hpp, Render.cpp, main.cpp — separate render and input hook files (architecture consistent with hooking Hyprland's render pipeline + input dispatch, not confirmed line-by-line).

## 5. hyprtasking — raybbian/hyprtasking
- Repo: https://github.com/raybbian/hyprtasking
- Stats: stars 376, pushed 2026-09-09T01:53:34Z, archived:false, license BSD-3-Clause.
- README states explicitly: "Supports Hyprland releases v0.46.2-v0.56.2." Ships its own hyprpm.toml compat pins ("Hyprpm uses the compatibility pins in hyprpm.toml to select the corresponding hyprtasking revision").
- Confirmed real-world 0.56.2 work via closed issues:
  - #131 "fix: support Hyprland 0.56.2 plugin ABI" (closed)
  - #128 "Plugin crashes on load: 'Failed initializing hooks' on Hyprland 0.56.2" (closed)
  - #121 "Support Hyprland 0.56" (closed)
  - #123 "Chase hyprland v0.56.1" (closed)
  - #124 "Error while compiling with hyprland 0.56.1 (Gentoo Linux)" (closed)
  - #115 "Add support for new lua configuration?" (closed) — Lua config support confirmed landed.
  - Still-open concerns: #133 "Scale affects Z-ordering", #130 "Workspace ordering instability", #127 "hyprpm build fails: find glob in meson.build picks up build/meson-private/sanity_check_for_cpp.cpp", #120 "[meson.build] Lua dependency missing for compiling", #122 "plugin not building on hyprland cashyos", #118 "kitty is not updating after focusing another workspace".
- Full Lua config example present in README using `hl.bind(...)`, `hl.plugin.hyprtasking.toggle(...)`, `hl.plugin.hyprtasking.move(...)`, `hl.plugin.hyprtasking.killhovered()`, `hl.config({ plugin = { hyprtasking = {...} } })` — directly matches the user's environment.
- Feature set: grid layout (rows x cols x layers "3D" grid of WORKSPACES) or linear layout (strip), left-click drag-and-drop of windows, right-click to switch workspace, jump labels (press a key to jump straight to a workspace), directional move dispatchers with coordinate space, touchpad gesture open/move, animation on workspace transitions, multi-monitor + scaling tested, per-monitor toggle ("cursor" vs "all"), close-on-escape via `if_active` dispatcher pattern.
- This is workspace-grid overview + DnD, not per-window exposé of the current workspace.
- AUR: `hyprtasking` 0.4-1, but **Out-of-date since 2026-07-30** per `yay -Si` (no direct pacman/yay -S test run, read-only query only).

## 6. hycov — DreamMaoMao/hycov
- Repo: https://github.com/DreamMaoMao/hycov
- Stats: stars 368, pushed 2024-06-25T15:16:59Z, **archived: true**, license MIT.
- README explicitly limits scope to "the hyprland version corresponding to each hycov release" and says it doesn't track every Hyprland commit — this was already true in 2024, now badly stale for 0.56.2 (2+ years of Hyprland ABI churn since last push).
- This is the one plugin found doing genuine **per-window exposé of the CURRENT workspace**: "Hycov can tile all of your windows in a single workspace via grid layout" (a real tiling/exposé of the active workspace's windows, restorable to prior floating/fullscreen/size/position state on exit). Modes: `toggleoverview` (normal, respects only_active_workspace/monitor config), `forceall`, `onlycurrentworkspace`, `forceallinone` (all windows across the whole monitor into one grid).
- Extras: hot-corner trigger (`enable_hotarea`, position/size config), touchpad gesture trigger, directional focus-move dispatcher usable even outside overview mode, click-to-jump / right-click-to-kill in overview, multi-monitor.
- Checked DreamMaoMao's other active (non-archived) repos for a successor: none found. Author's current major project is "mango" (https://github.com/DreamMaoMao/mango-config, and presumably a "mango" compositor repo) — a standalone Wayland compositor, not a Hyprland plugin. No hycov successor plugin exists from this author.
- AUR: `hycov-git` 0.34.0.1.r95.84b9f00-1 exists but tracks the dead upstream, last AUR touch info shows package age ~955 days — effectively unmaintained downstream too.
- Conclusion: dead, incompatible with 0.56.x (unverified by direct build test, but 2+ years of Hyprland internal API churn plus explicit non-tracking policy in its own README make compatibility extremely unlikely).

## 7. yz778/hyprview — per-window exposé, very new
- Repo: https://github.com/yz778/hyprview
- Stats: stars 68, pushed 2026-09-10T04:13:27Z, archived:false, license MIT.
- Genuine per-window exposé: "window overview with multiple placement algorithms... display windows from the current workspace, all workspaces on a monitor, or include special workspaces." Six algorithms: grid (default, dynamic), spiral, flow, adaptive, wide, **scale** ("A clone of the Wayfire `scale` plugin that enlarges the center window") — scale/grid modes are functionally macOS-Exposé-like non-overlapping spreads of the current workspace's windows.
- Other features: hover-to-focus + click-to-select (auto-closes overview), trackpad swipe gestures with gesture-conflict prevention (blocks workspace-swipe while overview active), smooth open/close animations, multi-monitor (separate overview per monitor), background dimming, active-window highlight border, focus restoration on close.
- Dispatcher: `hyprview:toggle`, `hyprview:toggle, all`, `hyprview:toggle, all special`, `hyprview:toggle, off`.
- Compat evidence: closed issue #22 "Port to Hyprland 0.56" — https://github.com/yz778/hyprview/issues/22 (closed, so code was updated for 0.56).
- **BUT hyprpm.toml commit_pins list has only ONE entry, still pinned to 0.51.1**:
  `["71a1216abcc7031776630a6d88f105605c4dc1c9", "5cbdc6f4aee021bb43f1e66c3f768b8c100e3eb8"] # 0.51.1`
  This means `hyprpm add` will very likely NOT auto-resolve a build against a 0.56.2 Hyprland install even though the source has been patched for 0.56 — manual build via `make -C src all` + `hyprctl plugin load` would be the working path, or a manual hyprpm.toml pin edit.
- Open issue #23 "Fix Lua configuration and animation crashes" (open) — Lua config path has known crash bugs at fetch time.
- Open issue #10 "drag window through overviewed photo like hyprspace?" (open) — confirms **no drag-and-drop yet**, only hover/click select; this is an outstanding feature request referencing Hyprspace's DnD as the desired behavior.
- Open issue #19 "Possible malicious copy of this repo" (closed) — flagging for caution; did not fetch full thread, resolution/nature unverified. Recommend a manual look before trusting the binary blindly.
- Not found in AUR under "hyprview" (yay -Ss hyprview returned no hits).

## 8. cjber/hyprview — DIFFERENT project, same name, Lua-only, no plugin binary
- Repo: https://github.com/cjber/hyprview
- Stats: stars 2, pushed 2026-05-18T11:23:24Z, archived:false, license MIT. Desc: "Float-grid workspace overview for Hyprland 0.55+".
- IMPORTANT: name collision with #7 (yz778/hyprview) — different author, different architecture, unrelated codebases.
- Architecture is fundamentally different from every other entry: **not a compiled C++ .so plugin loaded via hl.plugin.load at all**. It's a pure Lua module dropped into Hyprland's Lua module path and invoked via `require("hyprview").setup({...})` from hyprland.lua. It only calls stock `hl.dsp.window.*` dispatchers to float every tiled window on the ACTIVE workspace into a grid (real windows, not thumbnails/renders — genuine per-window exposé of the current workspace only), and unfloats them back (scrolling-layout columns restored to original order) on second press.
- Its own README gives a reason for existing that is worth flagging and re-verifying against 0.56.2 specifically:
  > "Plugin dispatchers are not exposed through the Lua bridge: builds of hyprexpo, hyprexpo-plus, and the various hyprland-scroll-overview forks load successfully, but their :expo and :overview dispatchers cannot be invoked from Lua, hyprctl, or the raw IPC socket."
  This appears to PREDATE or be unaware of the `hl.plugin.<name>.<fn>()` binding namespace that hyprtasking's and sandwichfarm/hyprexpo's current READMEs both demonstrate working (see sections 2 and 5). Could not directly reconcile the discrepancy — recommend testing hl.plugin.<name> bindings directly on this system before trusting either claim.
- No drag-and-drop, no other-workspace visibility, no thumbnails/live-render (it's literally the real windows re-floated), no gestures mentioned, no config beyond bind+padding shown in the README excerpt fetched.
- Not in AUR.

## 9. simonwinther/hyprspace — brand-new, distinct from KZDKM/Hyprspace
- Repo: https://github.com/simonwinther/hyprspace (lowercase "hyprspace", NOT a fork of KZDKM/Hyprspace — `fork:false, parent:null` confirmed via API).
- Stats: stars 0, created 2026-08-20T11:31:09Z, pushed 2026-09-11T16:43:35Z, archived:false, license MIT.
- Desc: "Live workspace overview and Alt+Tab switcher for Hyprland, with interactive window previews and multi-monitor support."
- README explicitly pins to an exact commit: "Supports Hyprland 0.56.2, commit efb50993780079460b0cbed1363e2166a2de1d9f, on x86_64 Linux." (This is the exact same 0.56.2 Hyprland commit hash used in hyprwm/hyprland-plugins' and sandwichfarm/hyprexpo's own pin tables — internally consistent.)
- Explicitly warns of a DIFFERENT namesake: "Use this repository's flake: Nixpkgs' `hyprlandPlugins.hyprspace` is a different project" (likely referring to KZDKM's Hyprspace being packaged in nixpkgs under a similar attribute).
- Feature set: Super+A opens workspace overview with live real window previews; "Fullscreen and maximized workspaces spread their previews apart so every window stays visible" (workspace-level non-overlap logic); Alt+Tab hold-to-cycle / release-to-focus switcher integrated into the same plugin; Super+left-drag to rearrange a window or move it across workspaces AND outputs; Super+right-drag to resize a window directly in its preview; arrow/number keys to jump workspaces; overview stays interactive while apps launch/resize (doesn't need to be a frozen snapshot).
- At fetch time, README says "The next release candidate is v1.0.2; the commands below become available after that release is reviewed and published" — i.e., **install instructions reference a release that had not yet shipped**, so real-world install may not work exactly as documented right now.
- Not evaluated for hyprpm.toml pin table or open issues (time did not permit); given 0 stars and <1 month of age, treat as unproven/early despite the precise 0.56.2 pin.
- Not found in AUR (the only "hyprspace" AUR hits were an unrelated libp2p VPN tool `hyprspace-git`, and packages for a different, unrelated "hyprspaces" (plural, by jtaw5649, hosted on GitLab: https://gitlab.com/jtaw5649/Hyprspaces) — a "paired workspace" / waybar-integration tool, not verified to be a Mission-Control-style overview at all; out of scope, flagged only to avoid confusion).

## 10. ThiagoAVicente/hyprexpose — different architecture entirely, arguably out of scope
- Repo: https://github.com/ThiagoAVicente/hyprexpose
- Stats: stars 10, pushed 2026-07-24T08:04:41Z, archived:false, license MIT, language Rust.
- NOT a compositor plugin loaded via `hl.plugin.load` — it's a standalone Rust **daemon** binary, toggled via SIGUSR1, that draws a fullscreen `wlr-layer-shell` overlay and gets real window thumbnails via the `hyprland-toplevel-export` Wayland protocol, talking to Hyprland over its own IPC unix socket. Also supports Sway (auto-detected via SWAYSOCK), falling back to colored rectangles instead of thumbnails there.
- Its own README carries a "vibecoded" badge (self-declared AI-generated codebase) — flag as a real quality/trust signal, not an insult.
- Requires Hyprland >= 0.55 ("uses the Lua-based IPC dispatch introduced in that release").
- Features: workspace grid (not per-window exposé — shows workspaces, like hyprexpo), keyboard nav (arrows/hjkl), move the active window to another workspace with the `m` key (not drag-and-drop, a keypress action), toggled as a daemon (~0% CPU hidden), TOML config for colors/fonts.
- In AUR as `hyprexpose-git` (maintainer "vcnt", first submitted 2026-03-06, last modified 2026-03-31, 0 votes).

## 11. Native Hyprland core (hyprwm/Hyprland) — no built-in overview/exposé
- Checked release notes for tags v0.50.0, v0.51.0, v0.52.0, v0.53.0, v0.54.0, v0.55.0, v0.56.0 via `gh api repos/hyprwm/Hyprland/releases/tags/<tag>` grepping for "overview", "expose"/"exposé", "mission control".
- Only hits were unrelated uses of the word "expose" as a verb in changelog entries (e.g. v0.51.0: "plugins: expose csd functionality (#11551)"; v0.56.0: several "config/lua: expose ... (#nnnn)" entries about exposing APIs to Lua). **No native Mission-Control/overview/exposé feature has been merged into Hyprland core through 0.56.x.** hyprexpo never moved into core — it moved OUT of the official plugin repo entirely (see section 1) and now lives only as third-party forks.

## Could-not-confirm / unverified list
- colonelpanic8/hyprexpo: exact 0.56.2 compatibility (hyprpm.toml pin table not fetched); no issue-tracker scan performed.
- simonwinther/hyprspace: hyprpm.toml pin table and open-issue list not fetched; install path depends on an unreleased v1.0.2 tag per its own README at fetch time.
- yz778/hyprview issue #19 "Possible malicious copy of this repo": closed, but thread content/resolution not fetched — flagged, not confirmed either way.
- cjber/hyprview's claim that plugin dispatchers "cannot be invoked from Lua" — appears contradicted by hyprtasking/sandwichfarm-hyprexpo's demonstrated `hl.plugin.<name>.<fn>()` bindings; not reconciled, needs a live test on this system.
- hycov / KZDKM Hyprspace / colonelpanic8-hyprexpo: no direct build-against-0.56.2 test was performed for any plugin in this research (all conclusions are from README/issue/pin-table evidence only, not compiled).
- "hyprspaces" (jtaw5649, GitLab, AUR: hyprspaces-tools) not evaluated for whether it offers any overview/exposé behavior — noted only to prevent name confusion.
- gh search repos and topic:hyprland-plugin search are not guaranteed exhaustive (GitHub search API caps and ranking); a plugin with no matching keywords/topic could exist unseen.
