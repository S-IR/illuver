import "point.imported.slang";

[[vk::binding(0, 0)]]
cbuffer CameraUBO {
  float4x4 view;
  float4x4 proj;
};

[[vk::binding(1, 0)]]
cbuffer SunUBO {
  float4 sunWorldPos;
  float4 sunColor;
  float4x4 lightVP;
}

[[vk::binding(2, 0)]]
Sampler2DShadow shadowMap;

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
  float4 shadowCoord : TEXCOORD2;
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
  VertexOutput output;
  output.worldPos = input.position;
  float4 viewPos = mul(view, float4(input.position, 1.0));
  output.position = mul(proj, viewPos);
  output.color = pointFinalColor(uint16_t(input.pointVal));
  output.normal = input.normal;

  output.shadowCoord = mul(lightVP, float4(input.position, 1.0));
  return output;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target0 {
  if (pc.isPointPass != 0) {
    return float4(0.0, 0.0, 0.0, 1.0);
  }
  float2 uv = (input.shadowCoord.xy / input.shadowCoord.w) * 0.5 + 0.5;
  float depth = input.shadowCoord.z / input.shadowCoord.w;
  float shadow = shadowMap.SampleCmp(uv, depth - 0.005);

  float3 surfaceColor = input.color.xyz;

  float sunAmbientStr = 0.15;
  float3 ambient = sunAmbientStr * surfaceColor;

  // diffuse
  float3 lightVec = sunWorldPos.xyz - input.worldPos;
  float distance = length(lightVec);
  float3 lightDir = lightVec / distance;

  // float attenuation =
  // 1.0 / (1.0 + 0.09 * distance + 0.032 * distance * distance);
  float attenuation = 1.0;

  float3 normal = normalize(input.normal);
  float diff = max(dot(lightDir, normal), 0.0);
  float3 diffuse = diff * surfaceColor * sunColor.rgb * attenuation;

  float3 cameraPos = -mul(view[3].xyz, (float3x3)view);
  // specular
  float3 viewDir = normalize(cameraPos - input.worldPos);
  float spec = 0.0;
  if (diff > 0.0) {
    float3 halfwayDir = normalize(lightDir + viewDir);
    float sunSpecularStr = 0.12;
    spec = pow(max(dot(normal, halfwayDir), 0.0), sunSpecularStr);
  }
  float3 specular = spec * 0.3 * sunColor.xyz * attenuation;

  return float4(ambient + shadow * (diffuse + specular), 1.0);
}
