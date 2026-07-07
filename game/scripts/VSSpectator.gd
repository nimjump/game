extends CanvasLayer
## VSSpectator.gd — INTENTIONALLY EMPTIED.
##
## An earlier version of live VS spectating used this as a standalone
## scoreboard/dot overlay fed by periodic position snapshots. That's been
## replaced by reusing the REAL deterministic replay player: the streaming
## player now sends their actual RLE input bytes (see
## GameManager.gd's _vs_live_* functions and backend/handlers/vs_live.go),
## and the spectator's client feeds those straight into the same replay
## machinery used for "Watch Replay" (GameManager.gd's live_start_watch/
## live_append/live_replace_log, driven from Main.gd's _watch_vs_live). So
## watching a live match now looks exactly like the real game, not a
## simplified stand-in view.
##
## Kept as an empty script only because the deploy environment wouldn't
## allow deleting the file outright — it can be deleted entirely from disk
## with zero effect.
