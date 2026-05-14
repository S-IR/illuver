import "point.imported.slang";

[[vk::binding(0, 0)]]
cbuffer CameraUBO {
  float4x4 view;
  float4x4 proj;
};

[[vk::binding(1, 0)]]
cbuffer SunUBO {
  float4 sunDir;
  float4 sunColor; // rgb = color, a = intensity
  float4 ambientColor;
  float4x4 lightViewProj; // <-- new
}

[[vk::binding(2, 0)]]
Sampler2DShadow shadowMap; // combined image + sampler

float ShadowFactor(float3 worldPos) {
  float4 lightClip = mul(lightViewProj, float4(worldPos, 1.0));
  float3 proj = lightClip.xyz / lightClip.w;
  float2 uv = proj.xy * 0.5 + 0.5;
  float depth = proj.z; // not *0.5+0.5

  if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 || depth > 1.0)
    return 1.0;

  float bias = 0.002;
  return shadowMap.SampleCmpLevelZero(uv, depth - bias);
}

struct PushConstants {
  uint isPointPass;
};
[[vk::push_constant]]
PushConstants pc;

struct VertexInput {
  [[vk::location(0)]]
  float3 position : POSITION;
  [[vk::location(1)]]
  float3 normal : NORMAL;
  [[vk::location(2)]]
  uint pointVal : TEXCOORD0;
};
struct VertexOutput {
  float4 position : SV_Position;
  nointerpolation float4 color : COLOR0;
  float3 normal : NORMAL0;
  float3 worldPos : TEXCOORD1;
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
  VertexOutput output;
  output.worldPos = input.position;
  float4 viewPos = mul(view, float4(input.position, 1.0));
  output.position = mul(proj, viewPos);
  output.color = pointFinalColor(uint16_t(input.pointVal));
  output.normal = input.normal;
  return output;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target0 {
  if (pc.isPointPass != 0) {
    return float4(0.0, 0.0, 0.0, 1.0);
  }

  return input.color;
}
