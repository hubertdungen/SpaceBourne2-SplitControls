--[[
  Split Controls - vertical look inversion split between ship and on foot, gamepad and mouse.
  SpaceBourne 2 (UE 4.27) Lua mod for UE4SS 3.0.1. Findings, design and test results: DESIGN.md.
  (Formerly "SplitInvert".)

  What it changes:
    Gamepad  The game reads the right stick through two Enhanced Input actions: GPC_LookUp
             (on foot) and S_Gamepad_LookUp (ships and vehicles). The mod adds or removes one
             Negate modifier on those bindings, both in the mapping contexts and in the
             player's live mapping list (after the native profile is laid, a rebuild no longer
             copies context modifiers into the live list: seen in game). Enhanced Input then
             applies it natively: no Lua runs per frame.
    Mouse    The game multiplies mouse pitch by its own flags: ALS_Base.Inverted on foot (menu
             option "Invert Mouse Y-Axis (Character)", CVar CInverted) and InvertedMouse on
             ships and vehicles ("(Ship)", CVar SInverted). The mod sets the flag right after
             the game does.
    On foot the game multiplies the stick by the same flag as the mouse, so the on-foot
    binding is chosen with both on-foot settings in mind.

  The game's native control system (SB2Controls, CVar SB2.Input.Profile) rewrites every
  binding from its profile on "Load Inputs", when a device connects or disconnects, when
  "Invert gamepad look" (GP_Invert) changes and after a bind. The mod therefore counts every
  sign flip already on a binding (that includes the game's own invert) and sets the parity it
  needs, and notices rewrites.

  When it acts:
    Q1Controller.UpdateControls  every possession (ship <-> foot, vehicles, level loads) and
                                 every time the pause menu closes, so after a key rebind too
    ReceiveBeginPlay (ALS_Base, Q1_Character, Q1_Master_Ship) and the CustomEvent_4 handlers
                                 the game calls when its invert option changes: mouse flags
    every CheckSeconds (5 s)     re-reads only the look bindings it set (a few elements) and
                                 applies again if the game rewrote them
  Nothing is hooked per frame (except by the "hook" fallback method, see config.lua).
]]

local VERSION = "0.1.1"

-- Game names: the only block to fix after a game update ----------------------------
local G = {}
G.Controller  = "/Game/1Data/Q1Controller.Q1Controller_C"
G.ALSBase     = "/Game/Locomotion/Blueprints/CharacterLogic/ALS_Base.ALS_Base_C"
G.Ship        = "/Game/1Data/SB2Ships/Q1_Master_Ship.Q1_Master_Ship_C"
G.Vehicle     = "/Game/1Data/SB2Ships/Miscator/Master_Misactor.Master_Misactor_C"
G.Player      = "/Game/1Data/Q1_Character.Q1_Character_C"  -- your character (child of ALS_Base)
G.PlayerClass = "Q1_Character_C"
G.Fn = {
    UpdateControls = G.Controller .. ":UpdateControls",     -- (Ship?, Misactor)
    FootBegin      = G.ALSBase .. ":ReceiveBeginPlay",       -- Inverted = CVar CInverted
    PlayerBegin    = G.Player .. ":ReceiveBeginPlay",        -- calls the one above (same frame)
    FootOption     = G.ALSBase .. ":CustomEvent_4",          -- CInverted changed -> Inverted
    ShipBegin      = G.Ship .. ":ReceiveBeginPlay",          -- InvertedMouse = CVar SInverted
    ShipOption     = G.Ship .. ":CustomEvent_4",             -- SInverted changed
    VehicleOption  = G.Vehicle .. ":CustomEvent_4",          -- SInverted (also called at BeginPlay)
    -- "hook" method only: the handlers that store the stick value (Triggered events)
    FootPad        = G.ALSBase .. ":InpActEvt_GPC_LookUp_K2Node_EnhancedInputActionEvent_16",
    ShipPad        = G.Ship .. ":InpActEvt_S_Gamepad_LookUp_K2Node_EnhancedInputActionEvent_96",
    VehiclePad     = G.Vehicle .. ":InpActEvt_S_Gamepad_LookUp_K2Node_EnhancedInputActionEvent_58",
}
G.FootFlag, G.ShipFlag = "Inverted", "InvertedMouse"
G.PadValue = { foot = "GamepadYAxis", ship = "GamepadYAxis", vehicle = "LookUpValue" }
G.Pads = { -- mapping context (as used by Q1Controller.UpdateControls) and look action
    foot = { imc = "/Game/1Data/1_Keybings/Character/ChacaterGamepad/CharacterGamepad.CharacterGamepad",
             action = "/Game/1Data/1_Keybings/Character/ChacaterGamepad/GPC_LookUp.GPC_LookUp" },
    ship = { imc = "/Game/1Data/1_Keybings/Ship/Gamepad/Ship_Gamepad.Ship_Gamepad",
             action = "/Game/1Data/1_Keybings/Ship/Gamepad/S_Gamepad_LookUp.S_Gamepad_LookUp" },
}
-- Sign-flip parity of the shipped bindings (on foot one Negate = normal; ship none = normal).
-- Only used by the "hook" method when a binding cannot be read.
G.VanillaOdd = { foot = true, ship = false }
-- Negate modifiers that ship with the game. The mod only references one, never edits it.
G.Negates = {
    "/Game/1Data/1_Keybings/Ship/NegativeModifire.NegativeModifire:InputModifierNegate_0",
    "/Game/1Data/1_Keybings/Ship/Gamepad/GenericInvertAction.GenericInvertAction:InputModifierNegate_0",
}
G.Statics       = "/Script/Engine.Default__GameplayStatics"
G.SubsystemLib  = "/Script/Engine.Default__SubsystemBlueprintLibrary"
G.InputSubsys   = "/Script/EnhancedInput.EnhancedInputLocalPlayerSubsystem"

-- Folder and log --------------------------------------------------------------------
local DIR
do -- UE4SS may report the path as ...\Scripts\ or ...\scripts\
    local src = debug.getinfo(1, "S").source:gsub("^@", "")
    local cut
    for i in src:lower():gmatch("()[\\/]scripts[\\/]") do cut = i end
    DIR = cut and src:sub(1, cut) or ".\\Mods\\SplitControls\\"
end
local LOGFILE, LOG_MAX = DIR .. "splitcontrols.log", 400
local logOn, logLines = true, 0

local function log(msg)
    if not logOn or logLines >= LOG_MAX then return end
    logLines = logLines + 1
    local f = io.open(LOGFILE, "a")
    if f then
        f:write(os.date("%H:%M:%S "), msg, "\n")
        if logLines == LOG_MAX then f:write("(log full; restart the game for a new one)\n") end
        f:close()
    end
end

local function warn(msg)
    print("[SplitControls] " .. msg .. "\n")
    log("WARN " .. msg)
end
-- Timed work on the game thread (gametick.lua, the set's shared file). No LoopAsync (UE4SS crash).
local GT = require("sc.gametick")
GT.log = function(msg) warn(msg) end

-- Settings --------------------------------------------------------------------------
local defaults = { Enabled = true, ShipGamepad = true, ShipMouse = false, FootGamepad = false, FootMouse = false,
    GamepadMethod = "auto", CheckSeconds = 5, Log = true }
local okCfg, cfg = pcall(require, "config")
local cfgError = nil
if not okCfg or type(cfg) ~= "table" then cfgError, cfg = tostring(cfg), {} end
for k, v in pairs(defaults) do if cfg[k] == nil then cfg[k] = v end end
logOn = cfg.Log ~= false
if logOn then
    local f = io.open(LOGFILE, "w") -- a fresh log every game start
    if f then f:close() end
end
if cfgError then warn("config.lua could not be read (" .. cfgError .. "); using defaults") end

for _, k in ipairs({ "ShipGamepad", "ShipMouse", "FootGamepad", "FootMouse" }) do
    local v = cfg[k]
    if type(v) == "string" then v = v:lower() end
    if v ~= true and v ~= false and v ~= "game" then
        warn(k .. " must be true, false or \"game\"; using the default")
        v = defaults[k]
    end
    cfg[k] = v
end
local method = tostring(cfg.GamepadMethod):lower()
if method ~= "auto" and method ~= "mapping" and method ~= "hook" then
    warn("GamepadMethod must be \"auto\", \"mapping\" or \"hook\"; using \"auto\"")
    method = "auto"
end
local checkEvery = tonumber(cfg.CheckSeconds) or defaults.CheckSeconds
if checkEvery < 0 then checkEvery = 0 elseif checkEvery > 0 and checkEvery < 1 then checkEvery = 1 end

local function word(v) return v == "game" and "game" or (v and "inverted" or "normal") end
log(string.format("=== Split Controls %s | ship: pad %s, mouse %s | foot: pad %s, mouse %s | method %s",
    VERSION, word(cfg.ShipGamepad), word(cfg.ShipMouse), word(cfg.FootGamepad), word(cfg.FootMouse), method))
if cfg.Enabled == false then
    log("Enabled = false: the mod does nothing")
    return
end

-- Helpers ---------------------------------------------------------------------------
local function valid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end
local function get(o, k)
    local ok, v = pcall(function() return o[k] end)
    if ok then return v end
end
local function set(o, k, v) return (pcall(function() o[k] = v end)) end
local function addr(o)
    if o == nil then return nil end
    local ok, a = pcall(function() return o:GetAddress() end)
    return ok and a or nil
end
local function className(o)
    local ok, n = pcall(function() return o:GetClass():GetFName():ToString() end)
    return ok and n or "?"
end
local function pathOf(o) -- "/Game/...Name" (GetFullName without the class in front)
    local ok, n = pcall(function() return o:GetFullName() end)
    return ok and n:match("^%S+%s+(.+)$") or nil
end

-- A StaticFindObject that finds nothing costs ~37 ms in this game (one that finds costs ~0),
-- so a miss is not repeated for a minute. Everything looked up here is loaded by the time
-- the mod needs it.
local missUntil = {}
local function find(path)
    local now = os.clock()
    if (missUntil[path] or 0) > now then return nil end
    local o = StaticFindObject(path)
    if valid(o) then return o end
    missUntil[path] = now + 60
    log("not loaded: " .. path)
    return nil
end

-- Hooks: post-hooks on Blueprint functions only (UE4SS runs the callback after the
-- Blueprint body). A callback that keeps failing switches itself off.
local hooked = {} -- function path -> address of its class when hooked
local function hook(path, fn, tag)
    local a = addr(find(path:match("^(.-):")))
    if not a or hooked[path] == a then return end
    local errors = 0
    local ok, err = pcall(RegisterHook, path, function(...)
        if errors >= 20 then return end
        local okCall, e = pcall(fn, ...)
        if not okCall then
            errors = errors + 1
            if errors <= 3 then warn("error in " .. tag .. ": " .. tostring(e)) end
            if errors == 20 then warn(tag .. " switched off after repeated errors") end
        end
    end)
    if ok then
        hooked[path] = a
        log("hooked " .. tag)
    else
        warn("could not hook " .. path .. ": " .. tostring(err))
    end
end

-- "foot", "ship" or "vehicle" from the object's Blueprint parents. Second result false when
-- the class chain could not be read at all.
local KIND = { [G.ALSBase] = "foot", [G.Ship] = "ship", [G.Vehicle] = "vehicle" }
local function kindOf(o)
    local ok, kind = pcall(function()
        local c = o:GetClass()
        for _ = 1, 20 do
            if not valid(c) then return nil end
            local k = KIND[pathOf(c) or ""]
            if k then return k end
            c = c:GetSuperStruct()
        end
    end)
    return ok and kind or nil, ok
end

-- Mouse -----------------------------------------------------------------------------
local gameFoot = false -- the game's on-foot option (CInverted), as last seen

local function footMouseInverted()
    if cfg.FootMouse == "game" then return gameFoot end
    return cfg.FootMouse
end

-- obj: a character ("foot") or a ship/vehicle. gameValue: the value the game just set from
-- its option, when known.
local function setMouse(obj, kind, gameValue, quiet)
    local flag = kind == "foot" and G.FootFlag or G.ShipFlag
    local want = kind == "foot" and cfg.FootMouse or cfg.ShipMouse
    local current = get(obj, flag)
    if kind == "foot" then
        if type(gameValue) == "boolean" then gameFoot = gameValue
        elseif want == "game" and type(current) == "boolean" then gameFoot = current end
    end
    if want == "game" or type(current) ~= "boolean" or current == want then return end
    set(obj, flag, want)
    if not quiet then
        log(string.format("%s mouse: game had %s, now %s", kind, word(current), word(get(obj, flag))))
    end
end

-- Gamepad ---------------------------------------------------------------------------
-- Sign model (DESIGN.md): the stick reports + when pushed up. On foot the game adds the
-- stick to the mouse, multiplies both by Inverted and calls AddControllerPitchInput, so
-- "normal" needs an odd number of sign flips on the binding while Inverted is false. In
-- ships a positive value pitches the nose up, so "normal" needs an even number.
local pad = {
    method = method == "hook" and "hook" or "mapping", -- in use now ("auto" starts with mapping)
    flip = { foot = false, ship = false },              -- "hook" method: negate the stick value
    appendWorks = false, -- an append was read back, so our Negate can also be taken out again
    seen = {},           -- "asset"/"live" .. channel: binding indices, list size, parity left behind
    lastKind = nil,      -- pawn kind at the last controls update (its classes are loaded)
    ctrlPath = nil,      -- the player controller, found again by path for the periodic check
    fixes = {},          -- times the game rewrote the bindings (to notice a fight)
}
local subsysPath = nil -- the Enhanced Input subsystem, to rebuild from the periodic check

local function wantOdd(ch)
    if ch == "ship" then
        if cfg.ShipGamepad == "game" then return nil end
        return cfg.ShipGamepad
    end
    if cfg.FootGamepad == "game" then return nil end
    return cfg.FootGamepad == footMouseInverted()
end

-- Modifiers that flip a 1D axis: Negate (bX) and Scalar with a negative X.
local function flipsSign(o)
    if not valid(o) then return false end
    local cn = className(o)
    if cn == "InputModifierNegate" then return get(o, "bX") ~= false end
    if cn == "InputModifierScalar" then
        local ok, x = pcall(function() return o.Scalar.X end)
        return ok and type(x) == "number" and x < 0
    end
    return false
end

local function isOdd(mods)
    local n = 0
    for j = 1, mods:GetArrayNum() do
        if flipsSign(mods[j]) then n = n + 1 end
    end
    return n % 2 == 1
end

local function negateObj()
    for _, p in ipairs(G.Negates) do
        local o = find(p)
        if valid(o) and className(o) == "InputModifierNegate" and get(o, "bX") ~= false then return o end
    end
end

local function keyName(m)
    local ok, k = pcall(function() return m.Key.KeyName:ToString() end)
    return ok and k or "?"
end

-- The bindings of an action inside a mappings array: { {i = index, mods = Modifiers array,
-- key = key name}, ... } and the array's size.
local function collect(maps, action)
    local want, list = addr(action), {}
    local count = maps:GetArrayNum()
    for i = 1, count do
        local m = maps[i]
        if addr(get(m, "Action")) == want then
            list[#list + 1] = { i = i, mods = m.Modifiers, key = keyName(m) }
        end
    end
    return list, count
end

-- Two places hold the look bindings:
--   "asset": the mapping context the game adds (CharacterGamepad / Ship_Gamepad). Enhanced
--            Input copies it into the live list on every rebuild.
--   "live":  the player's own list (PlayerInput.EnhancedActionMappings), read every frame. The
--            game's native control profile writes it directly when it lays its profile over
--            the live contexts, and a rebuild then does not bring the asset's modifiers back.
-- pc: the player controller (only needed for "live"). nil when not loaded / not available.
local function bindings(ch, where, pc)
    local action = find(G.Pads[ch].action)
    if not action then return nil end
    if where == "live" then
        if not valid(pc) then return nil end
        return collect(pc.PlayerInput.EnhancedActionMappings, action)
    end
    local imc = find(G.Pads[ch].imc)
    if not imc then return nil end
    return collect(imc.Mappings, action)
end

local function scan(ch, where, pc)
    local ok, list, count = pcall(bindings, ch, where, pc)
    if ok then return list, count end
    warn(ch .. " gamepad: could not read the " .. where .. " bindings: " .. tostring(list))
end

local function oddOf(list) -- true/false when all bindings agree; nil if none or mixed
    if not list or #list == 0 then return nil end
    local first = isOdd(list[1].mods)
    for k = 2, #list do
        if isOdd(list[k].mods) ~= first then return nil end
    end
    return first
end

local function keysOf(list)
    local t = {}
    for k, b in ipairs(list or {}) do t[k] = b.key end
    return table.concat(t, ", ")
end

-- Add our Negate, or take it out again if it is there. UE4SS arrays have no RemoveAt, so
-- taking out = rebuild the array without it (only once appending is known to work).
local function flipOne(mods, neg)
    local count, mine, na = mods:GetArrayNum(), nil, addr(neg)
    for j = 1, count do
        if addr(mods[j]) == na then mine = j; break end
    end
    if mine and pad.appendWorks then
        local keep = {}
        for j = 1, count do
            local o = mods[j]
            if j ~= mine and valid(o) then keep[#keep + 1] = o end
        end
        mods:Empty()
        for j, o in ipairs(keep) do mods[j] = o end
    else
        mods[count + 1] = neg
    end
end

-- Returns true if a binding was changed.
local function fixChannel(list, want)
    if #list == 0 then return false end
    local neg = negateObj()
    if not neg then error("no Negate modifier found in the game files") end
    local changed = false
    for _, b in ipairs(list) do
        if isOdd(b.mods) ~= want then
            flipOne(b.mods, neg)
            changed = true
        end
    end
    return changed
end

-- ctx: a live object in the world (preferred), or nil to use the subsystem found before.
local function rebuild(ctx)
    local ok, err = pcall(function()
        local sub
        if ctx then
            local pc = find(G.Statics):GetPlayerController(ctx, 0)
            sub = find(G.SubsystemLib):GetLocalPlayerSubSystemFromPlayerController(pc, find(G.InputSubsys))
        elseif subsysPath then
            sub = find(subsysPath)
        end
        if not valid(sub) then error("Enhanced Input subsystem not found") end
        subsysPath = pathOf(sub) -- lives as long as the game window (the local player)
        sub:RequestRebuildControlMappings(true)
    end)
    if ok then log("Enhanced Input mappings rebuilt") else warn("could not rebuild input mappings: " .. tostring(err)) end
end

local hookPads -- defined below
local warnedMapping = false

local function fallBack(reason)
    if pad.method ~= "mapping" then return end
    if method == "auto" then
        warn(reason .. "; switching to the \"hook\" method")
        pad.method = "hook"
    elseif not warnedMapping then
        warnedMapping = true
        warn(reason .. "; try GamepadMethod = \"hook\" in config.lua")
    end
end

-- Make the on-foot and ship look bindings match the settings.
local CHANNELS, PLACES = { "foot", "ship" }, { "asset", "live" }

-- The player controller: the one UpdateControls handed us, or found again by its path (a path
-- that no longer resolves is dropped, so a stale one costs one failed lookup at most).
local function controllerFor(ctx)
    if valid(ctx) then return ctx end
    if not pad.ctrlPath then return nil end
    local pc = StaticFindObject(pad.ctrlPath)
    if valid(pc) then return pc end
    pad.ctrlPath = nil
    return nil
end

-- Make the on-foot and ship look bindings match the settings: first in the contexts (what the
-- next rebuild copies), then, after the rebuild, in the live list (what the game reads now).
-- ctx: the player controller, or nil (periodic check).
local function ensurePads(ctx)
    local pc = controllerFor(ctx)
    local edited = {}
    if pad.method == "mapping" then
        for _, where in ipairs(PLACES) do
            for _, ch in ipairs(CHANNELS) do
                local want, list = wantOdd(ch), nil
                if want ~= nil then list = scan(ch, where, pc) end
                if list then
                    local ok, res = pcall(fixChannel, list, want)
                    if not ok then
                        fallBack(ch .. " gamepad " .. where .. " binding could not be edited (" .. tostring(res) .. ")")
                    elseif res then
                        edited[where .. ch] = true
                    end
                end
            end
            if where == "asset" and (edited.assetfoot or edited.assetship) then rebuild(pc) end
        end
    end
    -- Read everything back: the game could have rewritten it meanwhile.
    for _, ch in ipairs(CHANNELS) do
        local want = wantOdd(ch)
        for _, where in ipairs(PLACES) do
            local key, list, count, odd = where .. ch, nil, nil, nil
            if want ~= nil then
                list, count = scan(ch, where, pc)
                odd = oddOf(list)
            end
            if want ~= nil and pad.method == "mapping" and list and #list > 0 and odd ~= want then
                fallBack(ch .. " gamepad " .. where .. " binding did not keep the change")
            elseif edited[key] and odd == want then
                pad.appendWorks = true
                log(string.format("%s gamepad, %s [%s]: now %s", ch, where, keysOf(list),
                    word(ch == "ship" and cfg.ShipGamepad or cfg.FootGamepad)))
            end
            pad.seen[key] = nil -- only channels the mod manages are watched
            if list then
                local idx = {}
                for k, b in ipairs(list) do idx[k] = b.i end
                pad.seen[key] = { idx = idx, count = count, odd = odd }
            end
        end
        pad.flip[ch] = false
        if want ~= nil and pad.method == "hook" then
            -- what the game reads: the live list when this channel is active, else the context
            local o
            local live, asset = pad.seen["live" .. ch], pad.seen["asset" .. ch]
            if live and #live.idx > 0 then o = live.odd end
            if o == nil and asset then o = asset.odd end
            if o == nil then o = G.VanillaOdd[ch] end
            pad.flip[ch] = o ~= want
        end
    end
    if (pad.flip.foot or pad.flip.ship) and pad.lastKind then hookPads(pad.lastKind) end
end

-- True while the bindings still look as the mod left them. Cheap: re-reads only those few
-- elements (the game's control profile rewrites them when a device connects, for example).
local function unchanged(ch, where, pc)
    local s = pad.seen[where .. ch]
    if not s then return true end
    local action = find(G.Pads[ch].action)
    if not action then return true end
    local maps
    if where == "live" then
        if not valid(pc) then return true end
        maps = pc.PlayerInput.EnhancedActionMappings
    else
        local imc = find(G.Pads[ch].imc)
        if not imc then return true end
        maps = imc.Mappings
    end
    if maps:GetArrayNum() ~= s.count then return false end
    local a = addr(action)
    for _, i in ipairs(s.idx) do
        local m = maps[i]
        if addr(get(m, "Action")) ~= a then return false end
        if s.odd ~= nil and isOdd(m.Modifiers) ~= s.odd then return false end
    end
    return true
end

local nextCheck = 0
local function periodicCheck(now)
    if checkEvery <= 0 or now < nextCheck or next(pad.seen) == nil then return end
    nextCheck = now + checkEvery
    local ok, same = pcall(function()
        local pc = controllerFor(nil)
        for _, ch in ipairs(CHANNELS) do
            for _, where in ipairs(PLACES) do
                if not unchanged(ch, where, pc) then return false end
            end
        end
        return true
    end)
    if not ok then
        checkEvery = 0
        warn("the binding check failed (" .. tostring(same) .. "); periodic check stopped")
        return
    end
    if same then return end
    local recent = {}
    for _, t in ipairs(pad.fixes) do
        if now - t < 60 then recent[#recent + 1] = t end
    end
    recent[#recent + 1] = now
    pad.fixes = recent
    if #recent > 6 and pad.method == "mapping" then
        fallBack("the game keeps rewriting the gamepad bindings")
        if pad.method == "mapping" then -- "mapping" forced in config.lua: stop fighting
            checkEvery = 0
            warn("periodic check stopped")
            return
        end
    end
    log("the game rewrote the look bindings; applying again")
    ensurePads(nil)
end

-- "hook" method: negate the value the game just stored from the stick.
local function flipper(ch, prop)
    return function(self)
        if not pad.flip[ch] then return end
        local o = self:get()
        o[prop] = -o[prop]
    end
end

-- Registering from inside a hook callback is avoided: queue it for the next game-thread tick.
-- Only classes known to be loaded (the current pawn's kind) are looked up.
hookPads = function(kind)
    ExecuteInGameThread(function()
        if kind == "foot" and pad.flip.foot then
            hook(G.Fn.FootPad, flipper("foot", G.PadValue.foot), "on-foot stick (hook method)")
        elseif kind == "ship" and pad.flip.ship then
            hook(G.Fn.ShipPad, flipper("ship", G.PadValue.ship), "ship stick (hook method)")
        elseif kind == "vehicle" and pad.flip.ship then
            hook(G.Fn.VehiclePad, flipper("ship", G.PadValue.vehicle), "vehicle stick (hook method)")
        end
    end)
end

-- Event handlers --------------------------------------------------------------------
local function onFootBegin(self)
    local o = self:get()
    if className(o) ~= G.PlayerClass then return end -- NPCs share ALS_Base
    setMouse(o, "foot", get(o, G.FootFlag))
end

local function onFootOption(self, newValue)
    local o = self:get()
    if className(o) ~= G.PlayerClass then return end
    setMouse(o, "foot", newValue:get())
end

local function onShipEvent(self)
    local o = self:get()
    local ok, mine = pcall(function() return o:IsPlayerControlled() end)
    setMouse(o, "ship", nil, not (ok and mine)) -- every ship gets the flag; only yours is logged
end

local function onVehicleOption(self)
    setMouse(self:get(), "vehicle")
end

-- isPlayer: the pawn is your Q1_Character (so that class is loaded and can be hooked too).
local function hookClass(kind, isPlayer)
    ExecuteInGameThread(function()
        if kind == "foot" then
            hook(G.Fn.FootBegin, onFootBegin, "on-foot BeginPlay")
            hook(G.Fn.FootOption, onFootOption, "on-foot invert option")
            if isPlayer then hook(G.Fn.PlayerBegin, onFootBegin, "player BeginPlay") end
        elseif kind == "ship" then
            hook(G.Fn.ShipBegin, onShipEvent, "ship BeginPlay")
            hook(G.Fn.ShipOption, onShipEvent, "ship invert option")
        elseif kind == "vehicle" then
            hook(G.Fn.VehicleOption, onVehicleOption, "vehicle invert option")
        end
    end)
end

-- ctrl: the player controller. hint: kind from UpdateControls' parameters.
local function onControls(ctrl, why, hint)
    local pawn = get(ctrl, "Pawn")
    local kind
    if valid(pawn) then
        local k, readable = kindOf(pawn)
        kind = k
        if not readable then kind = hint end
    end
    pad.lastKind = kind
    pad.ctrlPath = pathOf(ctrl)
    if kind then
        setMouse(pawn, kind)
        hookClass(kind, className(pawn) == G.PlayerClass)
    end
    ensurePads(ctrl)
    log(why .. ": " .. (kind or "other pawn"))
end

local function onUpdateControls(self, ship, vehicle)
    local s, v = ship and ship:get(), vehicle and vehicle:get()
    onControls(self:get(), "controls update", s and "ship" or (v and "vehicle" or "foot"))
end

-- Once a second on the game thread:
--  * wait for the controller class: a class that is not loaded costs ~37 ms per look, so
--    the pause grows 1, 2, 4, 8, 16 s; once found it is re-checked every 10 s for ~0 ms
--  * every CheckSeconds, notice when the game rewrote the look bindings
local nextTry, retry, firstDone = 0, 1, false
-- On the game thread, pumped by the HUD's drawing (gametick.lua); started after
-- each load or possession (ClientRestart). Until 0.1.0 this was LoopAsync + ExecuteInGameThread:
-- from UE4SS's async thread that writes a map all mods share without a lock, and two mods at once
-- crashed the game (UE4SS.dll+0x87c104).
GT.drive(GT.HUD_TICK, "hud") -- the player's HUD drawing: once per frame, on foot and in ships
GT.boot()
GT.every(1.0, function(now)
    local ok, err = pcall(periodicCheck, now)
    if not ok then warn("binding check: " .. tostring(err)) end
    if now < nextTry then return end
    ok, err = pcall(function()
        local c = StaticFindObject(G.Controller)
        if valid(c) then
            nextTry, retry = now + 10, 1
            if hooked[G.Fn.UpdateControls] ~= addr(c) then
                hook(G.Fn.UpdateControls, onUpdateControls, "Q1Controller.UpdateControls")
                if not firstDone then
                    -- The game may already be running (mod loaded late): apply once now.
                    -- One object scan (~50 ms), once per session.
                    firstDone = true
                    for _, pc in ipairs(FindAllOf("Q1Controller_C") or {}) do
                        if valid(pc) and not (pathOf(pc) or "Default__"):find("Default__", 1, true) then
                            onControls(pc, "start")
                            break
                        end
                    end
                end
            end
        else
            nextTry, retry = now + retry, math.min(retry * 2, 16)
        end
    end)
    if not ok then warn("controller check: " .. tostring(err)) end
end)
