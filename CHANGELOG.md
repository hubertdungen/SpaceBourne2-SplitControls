# Changelog

## 0.1.1 — 2026-11-06

- **Fixed: a UE4SS crash with many mods** ("Fatal error" in UE4SS.dll, at the main menu or in
  play). Background loops (LoopAsync) run on their own threads without UE4SS's lock, and two mods
  calling ExecuteInGameThread from there at the same moment broke a map UE4SS shares between all
  mods. The once-a-second controller and binding check now runs on the game thread, from the
  HUD's own drawing (new `sc\gametick.lua`, the same file in every mod of the
  set). The crash is gone only once every mod of the set has this change.

## 0.1.0 — 2026-10-30

First release.

- Four independent vertical-look settings: ship gamepad, ship mouse, on-foot gamepad, on-foot
  mouse (`true` / `false` / `"game"`). Defaults: ship stick inverted (pull back = nose up),
  everything else normal. Vehicles follow the ship settings.
- Gamepad: one Negate modifier on the look binding, in the mapping context and in the live
  mapping list. No per-frame cost. Re-applied on ship/foot switches, level loads, pause-menu
  close, and within 5 s after the game's own control system rewrites the bindings.
- Mouse: the game's own invert flags, set right after the game sets them.
- Fallback "hook" method when a binding cannot be edited from Lua.
- Tested in game (see DESIGN.md); frame times equal with and without the mod.
