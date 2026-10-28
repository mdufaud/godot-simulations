class_name FractalConfig extends Resource

## GPU time the sample pass may spend per frame; the sample stride adapts to it.
@export_range(1.0, 50.0, 0.5) var sample_budget_ms: float = 10.0
## Coarsest stride: at most 1 pixel in stride² is sampled per frame. Power of two.
@export_range(1, 8, 1) var max_sample_stride: int = 8
@export_range(0.001, 1000000.0, 0.001) var perturbation_zoom_threshold: float = 1000.0


func validate() -> String:
	if sample_budget_ms <= 0.0:
		return "fractal sample budget must be positive"
	if max_sample_stride < 1 or (max_sample_stride & (max_sample_stride - 1)) != 0:
		return "fractal max sample stride must be a power of two"
	if perturbation_zoom_threshold <= 0.0:
		return "fractal zoom threshold must be positive"
	return ""
