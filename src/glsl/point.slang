import "point.imported.slang";

[[vk::binding(0, 0)]]
cbuffer CameraUBO {
  float4x4 view;
  float4x4 proj;
};
struct PushConstants {
  uint isPointPass;
};
[[vk::push_constant]]
PushConstants pc;

struct VertexInput {
  [[vk::location(0)]]
  float3 position : POSITION;
  [[vk::location(1)]]
  uint pointVal : TEXCOORD0;
};
struct VertexOutput {
  float4 position : SV_Position;
  nointerpolation float4 color : COLOR0;
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
  VertexOutput output;
  float4 viewPos = mul(view, float4(input.position, 1.0));
  output.position = mul(proj, viewPos);
  output.color = pointFinalColor(uint16_t(input.pointVal));
  return output;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target0 {
  if (pc.isPointPass != 0) {
    return float4(0.0, 0.0, 0.0, 1.0);
  }
  return input.color;
}
