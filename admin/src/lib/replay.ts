// TypeScript port of backend game/replay.go
// PCG32 must match Godot 4 RandomNumberGenerator exactly.

export interface PhysicsConfig {
  vw: number; vh: number; physics_fps: number;
  gravity: number; jump_speed: number; move_speed: number;
  platform_w: number; platform_h: number;
  base_gap: number; max_gap: number;
  spawn_above: number; despawn_below: number;
  broken_base_prob: number;
  score_per_unit: number; difficulty_max_score: number;
  start_y_ratio: number;
}

export function defaultConfig(): PhysicsConfig {
  const vw = 600, vh = 800;
  return {
    vw, vh, physics_fps: 60,
    gravity: vh * 2.25,
    jump_speed: -vh * 1.1875,
    move_speed: vw * 0.475,
    platform_w: vw * 0.193,
    platform_h: vh * 0.0225,
    base_gap: vh * 0.119,
    max_gap: vh * 0.1875,
    spawn_above: vh * 1.75,
    despawn_below: vh * 1.125,
    broken_base_prob: 0.05,
    score_per_unit: 0.1,
    difficulty_max_score: 3000,
    start_y_ratio: 0.72,
  };
}

// ── Character physics multipliers (must match Player.gd CHAR_STATS) ──────────────
const CHAR_STATS = [
  { gravityR: 2.125,  jumpR: -1.15,    moveR: 0.533 }, // bunny1
  { gravityR: 2.375,  jumpR: -1.3125,  moveR: 0.417 }, // bunny2
  { gravityR: 2.25,   jumpR: -1.225,   moveR: 0.475 }, // bunny3 (default)
  { gravityR: 2.5,    jumpR: -1.275,   moveR: 0.400 }, // bunny4
  { gravityR: 2.0,    jumpR: -1.30,    moveR: 0.510 }, // bunny5
];

// ── PCG32 — must match Godot 4 RandomNumberGenerator exactly ──────────────────
// Source: godot/core/math/pcg.h  PCG32::seed(uint64_t p_seed)
//   state = 0; inc = 1; next(); state += p_seed; next();
class PCG32 {
  private state: bigint;
  private inc: bigint = (2891336453n << 1n) | 1n; // = 5782672907 — Godot random_pcg.h DEFAULT_INC<<1|1

  constructor(seed: bigint) {
    this.state = 0n;
    this.next();                                          // warmup 1
    this.state = BigInt.asUintN(64, this.state + seed);  // seed inject
    this.next();                                          // warmup 2
  }

  next(): number {
    const old = this.state;
    this.state = BigInt.asUintN(64, old * 6364136223846793005n + this.inc);
    const xs = Number(BigInt.asUintN(32, ((old >> 18n) ^ old) >> 27n));
    const rot = Number(old >> 59n);
    return ((xs >>> rot) | (xs << ((-rot) & 31))) >>> 0;
  }

  randf(): number { return this.next() / 4294967296; }
  randfRange(lo: number, hi: number): number { return lo + this.randf() * (hi - lo); }
  randiRange(lo: number, hi: number): number { return lo + (this.next() % (hi - lo + 1)); }
}

// ── Replay frame snapshot (for visualization) ──────────────────────────────────
export interface Frame {
  px: number; py: number; pvy: number;
  cameraY: number; score: number;
  platforms: { x: number; y: number; broken: boolean }[];
  alive: boolean;
}

export interface ReplayResult {
  score: number;
  frames: Frame[];   // sampled at 60fps — every tick
}

// base64 → Uint8Array (browser-safe)
function b64toBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// ── Biome name by score (GameManager._biome_name_for_score) ────────────────────
function biomeName(score: number): string {
  if (score < 500)  return "grass";
  if (score < 1200) return "stone";
  if (score < 2200) return "wood";
  return "snow";
}

// ── RNG consumption for _add_deco ──────────────────────────────────────────────
function consumeDecoRNG(rng: PCG32, gname: string, vw: number): void {
  switch (gname) {
    case "grass":
      if (rng.randf() < 0.60) {
        rng.randf(); // grass1/grass2
        rng.randf(); // side
      }
      if (rng.randf() < 0.30) {
        rng.randfRange(-vw * 0.067, vw * 0.067); // x offset
      }
      break;
    case "sand":
      if (rng.randf() < 0.70) {
        rng.randf(); // side
      }
      break;
    case "wood": {
      const roll = rng.randf();
      if (roll >= 0.25 && roll < 0.50) {
        rng.randf(); // mush type
        rng.randf(); // side
      }
      break;
    }
    case "snow":
      if (rng.randf() < 0.55) {
        rng.randf(); // grass_brown1/2
        rng.randf(); // side
      }
      break;
    case "stone":
      if (rng.randf() < 0.40) {
        rng.randf(); // side
      }
      break;
  }
}

// ── RNG consumption for _add_spikes (grass/sand) ───────────────────────────────
function consumeSpikeRNG(rng: PCG32): void {
  const useWide = rng.randf() < 0.4;
  if (!useWide) {
    rng.randiRange(2, 4); // spike_count
  }
}

// ── Full platform spawn RNG simulation ─────────────────────────────────────────
// GameManager._spawn_platform → _add_deco → _add_spikes → _add_spring → enemy/item
function consumePlatformRNG(rng: PCG32, score: number, broken: boolean, cfg: PhysicsConfig): void {
  if (broken) return;

  const gname = biomeName(score);
  consumeDecoRNG(rng, gname, cfg.vw);

  // if/elif logic — only one branch runs
  if (gname === "grass" || gname === "sand") {
    if (rng.randf() < 0.18) {
      consumeSpikeRNG(rng);
    }
  } else if (gname === "stone" || gname === "wood" || gname === "snow") {
    if (rng.randf() < 0.12) {
      // _add_spike_bottom — no extra RNG
    }
  }

  // Spring
  if (rng.randf() < 0.05) return;

  // Enemy veya item
  const diff = Math.min(score / cfg.difficulty_max_score, 1);
  const enemyProb = 0.28 + (0.60 - 0.28) * diff;
  if (rng.randf() < enemyProb) {
    rng.next(); // enemy tipi: randi() % available.size()
  } else if (rng.randf() < 0.22) {
    if (rng.randf() < 0.15) {
      // spinning_card
      rng.randf(); // is_good
      rng.next();  // result_slot
    } else {
      rng.next(); // item tipi
    }
  }
}

export function runReplay(
  seed: string | number | bigint,
  logB64: string,
  ticks: number,
  cfg: PhysicsConfig = defaultConfig(),
  charIdx: number = 2,
  sampleEvery = 1,   // record every N ticks (1 = all, 2 = every other)
): ReplayResult {
  const logBytes = b64toBytes(logB64);
  const totalBits = logBytes.length * 5;
  if (ticks > totalBits) ticks = totalBits;

  // Apply character physics
  const ci = (charIdx >= 0 && charIdx < 5) ? charIdx : 2;
  const cs = CHAR_STATS[ci];
  const gravity   = cs.gravityR * cfg.vh;
  const jumpSpeed = cs.jumpR    * cfg.vh;
  const moveSpeed = cs.moveR    * cfg.vw;

  const rng = new PCG32(BigInt(seed));
  const dt = 1 / cfg.physics_fps;

  type Plat = { x: number; y: number; broken: boolean };
  let platforms: Plat[] = [];
  // _spawn_initial_platforms: start_plat_y = VH*0.72 + VH*0.03 = VH*0.75
  const startPlatY = cfg.vh * cfg.start_y_ratio + cfg.vh * 0.03;
  platforms.push({ x: cfg.vw * 0.5, y: startPlatY, broken: false });
  let highestPlatY = startPlatY;

  // ── Initial safe platforms (6 total) ──────────────────────────────────────
  for (let i = 0; i < 6; i++) {
    const x = rng.randfRange(cfg.vw * 0.13, cfg.vw * 0.87);
    const newY = highestPlatY - cfg.base_gap * 0.75;
    platforms.push({ x, y: newY, broken: false });
    if (newY < highestPlatY) highestPlatY = newY;
    // safe=true → no deco/spike/enemy
  }

  // ── Initial normal platforms (14 total) ─────────────────────────────────────
  for (let i = 0; i < 14; i++) {
    const x = rng.randfRange(cfg.vw * 0.10, cfg.vw * 0.90);
    const newY = highestPlatY - cfg.base_gap * 0.75;
    platforms.push({ x, y: newY, broken: false });
    if (newY < highestPlatY) highestPlatY = newY;
    consumePlatformRNG(rng, 0, false, cfg);
  }

  function spawnPlatform(score: number) {
    const diff = Math.min(score / cfg.difficulty_max_score, 1);
    const brokenChance = cfg.broken_base_prob + (0.28 - cfg.broken_base_prob) * diff;
    const gap = cfg.base_gap + (cfg.max_gap - cfg.base_gap) * diff;
    const newY = highestPlatY - gap - rng.randfRange(0, cfg.base_gap * 0.3);
    const newX = rng.randfRange(cfg.vw * 0.10, cfg.vw * 0.90);
    const broken = rng.randf() < brokenChance;
    platforms.push({ x: newX, y: newY, broken });
    if (newY < highestPlatY) highestPlatY = newY;
    consumePlatformRNG(rng, score, broken, cfg);
  }

  while (highestPlatY > -cfg.spawn_above) spawnPlatform(0);

  let px = cfg.vw * 0.5;
  let py = startPlatY - cfg.platform_h * 0.5 - cfg.vh * 0.025;
  let pvy = 0;
  let highestY = startPlatY - py;
  let score = 0;
  let cameraY = py;
  const frames: Frame[] = [];

  for (let tick = 0; tick < ticks; tick++) {
    const byteIdx = Math.floor(tick / 5);
    const slot    = tick % 5;
    let digit = 0;
    if (byteIdx < logBytes.length) {
      let pow3 = 1;
      for (let i = 0; i < slot; i++) pow3 *= 3;
      digit = Math.floor(logBytes[byteIdx] / pow3) % 3;
    }
    const left  = digit === 1;
    const right = digit === 2;

    const dir = right ? 1 : left ? -1 : 0;
    px += dir * moveSpeed * dt;
    if (px > cfg.vw + 20) px = -20;
    else if (px < -20) px = cfg.vw + 20;

    pvy += gravity * dt;
    py += pvy * dt;

    if (pvy > 0) {
      const playerBottom = py + cfg.vh * 0.04;
      for (let i = 0; i < platforms.length; i++) {
        const p = platforms[i];
        const platTop = p.y - cfg.platform_h * 0.5;
        if (
          px >= p.x - cfg.platform_w * 0.5 &&
          px <= p.x + cfg.platform_w * 0.5 &&
          playerBottom >= platTop &&
          playerBottom <= platTop + cfg.platform_h + Math.abs(pvy) * delta * 2
        ) {
          py = platTop - cfg.vh * 0.04;
          pvy = jumpSpeed;
          if (p.broken) platforms.splice(i, 1);
          break;
        }
      }
    }

    if (py < cameraY) cameraY = py;

    const h = startPlatY - py;
    if (h > highestY) { highestY = h; score = Math.floor(highestY * cfg.score_per_unit); }

    const despawnY = cameraY + cfg.despawn_below;
    platforms = platforms.filter(p => p.y < despawnY);
    while (highestPlatY > cameraY - cfg.spawn_above) spawnPlatform(score);

    const alive = py <= cameraY + cfg.vh * 0.75;

    if (tick % sampleEvery === 0) {
      frames.push({
        px, py, pvy, cameraY, score, alive,
        platforms: platforms.map(p => ({ ...p })),
      });
    }
    if (!alive) break;
  }

  return { score, frames };
}
