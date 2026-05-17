// slangc rotating.slang -target spirv -o rotating.vert.spv -entry vertexMain -stage vertex
// slangc rotating.slang -target spirv -o rotating.frag.spv -entry fragmentMain -stage fragment

struct RotatePushConstants {
    float3 center;
    float  time;
};

[[vk::push_constant]] RotatePushConstants push;

[[vk::binding(0, 0)]] cbuffer CameraUBO {
    float4x4 view;
    float4x4 proj;
};

struct VertexInput {
    [[vk::location(0)]] float3 inPosition : POSITION;
};

struct VertexOutput {
    float4 position : SV_Position;
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    VertexOutput output;

    float angle = push.time;
    float c = cos(angle);
    float s = sin(angle);

    float3x3 rotY = float3x3(
        c,  0.0, s,
        0.0, 1.0, 0.0,
        -s, 0.0, c
    );

    float3 localPos = mul(rotY, input.inPosition);
    float3 worldPos = localPos + push.center;

    float4 viewPos = mul(view, float4(worldPos, 1.0));
    output.position = mul(proj, viewPos);
    return output;
}

[shader("fragment")]
float4 fragmentMain() : SV_Target0 {
    return float4(0.0, 0.85, 1.0, 0.35);
}
