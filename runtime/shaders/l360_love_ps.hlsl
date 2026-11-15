// 360PC-Engine (from Love360) - default pixel stage (texture times colour) with the input of
// the generated shaders (uv, colour, screen): used by game shaders that only have position().
// c7 = 0 (set by the runtime) keeps every input alive, as in tools/shaders/glsl2hlsl.py.
sampler2D s0 : register(s0);
float4 l360_zero : register(c7);

struct PSInput
{
    float2 uv     : TEXCOORD0;
    float4 colour : COLOR0;
    float2 screen : TEXCOORD1;
};

float4 main(PSInput input) : COLOR
{
    float4 r = tex2D(s0, input.uv) * input.colour;
    return r + l360_zero.x * float4(input.screen, input.uv);
}
