extends "res://tests/test_case.gd"
## CPU checks of the Auto ladder's state machine, driven with simulated frame
## times: the vsync-strand fix (locked 60 must still climb), the trial-ascent
## revert, the overload guard, and the target budget derivation.

const FireQuality = preload("res://scripts/demos/fire/fire_quality.gd")


func _run_frames(quality, ms: float, seconds: float) -> void:
	# The ladder reads its frame time from update()'s delta, exactly like the
	# controller feeds it — frame_ms only seeds the smoothing at preset switch.
	for frame in int(round(seconds * 1000.0 / ms)):
		quality.frame_ms = ms
		quality.update(ms / 1000.0)


func _initialize() -> void:
	# A vsync-locked 60 Hz screen reports 16.67 ms forever: the ladder must
	# reach level 0 by trials, not strand after the first descent.
	var locked = FireQuality.new()
	locked.frame_ms = 16.67
	locked.set_preset(FireQuality.Preset.AUTO)
	_run_frames(locked, 16.67, 20.0)
	if locked._auto_level != 0:
		_check(false, "locked-60 ladder stranded at level %d" % locked._auto_level)

	# A trial that turns out too heavy reverts to the level it came from, and
	# the backoff keeps the ladder from retrying immediately.
	var heavy = FireQuality.new()
	heavy.frame_ms = 16.67
	heavy.set_preset(FireQuality.Preset.AUTO)
	_run_frames(heavy, 16.67, 6.0) # initial hold + first trial -> level 1
	if heavy._auto_level != 1:
		_check(false, "no trial ascent from the settled level: %d" % heavy._auto_level)
	_run_frames(heavy, 25.0, 2.2) # the trial window reads heavy: revert at +2 s
	if heavy._auto_level != 2:
		_check(false, "heavy trial not reverted (level %d)" % heavy._auto_level)
	_run_frames(heavy, 16.67, 6.0) # fast again, but the 9 s backoff still runs
	if heavy._auto_level != 2:
		_check(false, "ladder ascended during its own backoff: %d" % heavy._auto_level)
	_run_frames(heavy, 16.67, 4.0) # backoff over: it may try again
	if heavy._auto_level != 1:
		_check(false, "no retry after backoff (level %d)" % heavy._auto_level)

	# An overloaded machine descends proportionally and never gambles a trial.
	var overload = FireQuality.new()
	overload.frame_ms = 121.0
	overload.set_preset(FireQuality.Preset.AUTO)
	_run_frames(overload, 121.0, 30.0)
	if overload._auto_level != FireQuality.AUTO_MAX_LEVEL:
		_check(false, "overload did not reach the bottom: level %d"
			% overload._auto_level)

	# The 144 Hz budget derives its own thresholds and reaches the top too.
	var fast_screen = FireQuality.new()
	fast_screen.target_fps = 144.0
	fast_screen.frame_ms = 6.9
	fast_screen.set_preset(FireQuality.Preset.AUTO)
	_run_frames(fast_screen, 6.9, 40.0)
	if fast_screen._auto_level != 0:
		_check(false, "144 Hz target ladder stranded at level %d"
			% fast_screen._auto_level)

	# An explicit preset is never touched by the ladder.
	var explicit = FireQuality.new()
	explicit.frame_ms = 16.67
	explicit.set_preset(FireQuality.Preset.REFERENCE)
	_run_frames(explicit, 16.67, 10.0)
	if explicit.preset != FireQuality.Preset.REFERENCE:
		_check(false, "explicit preset was overwritten")

	_finish("fire_auto_ladder")
