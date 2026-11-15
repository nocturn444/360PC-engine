// Minimal case of our own: !shadow makes glslang emit OpFUnordLessThanEqual.
float4 P0 : register(c0);
float4 tinta : register(c1);
#define shadow ((P0.z > 0.5))
struct Entrada { float2 uv : TEXCOORD0; };
float4 main(Entrada entrada) : COLOR0
{
    float2 uv = entrada.uv;
    float4 valor = float4(uv, 0.25, 1.0);
    if (!shadow && P0.x > 0.5) {
        if (uv.x < P0.y) {
            valor.rgba = tinta.rgba;
        } else if (tinta.a > 0.0) {
            valor.rgba = tinta.abgr;
        }
    }
    return float4(valor.xyz, shadow ? valor.a : 0.0);
}
