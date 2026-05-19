[[vk::binding(0, 0)]]
cbuffer SunUBO {
    float4x4 lightVP[4];
    float4   sunWorldPos;
    float4   sunColor;
    float4   cascadeSplits;
}
struct PC { uint cascadeIndex; };
[[vk::push_constant]] PC pc;

struct VSIn {
  [[vk::location(0)]]
  float3 pos : POSITION;
}

[shader("vertex")]
float4 vertexMain(VSIn i) : SV_Position {
    return mul(lightVP[pc.cascadeIndex], float4(i.pos, 1.0));
}
