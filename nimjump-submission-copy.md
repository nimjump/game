# NimJump — Mini App Submission Copy

Paste these straight into the form fields. Adjust freely — this is a first draft grounded in what the app actually does (checked against the codebase), nothing invented.

---

## About your app

**App name**
NimJump

**Category**
Games

**Tagline** (one punchy line)
Solving one of web3 gaming's biggest problems — cheating — wrapped in a game actually worth playing.

Alt options:
- One of web3 gaming's biggest problems, cheating, solved — and made genuinely fun.
- Fixing web3 gaming's cheating problem, without forgetting to make a good game.
- No fake scores. No shortcuts. Just a solid game done right.

**What problem it solves**
Most web3 games that pay real money for a high score have the same hole: the client reports a score, and the server just believes it. Memory editing, a modified client, a macro — and the leaderboard is just a list of whoever cheated best.

NimJump closes that hole completely. The client never reports a score — it only sends the raw inputs from the run. The server replays those inputs itself and only trusts its own recomputed result. If it doesn't match exactly, the run is rejected. The client has zero authority beyond recording what the player did — no score, no quest completion, nothing is ever taken at face value.

Every reward — leaderboard rank, streak claims, quests, coin conversion — is granted purely off that server-side result.

There's also a reward-farming problem this solves: on top of the score itself being unfakeable, every NIM claim is checked against a per-IP guard. At most 2 wallets can get paid from the same IP per day, so stacking throwaway accounts on one connection doesn't work either.

**Short description**
NimJump is an endless vertical platformer for Nimiq — jump, dodge, and climb as high as you can with tap or gyro-tilt controls. Every run is verified server-side: the client only sends its inputs, the backend replays the match itself, and only that recomputed result ever counts — no fakeable scores. Replays are tiny (under 300 bytes a minute) so every run stays public and watchable, forever. Works fully offline too — your run queues locally and submits the moment you're back online.

That verified score is what real NIM gets attached to: leaderboard prizes, a daily login streak, quests, and coin conversion — all guarded by a per-IP claim limit so nobody farms it with throwaway wallets. Sign in with your Nimiq wallet and you're playing in seconds.

**Pricing**
Free

---

## Links & demo

**Repo URL**
[your GitHub repo link]

**Demo URL**
[your live web export / hosted link]

**Video walkthrough**
[30–60s clip: sign in with wallet → play a run (show gyro tilt) → land on leaderboard → open the daily streak claim / quest list showing NIM rewards]

---

## About you

**GitHub username**
[fill in]

**E-mail address**
emre34altinok@gmail.com

**Team name** (optional)
[fill in, or leave blank if solo]

**X account** (optional)
[fill in]

**Builder story** (optional)
I heard about this competition about a month ago and I've been building on NimJump nonstop since. I've been doing game development for a long time now, almost 3 years, and I genuinely love web3 games as a player too — I just hadn't worked on one myself until this project. That's actually what made the cheating problem stand out to me so much: playing "score = money" games from the other side and seeing how easy most of them are to cheat — the client claims a score, and the backend just takes its word for it. Building something genuinely, structurally resistant to that from the ground up was a real dream of mine, not a checkbox to tick, and it's the actual core of this project — everything else is built around it, not the other way around.

The game itself is built in Godot 4.7, backend in Go. Instead of the client reporting a final score, it sends the recorded inputs from the run, and the backend replays the entire match itself from those inputs, completely independently of anything the client claims, trusting only the score that comes out of its own recomputation. If a replayed run doesn't reproduce exactly, it's flagged and thrown out on the spot, no manual review, no benefit of the doubt. Making that verification actually trustworthy was genuinely the hardest and most important part of building this, and it's the part I'm proudest of.

Recording inputs instead of video turned out to have a huge bonus: a full minute of play compresses down to under 300 bytes, so under 1GB can hold more than 2 million complete, re-playable runs. That's efficient enough that I never have to throw anything away — every score on the public leaderboard has its actual replay sitting right behind it, watchable by anyone, logged in or not. Nothing on that leaderboard is ever just a trusted number with no way to check it.

Everything else that pays out real NIM — the daily/weekly leaderboard, the claimable daily login streak, in-run quests, and converting collected coins into NIM — only exists because that verification foundation made it safe to attach money to a score in the first place. And it's not just cheat-proof on the score side: every one of those claims is checked against a per-IP guard before anything gets paid out. Right now that cap sits at 2 wallet accounts per IP per day — the 1st and 2nd wallet claiming from the same connection get paid normally, the 3rd+ is rejected with a clear reason shown to the player instead of silently vanishing. So the same person can't just open a handful of wallets on one phone or one Wi-Fi and farm the reward pool multiple times a day. There's also a separate daily earn cap on top of that — in-game coin-to-NIM conversion is capped per player per day (100 NIM by default), so no single account can drain the pool in one sitting either. To actually operate this safely I also built a full admin panel where nearly everything is live-tunable with a single click, no code changes and no server restart: reward amounts, the per-IP claim cap, the daily earn cap itself, the coin-to-NIM conversion rate, leaderboard prize configuration, even hot-swapping the replay-verifier binary.

I also wanted the game to genuinely feel good to play on top of being technically sound: tap or gyro-tilt controls, with the tilt calibration and acceleration ramp tuned from real device testing until turns actually felt right. This is still a live-service loop I'm actively building on, but the anti-cheat replay system was, and still is, the whole point.

I also cared a lot about giving people a reason to come back the next day instead of playing once and forgetting about it — that's what the daily login streak, the daily/weekly leaderboard resets, and the daily quests are actually for, not just there to pad out the feature list.

I've been working on NimJump since the day this competition was first announced — about a month now — and I ran it publicly for 2 weeks during that time, not just tested it privately. In that window, 15 different real users found and played the game. I've attached screenshots of the stats and activity from that period — please take a look.

---

## Media checklist (not text, just a reminder of what to prepare)

- **App icon / favicon** — 512×512px, PNG/JPG/WebP. Use the character sprite or a simplified platform+character mark, clean on a solid or transparent background.
- **Thumbnail** — 240×240px. Can reuse the icon or a cropped in-game screenshot with the character mid-jump — needs to read at small size.
- **Screenshots (3–5, first = social preview)** — suggested shots:
  1. Lobby screen (Play button, character, streak badge visible) — this is the social preview, make it look alive.
  2. Mid-run gameplay (jumping, cloud enemy visible, score HUD).
  3. Leaderboard tab with real scores/prizes (public — this is a good one to lead with).
  4. Watching a top run's replay play back.
  5. Quest list showing NIM reward amounts.
