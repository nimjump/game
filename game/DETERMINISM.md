# Determinism rules — NimJump Godot client

Every game session is recorded on the client (real-time, WASM/JS in a browser)
and re-simulated on the server (headless native Godot, fast-forwarded in one
burst). **These two runs must produce the exact same score.** If they don't,
the session gets flagged and the player's score is rejected.

This document is the checklist for writing new gameplay code without
breaking that. It's paired with two automated gates in the admin panel
(System tab) that catch violations before they ship:

- **Static Determinism Lint** — scans every `.gd` file for the code patterns
  below and flags any new occurrence. Silence a confirmed-safe line with a
  trailing `# determinism-ok` comment (see examples throughout this doc).
- **Golden Replay Self-Test** — re-runs a set of pinned reference replays
  through the current binary and checks the score matches exactly (zero
  tolerance). Run this after any gameplay code change or binary upload.

Neither tool replaces reading this doc — they catch mistakes, they don't
prevent you from writing subtly-wrong code that happens to match a regex.

---

## Rule 1 — Gameplay randomness goes through `_rng`, never the engine's global RNG

Godot's global `randf()`/`randi()`/`randomize()` draw from a single shared,
unseeded stream. It cannot be reproduced identically on the server. Any
randomness that affects score, position, spawns, or item drops **must**
come from a `RandomNumberGenerator` that was seeded from `game_seed` at
session start.

```gdscript
# ❌ WRONG — global RNG, not reproducible
var outcome = outcomes[randi() % outcomes.size()]

# ✅ RIGHT — seeded, deterministic
var outcome = outcomes[_rng.randi() % outcomes.size()]
```

Cosmetic-only randomness (particle scatter, ghost trail jitter, screen
shake) should use `_visual_rng` / `_shake_rng` instead of `_rng` — same
principle (never the global RNG), but kept on a **separate stream** so a
visual effect can never accidentally consume a random value the gameplay
logic was counting on next.

```gdscript
# ✅ visual-only — separate stream, never affects score/physics
var angle = _visual_rng.randf_range(0.0, TAU)
```

If you genuinely need the global RNG (e.g. generating `game_seed` itself,
or decoy/anti-cheat obfuscation data that's never sent to the server),
mark the line so the lint doesn't flag it — and explain why in a comment:

```gdscript
var _mask = randi() | 1  # determinism-ok: obfuscation-only, never sent to server / never replayed
```

## Rule 2 — No wall-clock time in gameplay logic

`Time.get_unix_time_from_system()`, `Time.get_ticks_msec()`,
`Time.get_ticks_usec()`, `OS.get_unix_time()`, `OS.get_ticks_msec()` all
read the real-world clock. The server replay runs the whole session in one
fast-forwarded burst — its wall-clock reads will never line up with what
the client saw during the original real-time session.

```gdscript
# ❌ WRONG — powerup duration driven by wall clock
if Time.get_ticks_msec() - _powerup_start_ms > 5000: ...

# ✅ RIGHT — driven by the fixed-tick timer, decremented every simulate_tick()
powerup_timer -= delta   # delta is always 1.0/60.0 inside simulate_tick()
if powerup_timer <= 0.0: ...
```

Safe uses: UI countdown labels, auth token expiry checks, network-request
timestamps, toast spam-cooldowns — none of that is replayed, so wall clock
is fine there. Mark it:

```gdscript
var now_ts := int(Time.get_unix_time_from_system())  # determinism-ok: UI countdown label only
```

## Rule 3 — All physics-affecting positions get snapped every tick

`sin()`/`cos()`/`sqrt()` and friends can round differently in the last bit
between the client's WASM/JS math and the server's native libm. On their
own those differences are microscopic — but accumulated over thousands of
ticks, or landing right on a collision-boundary comparison, they can flip a
hit/miss decision and desync the whole rest of the run.

**Every node whose position affects gameplay (collision, scoring, "did the
player touch this") must snap its position to a fixed grid at the end of
its per-tick update** — this is a self-correcting quantization: it stops
tiny float drift from ever accumulating past the snap resolution, on both
sides identically.

```gdscript
# End of every simulate_tick() / tick-based movement function that touches
# global_position or velocity for something gameplay-relevant:
global_position.x = snappedf(global_position.x, 0.01)
global_position.y = snappedf(global_position.y, 0.01)
```

Already applied in `Player.gd` (`simulate_tick`) and `EnemyBase.gd`
(`_tick_player_overlap` pipeline). **Any new enemy type, moving hazard, or
interactable that has its own position-update loop must add this too** —
copy the pattern from `EnemyBase.gd`, don't reinvent it.

Purely cosmetic sin/cos (particle spawn angles, screen shake, camera drift)
does NOT need snapping — it never touches a collision check. Keep it gated
behind `if _is_headless: return` so it doesn't even run on the server (no
correctness impact, but no reason to burn CPU on invisible particles
either).

## Rule 4 — `queue_free()`, never `.free()`, for anything another object might reference

A hard `.free()` destroys the node immediately. If anything else still
holds a live reference — a signal connection, a captured lambda (e.g. a
platform's `platform_broke` callback capturing the enemy standing on it) —
touching that reference after the free() is a use-after-free. Best case:
Godot logs a "freed object" warning. Worst case: a native crash
(`0xC0000005` / `STATUS_ACCESS_VIOLATION` on Windows) that kills the whole
headless replay process mid-simulation.

```gdscript
# ❌ WRONG — anything holding a reference to `plat` can crash on next access
plat.free()

# ✅ RIGHT — destruction deferred to end of frame, safe even if something
#            else touches it in between. Still runs every tick in headless
#            mode, so it costs nothing functionally.
plat.queue_free()
```

This is the exact bug that was found and fixed in
`GameManager._discard_node()` — read the comment there for the full
post-mortem before "optimizing" a `queue_free()` back into a `free()`.

If a `.free()` is confirmed reachable only from client-only UI code (never
from `--server-replay`/`--server-worker`), mark it — but verify that
carefully first, ideally by tracing the call path back to `_ready()`:

```gdscript
node.free()  # determinism-ok: client-only UI teardown, never runs headless
```

## Rule 5 — Never mutate an array while iterating over it with `for x in array:`

```gdscript
# ❌ WRONG — undefined behavior, can skip elements or crash
for plat in _platforms:
    if should_remove(plat):
        _platforms.erase(plat)

# ✅ RIGHT — reverse index loop, safe to remove while iterating
for i in range(_platforms.size() - 1, -1, -1):
    if should_remove(_platforms[i]):
        _platforms.remove_at(i)
```

Every removal loop in `GameManager._manage_platforms()` already follows
this pattern — copy it for any new spawn/despawn logic instead of writing
a fresh `for x in array:` loop that removes from the same array.

## Rule 6 — Gate all non-simulation work behind `_is_headless`

Tweens, particle spawns, animation playback, camera effects, audio — none
of it should run during server replay. It's wasted CPU at best; at worst it
creates nodes/tweens that themselves need cleanup and can interact badly
with the fast-forwarded tick loop.

```gdscript
static var _is_headless : bool = (DisplayServer.get_name() == "headless")

func _spawn_dust() -> void:
    if _is_headless: return
    ...
```

Every new visual/audio effect function should start with this guard —
follow the existing pattern in `Player.gd`/`EnemyBase.gd`/`Item.gd`.

## Rule 7 — Fixed tick, not `delta` from `_process`/`_physics_process`

Gameplay state only ever advances through `simulate_tick()`, called with a
**constant** `delta := 1.0 / 60.0` — never the variable `delta` that
`_physics_process(delta)` receives from the engine (that one reflects real
frame timing and varies by hardware/frame-rate, which the server replay
doesn't reproduce). `_physics_process` itself is reserved for purely visual
per-frame updates (already gated by Rule 6).

```gdscript
func simulate_tick() -> void:
    const delta := 1.0 / 60.0   # fixed — same on client and server, always
    ...

func _physics_process(delta: float) -> void:
    if _is_headless: return   # visual-only — real delta is fine here
    ...
```

---

## When the lint flags something

1. Read the message — it explains *why* that pattern is risky, not just
   *that* it matched.
2. Decide: is this actually gameplay-affecting, or is it UI/network/cosmetic?
3. If gameplay-affecting: fix it using the pattern above.
4. If genuinely safe: add `# determinism-ok` to that exact line, with a
   short comment explaining why (see examples throughout this doc — future
   readers, including you in six months, need the reasoning, not just the
   silence).

## When the golden self-test fails

A score mismatch on a golden replay means the CURRENT replay binary/code
produces a different result than it used to on the exact same input. This
is not a live-player false positive — it's the same deterministic
simulation disagreeing with its own past output. Do not push that build.
Bisect the recent Godot script changes (or binary rebuild) until you find
what changed the numbers, using this doc's rules as your first suspects.
