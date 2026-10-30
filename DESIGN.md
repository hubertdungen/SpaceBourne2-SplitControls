# Split Controls — design notes

Status: **0.1.0, tested in game on 2026-10-30** (results at the end). The findings come from reading the game's
Blueprints (decompiled locally, not published), its `DefaultInput.ini`, strings in the game
executable and the game's own diagnostics files. Game build checked: 2026-10-26 (UE 4.27,
Enhanced Input), UE4SS 3.0.1.

## Goal

Four independent settings for vertical look: ship gamepad, ship mouse, on-foot gamepad,
on-foot mouse. Defaults: ship gamepad inverted (pull back = nose up), the other three normal.
No cost per frame. The settings must survive level loads, ship/foot switches and key rebinds.

## Findings

### The game's own options

| Option (where) | CVar | What reads it |
|---|---|---|
| "Invert Mouse Y-Axis (Character)" (old settings menu, `Q2_KeyBoard`) | `CInverted` | `ALS_Base.Inverted` |
| "Invert Mouse Y-Axis (Ship)" (old menu) and "Invert mouse (ship)" (new controls screen, EASY > Feel) | `SInverted` | `Q1_Master_Ship.InvertedMouse`, `Master_Misactor.InvertedMouse` |
| "Invert gamepad look" (new controls screen, EASY > Feel) | `GP_Invert` | no Blueprint; the native control system (below) |
| HOTAS invert options | `InvertHotasUp/Right/Roll` | not touched by this mod |

The CVars are AutoSettings settings (`RegisterBoolCVarSettingWithCallback`), saved in
`Saved\Config\WindowsNoEditor\Settings.ini` when changed.

### On foot (`ALS_Base`, parent of the player's `Q1_Character`)

- **Mouse:** the legacy axis mapping `LookUp` = `MouseY` × −1 (`DefaultInput.ini`; no gamepad key
  on it).
- **Stick:** Enhanced Input action `GPC_LookUp` (Axis1D). Its Triggered handler
  (`InpActEvt_GPC_LookUp_K2Node_EnhancedInputActionEvent_16`) stores
  `GamepadYAxis` = value × a ramp-up factor × 0.7 while aiming × 0.1 with a scope × 0.5 while
  flying. The other two handlers (`_15`, `_17`) reset it to 0.
- **Applied in** `InpAxisEvt_LookUp` (every frame):
  `(mouse axis + GamepadYAxis) × (Inverted ? −1 : 1) × rate × 60 × dt × sensitivity`, then
  `AddControllerPitchInput` (or `Fly_LookUp` with the jetpack).
- `Inverted` is written in exactly two places: `ReceiveBeginPlay` (reads `CInverted`, in the
  same frame) and `CustomEvent_4` (the CVar-changed callback).

**So "Invert Mouse Y-Axis (Character)" also inverts the stick on foot.**

### Ships (`Q1_Master_Ship`)

- **Mouse:** `InpAxisKeyEvt_MouseY`: `YAxis = MouseY × (InvertedMouse ? −1 : 1)` (× 0.1 on big
  ships) → `RotationCurve` → `RelativePitch` → SpringArm pitch.
- **Stick:** action `S_Gamepad_LookUp` (Axis1D), Triggered handler `_96`:
  `GamepadYAxis` = value × ramp-up × (0.2 on big ships) × sensitivity → native
  `SB2InputBPBridge.PadTurnRate` → SpringArm pitch (`MakeRotator` pitch, + = nose up). **No
  invert flag at all.**
- `InvertedMouse` is written in `ReceiveBeginPlay` (reads `SInverted`, same frame) and
  `CustomEvent_4`.

**So no game option inverts only the ship stick; the ship mouse option never touches it.**

### Vehicles (`Master_Misactor`, hover bikes)

They get the ship mapping contexts (`UpdateControls(false, true)` adds `Ship` and
`Ship_Gamepad`). `InvertedMouse` comes from `SInverted` through `CustomEvent_4`, which is
called once at BeginPlay and on every change. The stick handler (`_58`) stores
`LookUpValue`.

### Mapping contexts and when they change

- `Q1Controller.UpdateControls(Ship?, Misactor)` removes the other mode's contexts and adds
  `Character` + `CharacterGamepad` (on foot) or `Ship` + `Ship_Gamepad` (ship and vehicles),
  plus `X_Shared`, then calls `RequestRebuildControlMappings(true)`.
  It runs from `ReceivePossess` (every possession: boarding, leaving, level loads) and when
  the pause menu closes (Escape, P, gamepad pause), and from `RefreshControls`.
- Shipped bindings: in `CharacterGamepad`, `GPC_LookUp` ← `HIDJoystick_Axis4` with **one**
  `InputModifierNegate`. In `Ship_Gamepad`, `S_Gamepad_LookUp` ← `HIDJoystick_Axis4`, **no**
  modifier. The `HIDJoystick_*` keys are produced by the game's own input layer, also for
  XInput pads ("PadLegacy: drives the HIDJoystick_* pad keys").
- **Native control system (SB2Controls).** The executable contains a full control system:
  profiles, presets, a setup wizard, EASY/DETAILED/DEVICES screens, CVar `SB2.Input.Profile`,
  diagnostics in `Saved\Diagnostics\SB2Controls.txt`. With a profile active, it **writes every
  binding** (about 213) into the mapping contexts on "Load Inputs", "devices changed" (a
  controller connects or disconnects), "GP_Invert", "bind" and "swap". Its log reports
  "2 with V2 settings" on every apply, which is most likely the two look bindings getting the
  "Invert gamepad look" setting.
- **Live list (seen in game).** Once the native system has laid its profile over the live
  contexts (`SB2.Controls.Apply`, or a device change), the player's live list
  (`PlayerInput.EnhancedActionMappings`) keeps the profile's version of the binding. Neither
  `RequestRebuildControlMappings` nor the game's own `UpdateControls` copies a modifier from
  the context asset into it any more. So the mod edits the live list directly as well.
  Enhanced Input reads that list every frame, so the change takes effect at once.
- Old Blueprint rebind widget (`KeyMappingSlotsGamepad.KeySelected`): `UnmapKey`,
  `UnmapAction`, `MapKey`. The new binding has **no modifiers** (so in vanilla, rebinding the
  on-foot look drops its Negate). It then broadcasts `InputBinded`
  (`Q1Controller.AnyInputChanged`).
- `Game_Builder.EnhancedSave` is never called by any Blueprint. `EnhancedLoad` is called from
  "Load Inputs" and only changes the contexts if an input save exists.
- Negate objects the game ships: `NegativeModifire` (a mapping-context asset that only holds
  one `InputModifierNegate`, referenced by `Q1FunctionLibary.RemapKey`) and
  `GenericInvertAction` (an action that holds one).

### Sign model

- **Assumption S:** the stick key reports a positive value when the stick is pushed up (the
  `Gamepad_RightY` convention). The shipped bindings are consistent with S: one Negate on
  foot and none in the ship give "normal" in both.
- **On foot.** UE scales pitch input by −2.5 (`InputPitchScale`), so a positive input looks
  down. The mouse gives `−MouseY`: mouse up → negative → look up. The stick gives
  `v × (−1)^n × (Inverted ? −1 : 1)`, where n is the number of sign flips on the binding. For
  "normal", stick up must also be negative. The mod therefore wants n **odd** when
  `FootGamepad == FootMouse`, and **even** otherwise:

  | FootGamepad | FootMouse (Inverted) | flips on `GPC_LookUp` |
  |---|---|---|
  | normal | normal | odd (as shipped) |
  | inverted | normal | even |
  | normal | inverted | even |
  | inverted | inverted | odd |

- **Ship.** A positive `GamepadYAxis` pitches the nose up (assuming the native `PadTurnRate`
  keeps the sign). "Normal" (stick up = nose up) wants n **even**; "inverted" wants **odd**.
- **Mouse.** The mod trusts the game's own labels: `Inverted` / `InvertedMouse` = true means
  inverted.
- "Sign flips" counts `InputModifierNegate` (with `bX`) and `InputModifierScalar` with a
  negative X. That way the game's own "Invert gamepad look" is absorbed if it works through
  the bindings.
- If S is wrong, **both** stick settings come out reversed; swapping both fixes it.

## Options considered

1. **Toggle Negate modifiers per mapping context at runtime.** Used for the stick.
   - The split comes for free: on foot and in ships the stick feeds different actions in
     different contexts.
   - Enhanced Input applies the modifier natively, so there is no cost per frame.
   - Counting the flips already present absorbs the game's own invert and its profile
     rewrites.
   - Risk: UE4SS 3.0.1 must be able to grow a `TArray` from Lua (`array[n+1] = obj`). The mod
     reads the binding back **after** the rebuild and falls back to option 3 if the change did
     not stick.
   - Risk: the game rewrites the bindings. Answer: apply on every `UpdateControls` (switches,
     level loads, closing the pause menu) and re-read the few bindings every 5 s.
2. **Flip the game's own invert flag when switching ship/foot.** Used for the mouse only.
   - On foot the flag also multiplies the stick, and in ships there is no stick flag, so this
     alone cannot split the stick.
   - For the mouse it is exact: it is the game's own multiplier.
   - The mod writes the Blueprint variables right after each place the game writes them (the
     BeginPlay hooks and the CVar callbacks), not the CVars. Setting the CVars from the
     console would outrank the settings menu for the rest of the session (console priority),
     and AutoSettings would write it into the player's `Settings.ini`.
3. **Negate the value inside the Blueprint handler.** Fallback only. A post-hook on the
   Triggered handler flips `GamepadYAxis` / `LookUpValue` after the game stored it.
   - It works however the input reaches the action.
   - But it runs Lua every frame while the stick is held (an estimated few tens of µs).
   - `GamepadMethod = "hook"` forces it; `"auto"` (default) uses it only when option 1 fails.

## When the mod acts

| Event | What it does |
|---|---|
| `Q1Controller.UpdateControls` (possession, ship ↔ foot, vehicles, level loads, closing the pause menu, so after rebinds and option changes) | mouse flag on the current pawn; both look bindings set; mappings rebuilt only if something changed |
| `ALS_Base` / `Q1_Character` `ReceiveBeginPlay`, `ALS_Base.CustomEvent_4` | on-foot mouse flag (player only) |
| `Q1_Master_Ship.ReceiveBeginPlay`, `Q1_Master_Ship.CustomEvent_4` | ship mouse flag |
| `Master_Misactor.CustomEvent_4` | vehicle mouse flag |
| every `CheckSeconds` (5 s) | re-reads the context sizes and the few look bindings it set; applies again if the game rewrote them (for example after a controller reconnects) |
| mod loaded while the game already runs | one `FindAllOf("Q1Controller_C")` (~50 ms), once |

The pawn-class hooks are registered the first time `UpdateControls` reports that kind of pawn,
when the class is loaded for sure. Only the controller class is polled, with HTR's backoff.

## Cost (estimates, measure in game)

- **Per frame: nothing** with the mapping method. Every hook is on a rare event.
- `UpdateControls`: two scans of the look action's bindings, about 1–3 ms of Lua, and only at
  possession or when the pause menu closes. Rebuild only when a binding changed.
- Check every 5 s: two context sizes and about two bindings, estimated well under 0.1 ms.
- Controller-class lookup: a miss costs ~37 ms. It happens only until the class is loaded
  (1, 2, 4, 8, 16 s backoff, like HTR, usually at the main menu or a loading screen); after
  that ~0 ms every 10 s.
- Fallback "hook" method: one Lua call per frame while the right stick is held.

## Risks and open questions

1. **TArray growth from UE4SS Lua:** verified in game (appending to a `Modifiers` array works
   and reads back). The runtime check and the fallback stay in place.
2. **Assumption S (the physical stick reports + when pushed up):** the only link not measured
   in game. The ship and on-foot Blueprint signs were measured (see below); the stick itself
   needs the user's two-minute check.
3. **"Invert gamepad look" (`GP_Invert`):** if the native system applies it outside the
   bindings, it adds a flip the mod cannot see. While testing, keep it **off**.
4. **Native profile saving:** if the controls screen saves a profile from the live bindings
   (not from its own overrides), our Negate could end up in the profile. Check after
   uninstalling.
5. **The game seeing a HOTAS as a gamepad:** then `ShipGamepad` also applies to what the game
   binds to ship pitch on it. SB2 HOTAS itself steers the ship directly and is not affected.
6. **Free-look camera views in ships** read the raw mouse, in the game and with the mod.
7. While a mouse setting is `true`/`false`, the game's checkbox for it does nothing (by
   design).

## In-game test plan

Before you start: in the controls screen (EASY > Feel) set **"Invert gamepad look" off**.
Keep `config.lua` at the defaults. HTR and SB2 HOTAS can stay installed. Write down a pass
or fail for every step.

| # | Do | Expect |
|---|---|---|
| 0 | Start the game, load a save on foot, open `Mods\SplitControls\splitcontrols.log` | `=== Split Controls 0.1.0`, `hooked Q1Controller.UpdateControls`, `controls update: foot`, no `WARN`. A line `switching to the "hook" method` means the fallback is active: note it. |
| 1 | On foot, gamepad: push the right stick up, then down | aim goes up, then down |
| 2 | On foot, mouse: move the mouse up, then down | aim up, then down |
| 3 | Jetpack flight: repeat 1 and 2 | same as on foot |
| 4 | Board your ship. Gamepad: pull the stick back (down), then push it up | nose goes **up**, then down (log: `controls update: ship`, `ship gamepad [...]: now inverted`) |
| 5 | Ship, mouse: up, then down | nose up, then down |
| 6 | Leave and board 3 times, repeating 1, 2, 4, 5 | unchanged every time |
| 7 | A hover bike or other vehicle: stick and mouse | like the ship (4 and 5) |
| 8 | **After a level load:** take an elevator to a new floor, load another save, warp to another system. Repeat 1, 2, 4, 5 each time | unchanged |
| 9 | **After a rebind:** old menu, rebind the gamepad look (or any gamepad action), close the menu. Do the same in the new controls screen (DETAILED). Repeat 1 and 4 | unchanged |
| 10 | **Controller reconnect:** in a ship, switch the gamepad off and on (or unplug it) | within ~5 s pull back = nose up again. Log: `the game rewrote the look bindings; applying again` |
| 11 | Toggle the game's "Invert gamepad look" and both mouse invert checkboxes, then close the menu | directions still as in `config.lua` (the mod wins). Put "Invert gamepad look" back off. |
| 12 | Set `FootGamepad = "game"` and `ShipGamepad = "game"`, restart | the stick behaves like vanilla (the game's option decides). Restore the defaults. |
| 13 | **Frame times:** with your usual tool (`stat unit`, `stat fps` or a frame-time overlay), idle on foot, idle in a ship, switch ship ↔ foot, open and close the pause menu. Compare with `Enabled = false` | no extra spikes; at most one small spike when a switch or a menu close also rebuilds the bindings |

If a single direction is wrong, flip that setting and report which one. If **both** stick
directions are wrong, assumption S is wrong: swap both stick settings and report it, so the
defaults can be fixed. Please attach `splitcontrols.log` and `UE4SS.log` to the report.

## In-game test results (2026-10-30)

Automated runs on the Steam install (game build 2026-10-26, UE4SS 3.0.1, HTR installed,
SB2 HOTAS off for clean frame numbers). The save was loaded read-only and the saves were
unchanged afterwards. A dev Lua console read the game state.

| Check | Result |
|---|---|
| Bindings after load | on foot `GPC_LookUp` ← `HIDJoystick_Axis4` with the profile's own Negate (normal, not touched); ship `S_Gamepad_LookUp` ← `HIDJoystick_Axis4` with the mod's Negate (inverted) |
| Load-time rewrite by the game | logged and re-applied within 5 s |
| Boarding (`Q1_Character.BackToShip`) | live list gets the ship Negate; `InvertedMouse` false while the game option was on |
| Ship Blueprint sign | the game's own injection (`SB2.Drive.EI S_Gamepad_LookUp 0.6`) lifts the nose (+0.96): positive = up, as modelled |
| On-foot Blueprint sign | a stored stick value of +0.6 lowers the view by 87°: positive = down, as modelled |
| Mouse on foot | mouse up raised the view (+69°) |
| Game invert option callbacks | on foot and in the ship, the game set "inverted"; the mod put "normal" back at once |
| Native rewrite (`SB2.Controls.Apply`) | first version: the context was restored, but the live list kept no Negate (fixed: the mod edits the live list too). Fixed version: live list restored within 1 s |
| `UpdateControls` (pause menu close) | binding kept |
| Frame times, 30 s each | on foot 104 fps / p99 21 ms / max 28 ms without, 105 / 20 / 22 with; ship 120 / 10 / 20 without, 120 / 10 / 18 with; no periodic spikes |

Not automated: the physical stick (assumption S) and the mouse in the ship (the test could
not bring the game window to the front for `SendInput`). Those are in the README's two-minute
check. With SB2 HOTAS 0.3.0 installed a ~70 ms spike every second shows up with or without
this mod (SB2 HOTAS scans all widgets once a second; fixed in SB2 HOTAS 0.3.2).

## After a game update

Every game name the mod uses is in the `G` block at the top of `scripts/main.lua`. Check that
they still exist (dump `Q1Controller`, `ALS_Base`, `Q1_Character`, `Q1_Master_Ship`,
`Master_Misactor` and the assets in `1Data/1_Keybings`, for example with the `sb2dump` tool of
the [HTR repository](https://github.com/hubertdungen/SpaceBourne2-HardcoreTacticalRealism)). The
`EnhancedInputActionEvent_N` numbers used by the hook method change when the Blueprint is
edited.
