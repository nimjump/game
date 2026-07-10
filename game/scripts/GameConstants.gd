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

## ── Deterministic trig (no engine sin()/cos()/acos(), no literal table) ──
## WHY THIS EXISTS: snappedf(pos, 0.01) (see contract above) hides almost all
## client(WASM)/server(native) float drift, but it is not a mathematical
## guarantee. IEEE-754 only REQUIRES +,-,*,/,sqrt(),round(),floor(),fmod() to
## be correctly-rounded (bit-identical on every conforming implementation).
## sin()/cos()/tan()/acos()/exp()/log() are explicitly NOT covered by that
## guarantee — each libm (glibc on the native headless server vs Emscripten's
## musl-based libm compiled to WASM for the client) is free to implement its
## own polynomial/table approximation, and can legitimately differ by 1 ULP.
## That 1-ULP difference can, on a rare tick, survive the 0.01 snap and flip
## a hit/stomp decision right at its boundary — the leading theoretical
## explanation for a real replay ever desyncing despite every other
## hardening already in place.
## FIX: for the two gameplay-critical, every-tick trig call sites (enemy
## patrol sweep / bob — see EnemyBase.gd _tick_patrol/_tick_bob), don't call
## the engine's sin()/cos()/acos() at all. Compute sin ourselves with a
## Taylor-series polynomial built from only +,-,*,/ — operations IEEE-754
## guarantees are bit-identical on every platform. There is no large table
## to author or trust here: the entire "data" is five small, textbook
## constants (1/3!, 1/5!, 1/7!, 1/9!, 1/11!) that anyone can verify by hand
## in a few seconds, plus the standard sin Taylor series and quadrant
## symmetry identities (sin(pi - x) = sin(x), sin(-x) = -sin(x)) — nothing
## authored/typed in by hand beyond those five reciprocal factorials.
static func _sin_poly(x: float) -> float:
	# Valid for x in [-PI/2, PI/2] (see the range reduction in lut_sin below).
	# sin(x) = x - x^3/3! + x^5/5! - x^7/7! + x^9/9! - x^11/11! + ...
	# Truncating after the x^11 term gives < 6e-8 error at the very edge of
	# this range (x = PI/2) and far less near the center — nowhere close to
	# mattering after the position is snapped to a 0.01 grid, and it's a
	# FIXED, identical-on-every-platform bias (not drift), since it's the
	# same deterministic polynomial evaluated the same way everywhere.
	var x2 := x * x
	return x * (1.0 + x2 * (-1.0 / 6.0 + x2 * (1.0 / 120.0 + x2 * (-1.0 / 5040.0 + x2 * (1.0 / 362880.0 - x2 / 39916800.0)))))
	# coefficients: 1/6=1/3!, 1/120=1/5!, 1/5040=1/7!, 1/362880=1/9!, 1/39916800=1/11!

## Deterministic replacement for sin(phase). Range-reduces to [-PI, PI] with
## fposmod (IEEE-754-guaranteed), then mirrors into [-PI/2, PI/2] using the
## standard quadrant identities so _sin_poly stays inside its accurate range.
static func lut_sin(phase: float) -> float:
	var t : float = fposmod(phase, TAU)
	if t > PI:
		t -= TAU              # now t in (-PI, PI]
	if t > PI * 0.5:
		t = PI - t            # sin(PI - t) == sin(t)
	elif t < -PI * 0.5:
		t = -PI - t           # sin(-PI - t) == sin(t)
	return _sin_poly(t)

## Deterministic replacement for cos(phase) — cos(x) = sin(x + PI/2), reuses
## lut_sin so there is only ever one polynomial to reason about.
static func lut_cos(phase: float) -> float:
	return lut_sin(phase + PI * 0.5)

## Deterministic replacement for acos(cos_val), restricted to [0, PI] (the
## same range acos() itself returns) — exactly the range EnemyBase.gd's
## patrol-resume code needs. Plain bisection using lut_cos (monotonically
## decreasing on [0, PI], so bisection converges to the unique matching
## angle) — only comparisons + arithmetic, no table, no engine acos() call.
## 60 iterations halves the search interval 60 times (PI / 2^60 is many
## orders of magnitude below double precision at this scale), so this
## always converges to full double precision regardless of input — it's
## called once per patrol-resume event, not per tick, so the extra
## iterations cost nothing that matters.
static func lut_acos(cos_val: float) -> float:
	var v : float = clampf(cos_val, -1.0, 1.0)
	var lo : float = 0.0
	var hi : float = PI
	for _i in range(60):
		var mid : float = (lo + hi) * 0.5
		if lut_cos(mid) > v:
			lo = mid
		else:
			hi = mid
	return (lo + hi) * 0.5

## Global movement-speed multiplier applied to every enemy's patrol/chase/
## hover speed (see the speed block in Enemy.gd's setup). Deliberately does
## NOT touch the player — Player.MOVE_SPEED is untouched by design. Single
## knob so a global creature-speed pass stays a one-line change instead of
## touching each creature individually. Purely a multiplier on top of
## already-deterministic (_vw/_vh/difficulty based) formulas, so it does not
## break the client/server replay determinism contract above.
const SPEED_BUFF := 1.10
