## GameVersion.gd — client build version constant.
##
## REMOVED (on request): the backend used to reject a submit if this
## didn't match an admin-configured "replay version" (409 version_mismatch,
## see backend/game/appconfig.go's package doc comment for the full
## removal). The server no longer checks this at all — GameManager.gd
## still sends it as "client_version" on every submit (harmless, simply
## ignored server-side now) so this constant is effectively unused, kept
## only so that field isn't just deleted from the wire payload out of an
## abundance of caution. Safe to remove entirely in a future pass if you
## want to drop the field from the submit body too.
class_name GameVersion
extends RefCounted

const CLIENT_VERSION := 1
