extends SceneTree
## Regenerates resources/ambient_fluid/plate_bem.tres from the same BoxMesh the
## ambient fluid demo uses for its plate (scripts/demos/ambient_fluid_controller.gd).
##   godot --headless --path . -s tools/regenerate_ambient_profile.gd

const PROFILE_PATH := "res://resources/ambient_fluid/plate_bem.tres"
const PLATE_SIZE := Vector3(2.4, 0.18, 1.2)
const WATER_DENSITY_KG_M3 := 998.0


func _initialize() -> void:
	var box := BoxMesh.new()
	box.size = PLATE_SIZE
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, box.get_mesh_arrays())
	var profile: AmbientFluidProfile3D = AmbientFluidPreprocessor.build_profile(
		mesh, WATER_DENSITY_KG_M3)
	if profile == null:
		push_error("BEM build failed: %s" % AmbientFluidPreprocessor.get_last_error())
		quit(1)
		return
	var tensor := profile.added_mass_tensor
	print("translation diagonals x=%.3f y=%.3f z=%.3f" % [
		tensor[21], tensor[28], tensor[35]])
	print("rotation diagonals x=%.3f y=%.3f z=%.3f" % [
		tensor[0], tensor[7], tensor[14]])
	print("source offset %.4f m" % profile.source_offset_m)
	# The plate is thin along y: broadside (y) must dominate the translation.
	if tensor[28] <= tensor[21] or tensor[28] <= tensor[35]:
		push_error("broadside (y) added mass is not dominant")
		quit(1)
		return
	var save_error := AmbientFluidPreprocessor.save_profile(profile, PROFILE_PATH)
	if save_error != "":
		push_error("save failed: %s" % save_error)
		quit(1)
		return
	print("TEST PASS regenerate_ambient_profile")
	quit(0)
