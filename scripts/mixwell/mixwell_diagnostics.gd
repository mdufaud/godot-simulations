class_name MixwellDiagnostics
extends RefCounted

const Gallery := preload("res://scripts/mixwell/mixwell_gallery.gd")
const Math := preload("res://scripts/mixwell/mixwell_math.gd")
const Periodicity := preload("res://scripts/mixwell/mixwell_periodicity.gd")


static func cpu_advect(point: Vector2, operations: Array[Dictionary], periodic: bool,
		period: Vector2, brush_radius_px: float, reference_size: Vector2i,
		affine_mode: int, affine_radius_px: float, affine_strength: float,
		cutoff_gamma: float, drift_compensation: int, midpoint_alpha: float) -> Vector2:
	var value := point
	if periodic:
		value = Periodicity.wrap_coordinate(value, period)
	var reference_min := float(maxi(mini(reference_size.x, reference_size.y), 1))
	var epsilon := brush_radius_px * 2.0 / reference_min
	if affine_mode >= 0:
		var affine_radius := affine_radius_px * 2.0 / reference_min
		value = Gallery.affine_advect(affine_mode, value, Vector2.ZERO,
			affine_strength, affine_radius, cutoff_gamma)
		return Periodicity.wrap_coordinate(value, period) if periodic else value
	var periodic_curve_counts := {}
	for operation in operations:
		var curve_group := int(operation.get("curve_group", -1))
		if periodic and curve_group >= 0:
			var limit := maxi(int(operation.get("periodic_segment_count", 0)), 0)
			var seen := int(periodic_curve_counts.get(curve_group, 0))
			if limit <= 0 or seen >= limit:
				continue
			periodic_curve_counts[curve_group] = seen + 1
		var operation_type := int(operation.get("type", Gallery.LINE))
		if operation_type == Gallery.LINE or operation_type == Gallery.LINE_COMB:
			var direction: Vector2 = operation.get("direction", Vector2.RIGHT).normalized()
			var perpendicular := Vector2(-direction.y, direction.x)
			var operation_radius := float(operation.get("radius_px", -1.0))
			var operation_epsilon := (brush_radius_px if operation_radius <= 0.0 else operation_radius) \
					* 2.0 / reference_min
			var count := maxi(int(operation.get("count", 1)), 1) \
					if operation_type == Gallery.LINE_COMB else 1
			for line_index in count:
				var offset := 0.0
				if operation_type == Gallery.LINE_COMB:
					offset = (float(line_index) - 0.5 * float(count - 1)) \
							* float(operation.get("pitch", 0.0))
					var noise_value := float(operation.get("noise", 0.0))
					if noise_value != 0.0:
						var noise := _hash11(float(line_index) + noise_value)
						offset += (noise * 2.0 - 1.0) * noise_value
				var phase := float(operation.get("phase", 0.0))
				var origin: Vector2 = operation.get("origin", Vector2.ZERO) \
						+ perpendicular * (offset + phase)
				var drift := Math.rd_line(Math.point(value.x - origin.x, value.y - origin.y),
						operation_epsilon, Math.point(direction.x, direction.y))
				if drift.size() == 2:
					var weight := _line_extent_weight(value, origin, direction,
							operation_epsilon, cutoff_gamma, operation.get("extent", Vector2.ZERO))
					value += Vector2(drift[0], drift[1]) * weight
			if operation_type == Gallery.LINE_COMB:
				value += Gallery.compensation_vector(drift_compensation, operation_epsilon,
						float(operation.get("pitch", 0.0)), direction)
		elif operation_type == Gallery.SEGMENT:
			var segment: Vector4 = operation.get("segment", Vector4.ZERO)
			if periodic or operation.get("period", Vector2.ZERO) != Vector2.ZERO:
				segment = _periodic_segment_at(segment, value, operation.get("period", Vector2.ZERO))
			var radius := float(operation.get("radius_px", -1.0))
			var segment_epsilon := (brush_radius_px if radius <= 0.0 else radius) \
					* 2.0 / reference_min
			var drift := Math.rd_segment(Math.point(value.x, value.y), segment_epsilon,
					Math.point(segment.x, segment.y), Math.point(segment.z, segment.w),
					midpoint_alpha)
			if drift.size() == 2:
				value += Vector2(drift[0], drift[1])
		if periodic:
			value = Periodicity.wrap_coordinate(value, period)
	return Periodicity.wrap_coordinate(value, period) if periodic else value


static func _periodic_segment_at(segment: Vector4, point: Vector2, period: Vector2) -> Vector4:
	if period == Vector2.ZERO:
		return segment
	var start := Vector2(segment.x, segment.y)
	var shift := Vector2.ZERO
	if period.x > 0.0:
		shift.x = round((point.x - start.x) / period.x) * period.x
	if period.y > 0.0:
		shift.y = round((point.y - start.y) / period.y) * period.y
	return Vector4(start.x + shift.x, start.y + shift.y,
			segment.z + shift.x, segment.w + shift.y)


static func _hash11(value: float) -> float:
	return fposmod(sin(value * 127.1 + 311.7) * 43758.5453123, 1.0)


static func _line_extent_weight(point: Vector2, origin: Vector2, direction: Vector2,
		epsilon: float, cutoff_gamma: float, extent: Vector2) -> float:
	if extent == Vector2.ZERO:
		return 1.0
	var low := minf(extent.x, extent.y)
	var high := maxf(extent.x, extent.y)
	var distance := maxf(epsilon * cutoff_gamma, epsilon)
	var along := (point - origin).dot(direction.normalized())
	return _smoothstep(low - distance, low, along) \
			* (1.0 - _smoothstep(high, high + distance, along))


static func cpu_pigment(coordinate: Vector2, source_mode: int,
		reference_size: Vector2i) -> Vector3:
	var aspect := float(maxi(reference_size.x, 1)) / float(maxi(reference_size.y, 1))
	var uv := Vector2(
		clampf(coordinate.x / aspect * 0.5 + 0.5, 0.0, 1.0),
		clampf(coordinate.y * 0.5 + 0.5, 0.0, 1.0))
	if source_mode == 0:
		var band := 1.0 if fposmod(uv.x * 12.0, 1.0) >= 0.5 else 0.0
		return Vector3(0.08, 0.62, 0.95).lerp(Vector3(0.98, 0.25, 0.16), band)
	if source_mode == 1:
		var grid := Vector2(fposmod(uv.x * 10.0, 1.0), fposmod(uv.y * 10.0, 1.0))
		grid = abs(grid - Vector2(0.5, 0.5))
		var line := 1.0 - _smoothstep(0.43, 0.49, maxf(grid.x, grid.y))
		return Vector3(0.93, 0.88, 0.55).lerp(Vector3(0.12, 0.28, 0.48), line)
	if source_mode == 2:
		var centre := uv - Vector2(0.5, 0.5)
		var radius := centre.length() * 14.0
		var ring := 0.5 + 0.5 * cos(radius * PI)
		var cross := 1.0 - _smoothstep(0.0, 0.045, minf(absf(centre.x), absf(centre.y)))
		return Vector3(0.96, 0.84, 0.20).lerp(Vector3(0.18, 0.12, 0.46), ring * 0.8) \
				+ Vector3(cross * 0.25, cross * 0.25, cross * 0.25)
	var centres := [Vector2(0.28, 0.32), Vector2(0.66, 0.37), Vector2(0.42, 0.62),
		Vector2(0.72, 0.72), Vector2(0.18, 0.75)]
	var colours := [Vector3(0.96, 0.28, 0.20), Vector3(0.98, 0.73, 0.16),
		Vector3(0.22, 0.72, 0.94), Vector3(0.74, 0.24, 0.86), Vector3(0.22, 0.86, 0.46)]
	var result := Vector3(0.96, 0.92, 0.76)
	for index in centres.size():
		var drop := 1.0 - _smoothstep(0.0, 0.08, uv.distance_to(centres[index]))
		result = result.lerp(colours[index], drop)
	return result


static func oracle_expected(operation: Dictionary, coordinate: Vector2, epsilon: float,
		midpoint_alpha: float) -> PackedFloat64Array:
	if int(operation.get("type", Gallery.LINE)) == Gallery.LINE:
		var origin: Vector2 = operation.get("origin", Vector2.ZERO)
		var direction: Vector2 = operation.get("direction", Vector2.RIGHT)
		return Math.rd_line(Math.point(coordinate.x - origin.x, coordinate.y - origin.y),
			epsilon, Math.point(direction.x, direction.y))
	var segment: Vector4 = operation.get("segment", Vector4.ZERO)
	return Math.rd_segment(Math.point(coordinate.x, coordinate.y), epsilon,
			Math.point(segment.x, segment.y), Math.point(segment.z, segment.w), midpoint_alpha)


static func analyse_metrics(diagnostic_values: PackedFloat32Array,
		accumulation_values: PackedFloat32Array,
		previous_accumulation_values: PackedFloat32Array, size: Vector2i,
		snapshot, sample: int) -> Dictionary:
	var area_sum := 0.0
	var max_area := 0.0
	var count := diagnostic_values.size() / 4
	var area_values: Array[float] = []
	var class_sum := {"core": 0.0, "singularity": 0.0, "cutoff": 0.0, "boundary": 0.0, "wall": 0.0}
	var class_count := {"core": 0, "singularity": 0, "cutoff": 0, "boundary": 0, "wall": 0}
	for index in count:
		var area_error := absf(float(diagnostic_values[index * 4 + 3]))
		area_sum += area_error
		max_area = maxf(max_area, area_error)
		area_values.append(area_error)
		var category := _area_category(Vector2i(index % size.x, index / size.x), size, snapshot)
		class_sum[category] += area_error
		class_count[category] += 1
	area_values.sort()
	var convergence_max := 0.0
	var convergence_rms := 0.0
	var convergence_p99 := 0.0
	var convergence_values: Array[float] = []
	var accumulation_count := accumulation_values.size() / 4
	if previous_accumulation_values.size() == accumulation_values.size():
		for index in accumulation_count:
			var offset := index * 4
			var difference := Vector3(
				accumulation_values[offset] - previous_accumulation_values[offset],
				accumulation_values[offset + 1] - previous_accumulation_values[offset + 1],
				accumulation_values[offset + 2] - previous_accumulation_values[offset + 2])
			var norm := difference.length()
			convergence_values.append(norm)
			convergence_max = maxf(convergence_max, norm)
			convergence_rms += difference.length_squared()
	if not convergence_values.is_empty():
		convergence_values.sort()
		convergence_p99 = convergence_values[mini(convergence_values.size() - 1,
				int(ceil(float(convergence_values.size()) * 0.99)) - 1)]
		convergence_rms = sqrt(convergence_rms / float(convergence_values.size() * 3))
	return {
		"area_error": area_sum / float(maxi(count, 1)),
		"max_area_error": max_area,
		"area_p99": area_values[mini(area_values.size() - 1,
				int(ceil(float(area_values.size()) * 0.99)) - 1)] if not area_values.is_empty() else 0.0,
		"area_core": class_sum.core / float(maxi(class_count.core, 1)),
		"area_singularity": class_sum.singularity / float(maxi(class_count.singularity, 1)),
		"area_cutoff": class_sum.cutoff / float(maxi(class_count.cutoff, 1)),
		"area_boundary": class_sum.boundary / float(maxi(class_count.boundary, 1)),
		"area_wall": class_sum.wall / float(maxi(class_count.wall, 1)),
		"convergence_error": convergence_max,
		"convergence_rms": convergence_rms,
		"convergence_p99": convergence_p99,
		"sample": sample,
}


static func analyse_reduced_metrics(reduced_values: PackedFloat32Array, group_count: int,
		stride: int, size: Vector2i, _snapshot, sample: int) -> Dictionary:
	var area_sum := 0.0
	var max_area := 0.0
	var convergence_squared := 0.0
	var convergence_max := 0.0
	var category_sum := [0.0, 0.0, 0.0, 0.0, 0.0]
	var category_count := [0, 0, 0, 0, 0]
	var area_hist := [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
	var convergence_hist := [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
	for group in mini(group_count, reduced_values.size() / stride):
		var base := group * stride
		area_sum += reduced_values[base]
		max_area = maxf(max_area, reduced_values[base + 1])
		convergence_squared += reduced_values[base + 2]
		convergence_max = maxf(convergence_max, reduced_values[base + 3])
		for category in 5:
			category_sum[category] += reduced_values[base + 4 + category]
			category_count[category] += int(round(reduced_values[base + 9 + category]))
		for bin in 16:
			area_hist[bin] += int(round(reduced_values[base + 14 + bin]))
			convergence_hist[bin] += int(round(reduced_values[base + 30 + bin]))
	var pixel_count := maxi(size.x * size.y, 1)
	var area_p99_bin := _histogram_percentile(area_hist, pixel_count, 0.99)
	var convergence_p99_bin := _histogram_percentile(convergence_hist, pixel_count, 0.99)
	var area_p99 := max_area * minf(float(area_p99_bin + 1) / 15.0, 1.0)
	var convergence_p99 := convergence_max * minf(
			float(convergence_p99_bin + 1) / 15.0, 1.0)
	return {
		"area_error": area_sum / float(pixel_count),
		"max_area_error": max_area,
		"area_p99": area_p99 if area_sum > 0.0 else 0.0,
		"area_core": category_sum[0] / float(maxi(category_count[0], 1)),
		"area_singularity": category_sum[1] / float(maxi(category_count[1], 1)),
		"area_cutoff": category_sum[2] / float(maxi(category_count[2], 1)),
		"area_boundary": category_sum[3] / float(maxi(category_count[3], 1)),
		"area_wall": category_sum[4] / float(maxi(category_count[4], 1)),
		"convergence_error": convergence_max,
		"convergence_rms": sqrt(convergence_squared / float(pixel_count * 3)),
		"convergence_p99": convergence_p99 if convergence_squared > 0.0 else 0.0,
		"sample": sample,
	}


static func analyse_zone_metrics(diagnostic_values: PackedFloat32Array,
		zone_values: PackedByteArray, size: Vector2i) -> Dictionary:
	var zone_values_sorted: Array = [[], [], [], [], []]
	var zone_counts := [0, 0, 0, 0, 0]
	var zone_sums := [0.0, 0.0, 0.0, 0.0, 0.0]
	var pixel_count := mini(size.x * size.y, mini(diagnostic_values.size() / 4,
		zone_values.size()))
	for index in pixel_count:
		var zone := clampi(int(zone_values[index]), 0, 4)
		var area_error := absf(float(diagnostic_values[index * 4 + 3]))
		zone_values_sorted[zone].append(area_error)
		zone_counts[zone] += 1
		zone_sums[zone] += area_error
	var result := {}
	for zone in 5:
		var values: Array = zone_values_sorted[zone]
		values.sort()
		var name: String = ["core", "singularity", "cutoff", "boundary", "wall"][zone]
		var p99: float = values[mini(values.size() - 1,
				int(ceil(float(values.size()) * 0.99)) - 1)] if not values.is_empty() else 0.0
		result["area_%s_count" % name] = zone_counts[zone]
		result["area_%s_p99" % name] = p99
		result["area_%s_mean" % name] = zone_sums[zone] / float(maxi(zone_counts[zone], 1))
	result["area_valid_count"] = zone_counts[0]
	result["area_valid_p99"] = result.area_core_p99
	return result


static func _histogram_percentile(histogram: Array, count: int, percentile: float) -> int:
	var target := maxi(int(ceil(float(count) * percentile)), 1)
	var cumulative := 0
	for bin in histogram.size():
		cumulative += int(histogram[bin])
		if cumulative >= target:
			return bin
	return maxi(histogram.size() - 1, 0)


static func compare_gpu_diagnostics(periodic_values: PackedFloat32Array,
		fullscreen_values: PackedFloat32Array, periodic_colours: PackedFloat32Array,
		fullscreen_colours: PackedFloat32Array, size: Vector2i, period: Vector2) -> Dictionary:
	var count := mini(periodic_values.size(), fullscreen_values.size()) / 4
	var periodic_displacement := PackedFloat32Array()
	var fullscreen_displacement := PackedFloat32Array()
	var max_area_error := 0.0
	var mean_area_error := 0.0
	var area_count := 0
	for index in count:
		var offset := index * 4
		periodic_displacement.append(periodic_values[offset])
		periodic_displacement.append(periodic_values[offset + 1])
		fullscreen_displacement.append(fullscreen_values[offset])
		fullscreen_displacement.append(fullscreen_values[offset + 1])
		var pixel := Vector2i(index % size.x, index / size.x)
		if pixel.x > 0 and pixel.x < size.x - 1 and pixel.y > 0 and pixel.y < size.y - 1:
			var area_error := absf(periodic_values[offset + 3] - fullscreen_values[offset + 3])
			max_area_error = maxf(max_area_error, area_error)
			mean_area_error += area_error
			area_count += 1
	if area_count > 0:
		mean_area_error /= float(area_count)
	var result := Periodicity.compare_paths(periodic_displacement, fullscreen_displacement,
			period, periodic_colours, fullscreen_colours)
	result["backend"] = "gpu"
	result["pixels"] = count
	result["max_area_error"] = max_area_error
	result["mean_area_error"] = mean_area_error
	result["passes"] = result.get("passes", false) and max_area_error <= 5.0e-3
	return result


static func _area_category(pixel: Vector2i, size: Vector2i, snapshot) -> String:
	if pixel.x <= 0 or pixel.y <= 0 or pixel.x >= size.x - 1 or pixel.y >= size.y - 1:
		return "wall" if snapshot != null and snapshot.active_boundary_mode == 2 else "boundary"
	if snapshot == null or snapshot.operations.is_empty():
		return "core"
	var coordinate := Vector2(
		(float(pixel.x) + 0.5) / float(maxi(size.x, 1)) * 2.0
			* float(size.x) / float(maxi(size.y, 1)) - float(size.x) / float(maxi(size.y, 1)),
		(float(pixel.y) + 0.5) / float(maxi(size.y, 1)) * 2.0 - 1.0)
	var nearest := INF
	for operation in snapshot.operations:
		var operation_type := int(operation.get("type", Gallery.LINE))
		if operation_type == Gallery.SEGMENT:
			var segment: Vector4 = operation.get("segment", Vector4.ZERO)
			var edge := Vector2(segment.z - segment.x, segment.w - segment.y)
			var parameter := clampf((coordinate - Vector2(segment.x, segment.y)).dot(edge)
					/ maxf(edge.length_squared(), 1.0e-30), 0.0, 1.0)
			nearest = minf(nearest, coordinate.distance_to(
				Vector2(segment.x, segment.y) + edge * parameter))
		else:
			var direction: Vector2 = operation.get("direction", Vector2.RIGHT).normalized()
			var perpendicular := Vector2(-direction.y, direction.x)
			var origin: Vector2 = operation.get("origin", Vector2.ZERO)
			nearest = minf(nearest, absf((coordinate - origin).dot(perpendicular)))
	var epsilon: float = snapshot.brush_radius_px * 2.0 / float(maxi(
			mini(snapshot.reference_size.x, snapshot.reference_size.y), 1))
	if nearest < epsilon * 0.5:
		return "singularity"
	if nearest <= epsilon * snapshot.cutoff_gamma:
		return "cutoff"
	return "core"


static func _smoothstep(edge0: float, edge1: float, value: float) -> float:
	var t := clampf((value - edge0) / maxf(edge1 - edge0, 1.0e-30), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
