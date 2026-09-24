class_name LfmLeapfrogSchedule extends RefCounted


static func entry(step: int, reinit_every: int) -> Dictionary:
	var s := posmod(step, reinit_every)
	if s == 0:
		return {"src": -1, "last_proj": -1, "dt_factor": 0.5,
			"reinit_after": reinit_every == 1}
	if s == 1:
		return {"src": 0, "last_proj": 0, "dt_factor": 1.0,
			"reinit_after": reinit_every == 2}
	return {"src": s - 2, "last_proj": s - 1, "dt_factor": 2.0,
		"reinit_after": s == reinit_every - 1}
