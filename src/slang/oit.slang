
import "point.imported.slang";

[[vk::binding(0, 0)]]
cbuffer CameraUBO {
  float4x4 view;
  float4x4 proj;
};

struct PushConstants {
  float nearPlane;
  float farPlane;
};

[[vk::push_constant]]
PushConstants pc;

struct VSInput {
  [[vk::location(0)]] float3 pos   : POSITION;
  [[vk::location(1)]] uint   val  : TEXCOORD0;
};
struct VSOutput {
  float4 pos      : SV_Position;
  nointerpolation float4 color : COLOR0;
  float3 worldPos : TEXCOORD1;
};

[shader("vertex")]
VSOutput vertexMain(VSInput i) {
  VSOutput o;
  o.worldPos = i.pos;
  o.pos = mul(proj, mul(view, float4(i.pos, 1.0)));
  o.color = pointFinalColor(uint16_t(i.val));
  return o;
}

struct TranspOutput {
  [[vk::location(1)]] float4 accum  : SV_Target1;
  [[vk::location(2)]] float  reveal : SV_Target2;
};
[shader("fragment")]
TranspOutput fragmentMain(VSOutput i) {
  float d = mul(view, float4(i.worldPos, 1.0)).z;
  float nr = pc.farPlane - pc.nearPlane;
  float w = i.color.a * max(1e-2, min(3e3,
      10.0 / (1e-5 + pow(d/(nr*0.03),2) + pow(d/nr,4)) ));
  TranspOutput o;
  o.accum  = float4(i.color.rgb * i.color.a, i.color.a) * w;
  o.reveal = i.color.a;
  return o;
}
