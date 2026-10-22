@tool
extends EditorExportPlugin
## Android exports only: an imported texture longer than MAX_SIZE_PX on either side
## ships downscaled, in the compression mode its .import chose. Desktop exports and
## the project's imports are untouched.

const MAX_SIZE_PX := 1024
const FEATURE := "android"

# ResourceImporterTexture::CompressMode.
const COMPRESS_LOSSLESS := 0
const COMPRESS_LOSSY := 1
const COMPRESS_VRAM_COMPRESSED := 2
const COMPRESS_BASIS_UNIVERSAL := 4


func _get_name() -> String:
	return "AndroidTextureCap"


func _begin_customize_resources(_platform: EditorExportPlatform,
		features: PackedStringArray) -> bool:
	return features.has(FEATURE)


func _get_customization_configuration_hash() -> int:
	return (get_script() as Script).source_code.hash()


func _customize_resource(resource: Resource, path: String) -> Resource:
	# An empty path is a reference held by another resource: the file itself is
	# customized on its own, and the reference then loads the smaller one.
	var texture := resource as CompressedTexture2D
	if path.is_empty() or texture == null \
			or maxi(texture.get_width(), texture.get_height()) <= MAX_SIZE_PX:
		return null
	var import := ConfigFile.new()
	if import.load(path + ".import") != OK:
		return null
	var compress_mode: int = import.get_value("params", "compress/mode", COMPRESS_LOSSLESS)
	var normal_map: bool = import.get_value("params", "compress/normal_map", 0) == 1
	var lossy_quality: float = import.get_value("params", "compress/lossy_quality", 0.7)

	var image := texture.get_image()
	if image.is_compressed():
		image.decompress()
	var had_mipmaps := image.has_mipmaps()
	var scale := float(MAX_SIZE_PX) / float(maxi(image.get_width(), image.get_height()))
	image.resize(maxi(1, roundi(image.get_width() * scale)),
		maxi(1, roundi(image.get_height() * scale)), Image.INTERPOLATE_TRILINEAR)
	if had_mipmaps:
		image.generate_mipmaps(normal_map)
	else:
		image.clear_mipmaps()

	# WebP and the block compressors only take 8-bit channels: HDR and 16-bit stay raw.
	if image.get_format() > Image.FORMAT_RGBA8:
		return ImageTexture.create_from_image(image)
	var portable := PortableCompressedTexture2D.new()
	match compress_mode:
		COMPRESS_LOSSLESS:
			portable.create_from_image(image, PortableCompressedTexture2D.COMPRESSION_MODE_LOSSLESS)
		COMPRESS_LOSSY:
			portable.create_from_image(image, PortableCompressedTexture2D.COMPRESSION_MODE_LOSSY,
				normal_map, lossy_quality)
		COMPRESS_VRAM_COMPRESSED:
			portable.create_from_image(image, PortableCompressedTexture2D.COMPRESSION_MODE_ETC2,
				normal_map)
		COMPRESS_BASIS_UNIVERSAL:
			portable.create_from_image(image,
				PortableCompressedTexture2D.COMPRESSION_MODE_BASIS_UNIVERSAL, normal_map)
		_:
			return ImageTexture.create_from_image(image)
	return portable
