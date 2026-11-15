// 360PC-Engine (from Love360) - default vertex shader of love.graphics (vs_3_0, Xbox 360).
// Positions arrive in screen pixels (transformed on the CPU, like LOVE 11).
// c0-c3 = orthographic projection (one row per register, M * v).
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
};

VSOutput main(VSInput input)
{
    VSOutput output;
    output.position = mul(transform_projection, input.position);
    output.uv = input.uv;
    output.colour = input.colour;
    return output;
}
