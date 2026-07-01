## GameConstants.gd — single source of truth for the fixed virtual game
## resolution. Gameplay logic (GameManager, Player, Enemy, Item, Platform,
## DumpPlatforms) and UI scale references ALL read VW/VH from here.
##
## Nobody else may hardcode 600.0 / 800.0 anywhere in the project — if the
## design resolution ever needs to change, it changes in exactly one place,
## and every consumer (client AND headless server-replay/anti-cheat) stays
## bit-for-bit identical. That guarantee is what keeps replay deterministic.
##
## DETERMINISM CONTRACT — any Node whose position/velocity feeds into a
## tick-based collision check (Player vs Platform, Player vs Enemy, etc.)
## MUST end its simulate_tick() by snapping with snappedf(x, 0.01). Raw
## floats accumulated via sin()/cos()/move_toward() round differently on
## WASM (client) vs native (headless server replay) and drift compounds
## over thousands of ticks, eventually flipping a hit/stomp decision right
## at the boundary and desyncing client/server scores even with identical
## input + identical seed. Player.gd and EnemyBase.gd both implement this —
## any future tick-driven actor (new enemy types, moving hazards, etc.)
## must do the same.
class_name GameConstants
extends RefCounted

const VW := 600.0
const VH := 800.0
