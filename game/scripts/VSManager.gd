extends Node
## VSManager.gd — INTENTIONALLY EMPTIED.
##
## This used to be the client for the legacy real-time 1v1 WebSocket VS
## system (backend/handlers/vs.go, now also emptied — see that file's
## header comment). It was never wired to a reachable menu button in the
## shipped game and has been fully replaced by VSPanel.gd, which talks to
## the VS Rooms system (backend/game/vsroom.go) and now also supports live
## spectating of an in-progress match via the new live relay endpoints.
##
## Removed from the [autoload] section in project.godot. Kept as an empty
## script only because the deploy environment wouldn't allow deleting the
## file outright — it can be deleted entirely from disk with zero effect.
