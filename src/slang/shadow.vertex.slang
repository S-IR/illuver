[[vk::binding(0, 0)]]
cbuffer SunUBO {
  float4 sunWorldPos;
  float4 sunColor;
  float4x4 lightVP;
}

struct VSIn {
  [[vk::location(0)]]
  float3 pos : POSITION;
}

[shader("vertex")]
float4 vertexMain(VSIn i) : SV_Position {
  return mul(lightVP, float4(i.pos, 1.0));
}
