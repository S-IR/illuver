[[vk::binding(0, 0)]] cbuffer CameraUBO {
    float4x4 view;
    float4x4 proj;
};
struct PushConstants {
    uint isPointPass;
};
[[vk::push_constant]] PushConstants pc;
static const uint TYPE_MASK    = 1023u;
static const uint ENERGY_MASK  = 3u;
static const uint LIGHT_SHIFT  = 10;
static const uint LIFE_SHIFT   = 12;
static const uint WISDOM_SHIFT = 14;

float3 baseColor(uint type) {
    switch (type) {
        case 1:  return float3(159, 112,  75) / 255.0;
        case 2:  return float3( 36,  19,  97) / 255.0;
        case 3:  return float3(141,  97, 237) / 255.0;
        case 4:  return float3(  0, 236, 231) / 255.0;
        case 5:  return float3( 31,  22,  25) / 255.0;
        case 6:  return float3(229, 108, 125) / 255.0;
        case 7:  return float3(218, 189, 252) / 255.0;
        case 8:  return float3( 68, 131, 129) / 255.0;
        default: return float3(0.0);
    }
}
float3 energyToColor(uint p) {
    uint light  = (p >> LIGHT_SHIFT)  & ENERGY_MASK;
    uint life   = (p >> LIFE_SHIFT)   & ENERGY_MASK;
    uint wisdom = (p >> WISDOM_SHIFT) & ENERGY_MASK;
    return float3(float(light)/3.0, (float(light)+float(life))/3.0, float(wisdom)/3.0);
}
float3 pointToColor(uint p) {
    uint type = p & TYPE_MASK;
    return baseColor(type) * 0.9 + energyToColor(p) * 0.1;
}

struct VertexInput {
    [[vk::location(0)]] float3 position : POSITION;
    [[vk::location(1)]] uint   pointVal : TEXCOORD0;
};
struct VertexOutput {
    float4 position                  : SV_Position;
    nointerpolation float3 color     : COLOR0;
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    VertexOutput output;
    float4 viewPos  = mul(view, float4(input.position, 1.0));
    output.position = mul(proj, viewPos);
    output.color    = pointToColor(input.pointVal);
    return output;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target0 {
    if (pc.isPointPass != 0) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }
    return float4(input.color, 1.0);
}
