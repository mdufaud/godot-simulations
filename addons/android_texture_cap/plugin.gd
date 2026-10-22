@tool
extends EditorPlugin

const TextureCapExport := preload("res://addons/android_texture_cap/texture_cap_export.gd")

var _export_plugin: EditorExportPlugin


func _enter_tree() -> void:
	_export_plugin = TextureCapExport.new()
	add_export_plugin(_export_plugin)


func _exit_tree() -> void:
	remove_export_plugin(_export_plugin)
	_export_plugin = null
