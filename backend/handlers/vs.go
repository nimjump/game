package handlers

// vs.go — INTENTIONALLY EMPTIED.
//
// This used to hold the legacy real-time 1v1 WebSocket matchmaking system
// (POST /backend/vs/join, GET /backend/vs/ws/{room_id} — in-memory rooms,
// raw input relay between two connected players). It was never reachable
// from the shipped game (no invite-link generator existed for it) and has
// been fully replaced by the VS Rooms system (backend/game/vsroom.go +
// backend/handlers/vsroom.go), which now also carries a live spectator
// relay (see vs_live.go) covering the same "watch a match in progress" use
// case this legacy system was originally meant for.
//
// The routes that used to point here were removed from server.go. Nothing
// elsewhere in the codebase references any identifier that used to live in
// this file (confirmed via full-repo search before removal) — this file is
// kept only because the deploy environment wouldn't allow deleting it
// outright; it can be deleted entirely from disk with zero effect on the
// build (a lone `package handlers` file compiles fine).
