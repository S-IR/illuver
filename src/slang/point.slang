import "point.imported.slang";

[[vk::binding(0, 0)]]
cbuffer CameraUBO {
  float4x4 view;
  float4x4 proj;
};

[[vk::binding(1, 0)]]
cbuffer SunUBO {
    float4x4 lightVP[4];
    float4   sunWorldPos;
    float4   sunColor;
    float4   cascadeSplits;
}

[[vk::binding(2, 0)]]
Sampler2DArrayShadow shadowMap;

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
  float4 baseCol = pointFinalColor(uint16_t(input.pointVal));
  output.color = baseCol;
  output.normal = input.normal;

  return output;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target0 {
  if (pc.isPointPass != 0) {
    return float4(0.0, 0.0, 0.0, 1.0);
  }
  float3 fragViewPos = mul(view, float4(input.worldPos, 1.0)).xyz;
  float depthVS = -fragViewPos.z;
  int cascade = 3;
  if      (depthVS < cascadeSplits.x) cascade = 0;
  else if (depthVS < cascadeSplits.y) cascade = 1;
  else if (depthVS < cascadeSplits.z) cascade = 2;

  float4 shadowCoord = mul(lightVP[cascade], float4(input.worldPos, 1.0));
  float2 uv = (shadowCoord.xy / shadowCoord.w) * 0.5 + 0.5;
  float depth = shadowCoord.z / shadowCoord.w;
  float  shadow = shadowMap.SampleCmp(float3(uv, float(cascade)), depth - 0.005);

  float3 surfaceColor = input.color.xyz;

  float sunAmbientStr = 0.22;
  float3 ambient = sunAmbientStr * surfaceColor * float3(0.75, 0.88, 1.0);

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
    float sunSpecularStr = 48.0;
    spec = pow(max(dot(normal, halfwayDir), 0.0), sunSpecularStr);
  }
  float3 specular = spec * 0.3 * sunColor.xyz * attenuation;

  float3 hdrColor = ambient + shadow * (diffuse + specular);
  // ACES filmic tonemapping
  float3 x = hdrColor;
  float3 mapped = clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
  return float4(mapped, input.color.w);
}
