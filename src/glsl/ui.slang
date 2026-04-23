// slangc ui.slang -target spirv -o ui.vert.spv -entry vertexMain -stage vertex
// slangc ui.slang -target spirv -o ui.frag.spv -entry fragmentMain -stage fragment

enum Mode : uint {
    Solid = 0,
    Text  = 1,
    Image = 2
};

struct PushConstants {
    float4x4 ortho;
    float4   color;
    float    pxRange;
    Mode     mode;
};

[[vk::push_constant]] PushConstants pc;

// Combined image sampler (matches GLSL sampler2D)
[[vk::binding(0, 0)]] Sampler2D fontAtlas;

struct VertexInput {
    [[vk::location(0)]] float2 inPos : POSITION;
    [[vk::location(1)]] float2 inUV  : TEXCOORD0;
};

struct VertexOutput {
    float4 position : SV_Position;
    float2 uv       : TEXCOORD0;
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    VertexOutput output;
    output.position = mul(pc.ortho, float4(input.inPos, 0.0, 1.0));
    output.uv = input.inUV;
    return output;
}

float median(float3 v) {
    return max(min(v.r, v.g), min(max(v.r, v.g), v.b));
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target0 {
    if (pc.mode == Mode::Solid) {
        return pc.color;
    }

    if (pc.mode == Mode::Image) {
        float4 texColor = fontAtlas.Sample(input.uv);
        return texColor * pc.color;
    }

    // SDF Text
    float3 texSample = fontAtlas.Sample(input.uv).rgb;
    float sigDist = median(texSample) - 0.5;
    float opacity = clamp(sigDist * pc.pxRange + 0.5, 0.0, 1.0);
    if (opacity < 0.01) discard;
    return float4(pc.color.rgb, pc.color.a * opacity);
}
