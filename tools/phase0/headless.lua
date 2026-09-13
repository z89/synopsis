-- minimal config for a throwaway hyprland instance used by tests.
-- nothing here touches the real session.
hl.monitor({ output = "HEADLESS-1", mode = "1920x1080@60", position = "0x0", scale = 1 })
hl.bind("SUPER + Q", hl.dsp.exec_cmd("kitty"))
hl.bind("SUPER + M", hl.dsp.exit())
