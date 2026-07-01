## MoveSegment.gd — Segment data class for the EnemyBase tick-based movement engine
class_name MoveSegment
extends RefCounted

var from_pos  : Vector2
var to_pos    : Vector2
var axis      : int     # 0=XY, 1=X-only, 2=Y-only
var total     : int     # total ticks
var elapsed   : int
var ease_in   : bool
var ease_out  : bool
var bounce    : bool    # TRANS_BOUNCE-like
var callback  : Callable

func _init(f:Vector2, t:Vector2, ax:int, ticks:int, ein:bool, eout:bool, bnc:bool, cb:Callable) -> void:
	from_pos = f; to_pos = t; axis = ax; total = ticks; elapsed = 0
	ease_in = ein; ease_out = eout; bounce = bnc; callback = cb
