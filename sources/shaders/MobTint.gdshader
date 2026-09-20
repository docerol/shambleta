shader_type canvas_item;

// Variant tint (mob variants): multiply blend preserving shading.
// Same role as ColorPalette for mobs whose base sprite isn't a gray ramp.
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);

void fragment()
{
	COLOR = texture(TEXTURE, UV) * tint;
}
