extends Node
## GlobalTheme.gd — autoload, runs before any scene UI is built.
##
## Installs our pixel font (with its engine-default-font fallback for missing
## glyphs — see UITheme._apply_pixel_font) as the whole SceneTree's default
## theme font. Any Label/Button/etc. that doesn't get an explicit font
## override from UITheme.apply_label()/_apply_pixel_font() (a missed call
## site, dynamically-built debug UI, a 3rd-party control, etc.) now falls
## back to THIS instead of Godot's plain built-in default font — fixes the
## "some numbers/text render in the normal system font instead of ours" bug.

const UITheme := preload("res://scripts/UITheme.gd")

func _ready() -> void:
	UITheme.apply_global_default(get_tree())
