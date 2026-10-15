class_name LoadingPump
extends RefCounted
## Lets a long main-thread step (a demo's _ready, a blocking bake) keep the
## loading overlay alive and say what it is doing. Both calls are no-ops until
## the game manager installs its hook and while no simulation is loading; never
## call them from a method that runs on the render thread.

static var _hook := Callable()


static func set_hook(hook: Callable) -> void:
	_hook = hook


## Redraws the overlay if enough time passed since the last redraw.
static func tick() -> void:
	if _hook.is_valid():
		_hook.call("")


## Names the step about to run and redraws immediately, so a step that then
## blocks for seconds is labelled instead of looking frozen.
static func stage(label: String) -> void:
	if _hook.is_valid():
		_hook.call(label)


## wait_for_group_task_completion that keeps the overlay drawing meanwhile.
static func wait_for_group(task: int) -> void:
	while not WorkerThreadPool.is_group_task_completed(task):
		tick()
		OS.delay_msec(2)
	WorkerThreadPool.wait_for_group_task_completion(task)
