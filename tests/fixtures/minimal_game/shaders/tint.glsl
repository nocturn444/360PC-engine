// Example shader: blends what is drawn towards a tint colour. Runs as it is on LÖVE 11.x; for
// the console it is declared in game.lua and built with tools/shaders (docs/SHADERS.md).
extern vec4 tint;
extern number amount;

vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
{
    vec4 pixel = Texel(tex, texture_coords) * color;
    return vec4(mix(pixel.rgb, pixel.rgb * tint.rgb, amount), pixel.a);
}
