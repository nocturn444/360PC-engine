// 360PC-Engine (from Love360) - vertex stage for game shaders without position() (vs_3_0,
// Xbox 360). Passes uv, colour and the position in screen pixels.
// Constants: c0-c3 projection (one row per register).
row_major float4x4 transform_projection : register(c0);

struct VSInput
{
    float4 position : POSITION;
    float2 uv       : TEXCOORD0;
    float4 colour   : COLOR0;
};

struct VSOutput
{
    float4 position : POSITION;
    float2 uv       : TEXCOORD0;
    float4 colour   : COLOR0;
    float2 screen   : TEXCOORD1;
};

VSOutput main(VSInput input)
{
    VSOutput output;
    output.position = mul(transform_projection, input.position);
    output.uv = input.uv;
    output.colour = input.colour;
    output.screen = input.position.xy;
    return output;
}
