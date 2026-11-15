// 360PC-Engine (from Love360) - default pixel shader of love.graphics (ps_3_0, Xbox 360):
// texture times colour, like LOVE's default shader. Shapes without a texture use a white one.
sampler2D s0 : register(s0);

struct PSInput
{
    float2 uv     : TEXCOORD0;
    float4 colour : COLOR0;
};

float4 main(PSInput input) : COLOR
{
    return tex2D(s0, input.uv) * input.colour;
}
