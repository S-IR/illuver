// shadow.vertex.slang
[[vk::push_constant]]
cbuffer ShadowPC { float4x4 lightViewProj; };

struct VSInput {
  [[vk::location(0)]]
  float3 position : POSITION;
};

struct VSOutput {
  float4 clipPos : SV_Position;
};

[shader("vertex")]
VSOutput vertexMain(VSInput input) {
  VSOutput output;
  output.clipPos = mul(lightViewProj, float4(input.position, 1.0));
  return output;
}
