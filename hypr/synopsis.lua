-- synopsis: bind, layer rule and the standing render_unfocused rule.
--
-- Loaded from hyprland.lua the same io.open + load way the colour files and
-- local.lua are (see hyprland.lua load_colours). Not required, so hyprland
-- does not register it for autoreload. Usage in hyprland.lua:
--
--   local synopsis = load(io.open(os.getenv("HOME") .. "/.config/hypr/synopsis.lua"):read("a"))()
--   synopsis.setup({ mod = mainMod })
--
-- opts.mod defaults to "SUPER", opts.key defaults to "grave".
--
-- render_unfocused: hyprland only sends frame callbacks to the active
-- workspace, so a window on a hidden workspace stops painting. This rule
-- enrols every window in the renderer's callback list at map time; synopsis
-- raises misc.render_unfocused_fps while the overview is open so hidden
-- tiles keep moving, then this file's default (1) is what they rest at.

local function setup(opts)
    opts = opts or {}
    local mod = opts.mod or "SUPER"
    local key = opts.key or "grave"

    hl.bind(mod .. " + " .. key, hl.dsp.event("synopsis:toggle"), { desc = "Synopsis" })

    hl.layer_rule({ name = "synopsis", match = { namespace = "^synopsis$" }, no_anim = true, no_screen_share = true })

    -- the wallpaper backdrop sits on the top layer beneath the dms bar: hyprland sorts
    -- a layer's surfaces by descending order and draws them in that sequence
    -- (Renderer.cpp arrangeLayersForMonitor), so a higher order sits beneath
    hl.layer_rule({ name = "synopsis-backdrop", match = { namespace = "^synopsis-backdrop$" }, no_anim = true, no_screen_share = true, order = 1 })

    hl.window_rule({ name = "synopsis-render-unfocused", match = { class = ".*" }, render_unfocused = true })

    hl.config({ misc = { render_unfocused_fps = 1 } })
end

return { setup = setup }
