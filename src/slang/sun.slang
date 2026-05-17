[[vk::binding(0, 0)]]
cbuffer CameraUBO {
  float4x4 view;
  float4x4 proj;
}

struct SunPC {
  float3 worldPos;
}
[[vk::push_constant]]
SunPC pc;

struct VSIn {
  [[vk::location(0)]]
  float3 pos : POSITION;
}
struct VSOut {
  float4 clipPos : SV_Position;
}
static float sunSize = 50.0;

[shader("vertex")]
VSOut vertexMain(VSIn i) {
  VSOut o;
  float3 wp = i.pos * sunSize + pc.worldPos;
  o.clipPos = mul(proj, mul(view, float4(wp, 1.0)));
  return o;
}
[shader("fragment")]
float4 fragmentMain(VSOut i) : SV_Target0 {
  return float4(1.0, 0.95, 0.55, 1.0);
}
