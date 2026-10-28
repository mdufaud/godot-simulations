extends SceneTree

const WATER_DENSITY_KG_M3 := 998.0


func _initialize() -> void:
	var profiles := [
		{
			"path": "res://resources/ambient_fluid/sphere_bem.tres",
			"mesh": AmbientFluidShapes.bem_mesh(AmbientFluidShapes.Kind.SPHERE),
		},
		{
			"path": "res://resources/ambient_fluid/body_bem.tres",
			"mesh": AmbientFluidShapes.bem_mesh(AmbientFluidShapes.Kind.BOX),
		},
		{
			"path": "res://resources/ambient_fluid/plate_bem.tres",
			"mesh": AmbientFluidShapes.bem_mesh(AmbientFluidShapes.Kind.PLATE),
		},
	]
	for item in profiles:
		var profile: AmbientFluidProfile3D = AmbientFluidPreprocessor.build_profile(
			item.mesh, WATER_DENSITY_KG_M3)
		if profile == null:
			push_error("BEM build failed for %s: %s" % [
				item.path, AmbientFluidPreprocessor.get_last_error()])
			quit(1)
			return
		var tensor := profile.added_mass_tensor
		var displaced := WATER_DENSITY_KG_M3 * profile.volume_m3
		print("%s: %d faces, translation added-mass coefficients x=%.4f y=%.4f z=%.4f" % [
			item.path, profile.face_centers_m.size(), tensor[21] / displaced,
			tensor[28] / displaced, tensor[35] / displaced])
		if item.path.ends_with("plate_bem.tres") \
				and (tensor[28] <= tensor[21] or tensor[28] <= tensor[35]):
			push_error("plate broadside (y) added mass is not dominant")
			quit(1)
			return
		var save_error := AmbientFluidPreprocessor.save_profile(profile, item.path)
		if save_error != "":
			push_error("save failed for %s: %s" % [item.path, save_error])
			quit(1)
			return
	print("TEST PASS regenerate_ambient_profile")
	quit(0)
