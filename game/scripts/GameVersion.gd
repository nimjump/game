## GameVersion.gd — single source of truth for the client build version.
##
## Sent with every replay submit ("client_version" field). The backend
## compares it against its own configured replay_version (admin panel →
## System tab). If they don't match, the submit is rejected and never
## saved — old client builds can't send replays a newer/older replay
## verifier binary wasn't built to check, and vice versa.
##
## Bump this number every time you cut a new client build that goes out
## together with a new replay verifier binary (backend/replay-verifier),
## then bump the matching "Replay version" field in the admin panel to
## the SAME number once both are live. Until you do, existing clients
## keep working — this all only exists to catch client/server version
## drift, not to force people to be on a specific number.
class_name GameVersion
extends RefCounted

const CLIENT_VERSION := 1
