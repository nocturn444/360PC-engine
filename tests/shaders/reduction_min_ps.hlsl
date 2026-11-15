// Our own test stencil: keep samples and order, bound the temporaries of xost.
sampler2D s0 : register(s0);
float4 l360_zero : register(c7);
struct Entrada { float2 uv : TEXCOORD0; };
float4 main(Entrada entrada) : COLOR0
{
    float suma = 0.0;
    int radio = 2;
    int cantidad = 0;
    float muestra = 0.0;
    for (int x = -radio; x <= radio; ++x) {
        for (int y = -radio; y <= radio; ++y) {
            muestra = tex2D(s0, entrada.uv + 0.02 * float2(float(x), float(y))).a;
            if (muestra < 0.6) {
                cantidad += 1;
                suma = suma + muestra;
            }
        }
    }
    return float4(suma, float(cantidad), 0.0, 1.0);
}
