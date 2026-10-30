--[[
  Split Controls - separate vertical look inversion for SpaceBourne 2
  ====================================================================
  USER SETTINGS. Edit with any text editor, then restart the game.
  Delete a line to get its default.

  Each of the four settings takes:
    false   normal:   push up / mouse up = look up / nose up
    true    inverted: pull back / mouse down = look up / nose up (flight style)
    "game"  leave it to the game (its own menu options, vanilla behaviour)

  "Ship" also covers ground vehicles (hover bikes), because the game gives them the ship controls.
]]

return {
    Enabled = true,

    -- Flying a ship
    ShipGamepad = true,   -- right stick: pull back = nose up
    ShipMouse   = false,  -- mouse up = nose up

    -- On foot (and jetpack)
    FootGamepad = false,  -- right stick: push up = aim up
    FootMouse   = false,  -- mouse up = aim up

    -- While a setting is true or false it wins over the game's own options:
    --   mouse:   "Invert Mouse Y-Axis (Character)" / "(Ship)" and "Invert mouse (ship)"
    --   gamepad: "Invert gamepad look" (controls screen, EASY > Feel)
    -- Set it to "game" to use the game's option instead.

    -- How the gamepad settings are applied (see DESIGN.md):
    --   "auto"    edit the game's gamepad look binding (no cost per frame); if UE4SS cannot
    --             edit it, fall back to "hook"
    --   "mapping" only edit the binding
    --   "hook"    flip the stick value right after the game reads it (a tiny cost on every
    --             frame while the right stick is held)
    GamepadMethod = "auto",

    -- The game's own control system rewrites all bindings when a device connects or
    -- disconnects (and on a few other events). Every this many seconds the mod re-reads the
    -- two look bindings it set (a handful of values, well under a millisecond) and applies
    -- again if they were rewritten. 0 = off (then only ship/foot switches and closing the
    -- pause menu apply it).
    CheckSeconds = 5,

    -- SplitControls\splitcontrols.log: what the mod did (a few lines per ship/foot switch).
    -- Cleared at every game start, at most 400 lines.
    Log = true,
}
