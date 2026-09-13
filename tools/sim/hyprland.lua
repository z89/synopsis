-- synopsis headless simulator: config for the NESTED Hyprland instance.
--
-- This config is never loaded by the live session. It is passed explicitly:
--     env -u HYPRLAND_INSTANCE_SIGNATURE -u DISPLAY \
--         WAYLAND_DISPLAY=synopsis-sim-parent \
--         Hyprland -c tools/sim/hyprland.lua
--
-- aquamarine 0.15 has no allocator without a DRM or Wayland parent, so the
-- nested instance runs on the Wayland backend inside a headless parent
-- compositor (weston kiosk, or cage). Its single output is called WAYLAND-1.
--
-- Geometry comes from the environment so run.sh can pick the size:
--   SIM_W / SIM_H  output size (default 1280x720, cage's headless output)
--   SYNOPSIS_REPO  repo root, used to load hypr/synopsis.lua
--
-- Validate with:  luac -p tools/sim/hyprland.lua

-- 1280x720 is cage's fixed headless output size, so it is the default here.
-- With weston --backend=headless any size works (run.sh passes --w/--h).
local SIM_W = tonumber(os.getenv("SIM_W")) or 1280
local SIM_H = tonumber(os.getenv("SIM_H")) or 720
local REPO  = os.getenv("SYNOPSIS_REPO")

hl.monitor({
    output   = "WAYLAND-1",
    mode     = SIM_W .. "x" .. SIM_H .. "@60",
    position = "0x0",
    scale    = 1,
})

hl.config({
    debug = { disable_logs = false },
    general = {
        gaps_in     = 6,
        gaps_out    = 12,
        border_size = 2,

        resize_on_border = false,
        allow_tearing    = false,
        layout           = "dwindle",
    },

    decoration = {
        rounding       = 16,
        rounding_power = 2,

        active_opacity   = 1.0,
        inactive_opacity = 1.0,

        shadow = { enabled = false },
        blur   = { enabled = false },
    },

    animations = {
        enabled = true,
    },

    input = {
        -- no physical devices exist in the nested session; keep focus
        -- purely keyboard/dispatcher driven so the driver is deterministic
        follow_mouse    = 0,
        kb_layout       = "us",
        force_no_accel  = true,
    },

    misc = {
        disable_watchdog_warning = true,
        disable_hyprland_logo     = true,
        disable_splash_rendering  = true,
        force_default_wallpaper   = 0,
        -- hyprland only sends frame callbacks to the focused window; the
        -- overview needs the hidden ones to keep painting for its thumbnails
        render_unfocused_fps      = 1,
    },

    cursor = {
        no_hardware_cursors = true,
    },
})


--------------------
---- ANIMATIONS ----
--------------------
-- Copied verbatim from ~/.config/hypr/hyprland.lua so the simulated
-- transitions have the same timing as the machine under test.

hl.curve("easeOutQuint",    { type = "bezier", points = { {0.23, 1},     {0.32, 1} } })
hl.curve("easeInOutCubic",  { type = "bezier", points = { {0.65, 0.05},  {0.36, 1} } })
hl.curve("linear",          { type = "bezier", points = { {0, 0},        {1, 1} } })
hl.curve("almostLinear",    { type = "bezier", points = { {0.5, 0.5},    {0.75, 1} } })
hl.curve("quick",           { type = "bezier", points = { {0.15, 0},     {0.1, 1} } })
hl.curve("workspaceSwitch", { type = "bezier", points = { {0.51, -0.04}, {0, 1} } })
-- Springs (Hyprland 0.56): mass / stiffness / dampening, macOS-like settle
hl.curve("easy",  { type = "spring", mass = 1, stiffness = 238.1191, dampening = 24.21279333 })
hl.curve("snappy",{ type = "spring", mass = 1, stiffness = 320, dampening = 30 })
hl.curve("gentle",  { type = "spring", mass = 1, stiffness = 110, dampening = 20 })
hl.curve("swift",   { type = "spring", mass = 1, stiffness = 400, dampening = 32 }) -- ~210 ms settle, half of gentle
-- Slightly overdamped (zeta 1.02), so it cannot overshoot or ring no matter how
-- much velocity it inherits. Used by windowsMove below.
hl.curve("settle",  { type = "spring", mass = 1, stiffness = 200, dampening = 29 })

hl.animation({ leaf = "global",        enabled = true, speed = 10,   bezier = "default" })
hl.animation({ leaf = "border",        enabled = true, speed = 5.39, bezier = "easeOutQuint" })
hl.animation({ leaf = "windows",       enabled = true, speed = 4.79, spring = "snappy" })
hl.animation({ leaf = "windowsIn",     enabled = true, speed = 4.1,  spring = "snappy",          style = "popin 87%" })
hl.animation({ leaf = "windowsOut",    enabled = true, speed = 1.49, bezier = "linear",          style = "popin 87%" })
hl.animation({ leaf = "windowsMove",   enabled = true, speed = 4,    spring = "settle" })
hl.animation({ leaf = "fadeIn",        enabled = true, speed = 1.73, bezier = "almostLinear" })
hl.animation({ leaf = "fadeOut",       enabled = true, speed = 1.46, bezier = "almostLinear" })
hl.animation({ leaf = "fade",          enabled = true, speed = 3.03, bezier = "quick" })
hl.animation({ leaf = "layers",        enabled = true, speed = 3.81, spring = "snappy" })
hl.animation({ leaf = "layersIn",      enabled = true, speed = 4,    bezier = "easeOutQuint",    style = "fade" })
hl.animation({ leaf = "layersOut",     enabled = true, speed = 1.5,  bezier = "linear",          style = "fade" })
hl.animation({ leaf = "fadeLayersIn",  enabled = true, speed = 1.79, bezier = "almostLinear" })
hl.animation({ leaf = "fadeLayersOut", enabled = true, speed = 1.39, bezier = "almostLinear" })
hl.animation({ leaf = "workspaces",    enabled = true, speed = 3.5,  spring = "swift",           style = "slide" })
hl.animation({ leaf = "workspacesIn",  enabled = true, speed = 3.5,  spring = "gentle",          style = "slide" })
hl.animation({ leaf = "workspacesOut", enabled = true, speed = 3.5,  spring = "gentle",          style = "slide" })
hl.animation({ leaf = "zoomFactor",    enabled = true, speed = 7,    bezier = "quick" })


----------------------
---- FIXTURE RULES ---
----------------------
-- The driver launches windows with fixed classes so the layout is identical on
-- every run: sim-f1..sim-f4 (+ sim-fv for the video window) float at known

-- Geometry is written as fractions of the output so one table works for cage
-- (1280x720) and for a wide weston output alike; the layout keeps its shape.
-- x, y, w, h are fractions of SIM_W / SIM_H.
local floats = {
    { class = "sim-f1", x = 0.05, y = 0.08, w = 0.41, h = 0.50 },
    { class = "sim-f2", x = 0.27, y = 0.22, w = 0.44, h = 0.42 },  -- overlaps f1, ends above it
    { class = "sim-f3", x = 0.66, y = 0.08, w = 0.30, h = 0.33 },
    { class = "sim-f4", x = 0.70, y = 0.47, w = 0.27, h = 0.36 },
    { class = "sim-fv", x = 0.47, y = 0.58, w = 0.25, h = 0.25 },  -- the mpv test pattern
    { class = "sim-f5", x = 0.09, y = 0.22, w = 0.24, h = 0.31 },  -- ws5
    { class = "sim-f6", x = 0.39, y = 0.33, w = 0.24, h = 0.31 },  -- ws5
}

local function px(frac, total, lo)
    local v = math.floor(frac * total + 0.5)
    if v < lo then v = lo end
    return v
end

for _, f in ipairs(floats) do
    local w = px(f.w, SIM_W, 160)
    local h = px(f.h, SIM_H, 120)
    local x = px(f.x, SIM_W, 0)
    local y = px(f.y, SIM_H, 0)
    if x + w > SIM_W then x = math.max(0, SIM_W - w) end
    if y + h > SIM_H then y = math.max(0, SIM_H - h) end
    local m = { class = "^" .. f.class .. "$" }
    hl.window_rule({ name = f.class .. "-float", match = m, float = true })
    hl.window_rule({ name = f.class .. "-size",  match = m, size = w .. " " .. h })
    hl.window_rule({ name = f.class .. "-move",  match = m, move = x .. " " .. y })
end

-- mpv on wayland may ignore --wayland-app-id on older builds and keep app_id
-- "mpv"; give that class the same treatment so the fixture still looks right.
hl.window_rule({ name = "mpv-float", match = { class = "^mpv$" }, float = true })
hl.window_rule({ name = "mpv-size",  match = { class = "^mpv$" },
                 size = px(0.25, SIM_W, 160) .. " " .. px(0.25, SIM_H, 120) })
hl.window_rule({ name = "mpv-move",  match = { class = "^mpv$" },
                 move = px(0.47, SIM_W, 0) .. " " .. px(0.58, SIM_H, 0) })

-- everything tiled otherwise; stated explicitly so a stray rule cannot float it
hl.window_rule({ name = "sim-tiled", match = { class = "^sim-t" }, float = false })


-------------------------
---- SYNOPSIS ITSELF ----
-------------------------
-- Same entry point the live session uses: binds SUPER + grave, the layer rules,
-- the standing render_unfocused rule and misc.render_unfocused_fps.

if REPO then
    local f = io.open(REPO .. "/hypr/synopsis.lua")
    if f then
        local src = f:read("a")
        f:close()
        local synopsis = load(src, "@synopsis.lua")()
        synopsis.setup({})
    else
        print("sim: cannot open " .. REPO .. "/hypr/synopsis.lua")
    end
else
    print("sim: SYNOPSIS_REPO is unset; synopsis.lua not loaded")
end
