[[vk::binding(0, 0)]] Texture2D accumTex;
[[vk::binding(1, 0)]] Texture2D revealTex;
[[vk::binding(2, 0)]] SamplerState s;

struct VSOut { float4 pos : SV_Position; float2 uv : TEXCOORD0; };

[shader("vertex")]
VSOut vertexMain(uint vid : SV_VertexID) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    VSOut o;
    o.pos = float4(uv * 2.0 - 1.0, 0.0, 1.0);
    o.uv = uv;
    return o;
}

[shader("fragment")]
float4 fragmentMain(float2 uv : TEXCOORD0)
{
    float4 accum = accumTex.Sample(s, uv);
    float reveal = revealTex.Sample(s, uv).r;

    if (abs(accum.a) < 1e-4) discard;
    float3 avgColor = accum.rgb / accum.a;

    return float4(avgColor, 1.0 - reveal);
}
