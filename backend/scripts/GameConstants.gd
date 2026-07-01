## GameConstants.gd — single source of truth for the fixed virtual game
## resolution. Gameplay logic (GameManager, Player, Enemy, Item, Platform,
## DumpPlatforms) and UI scale references ALL read VW/VH from here.
##
## Nobody else may hardcode 600.0 / 800.0 anywhere in the project — if the
## design resolution ever needs to change, it changes in exactly one place,
## and every consumer (client AND headless server-replay/anti-cheat) stays
## bit-for-bit identical. That guarantee is what keeps replay deterministic.
class_name GameConstants
extends RefCounted

const VW := 600.0
const VH := 800.0
