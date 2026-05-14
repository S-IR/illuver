[[vk::binding(0, 0)]]
cbuffer CameraUBO {
  float4x4 view;
  float4x4 proj;
}

[[vk::binding(1, 0)]]
cbuffer SunUBO {
  float4 sunDir;
  float4 sunColor;
  float4 ambientColor;
}

struct PushConstants {
  float3 sunWorldPos;
  float _pad;
};

[[vk::push_constant]]
PushConstants pc;

struct VertexInput {
  [[vk::location(0)]]
  float3 position : POSITION;
};

struct VertexOutput {
  float4 clipPos : SV_Position;
  float3 localPos : TEXCOORD0; // unit sphere pos = normal
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
  VertexOutput o;
  float3 worldPos = pc.sunWorldPos + input.position * 120;
  o.clipPos = mul(proj, mul(view, float4(worldPos, 1.0)));
  o.localPos = input.position;
  return o;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target0 {
  float3 N = normalize(input.localPos);

  // Crystal facet effect: quantize normal into facets
  float3 facetN = normalize(floor(N * 4.0 + 0.5) / 4.0);

  // Fresnel — brighter at edges, dimmer in center
  float fresnel = 1.0 - abs(dot(N, float3(0, 0, 1)));
  fresnel = pow(fresnel, 2.0);

  // Core glow
  float core = 1.0 - length(N.xy) * 0.6;

  // Tint from sun color, brightest at noon
  float3 crystalColor = lerp(float3(0.8, 0.9, 1.0), // cool crystal base
                             sunColor.rgb * 1.5,    // warm at noon
                             sunColor.a             // intensity = dayness
  );

  // Facet shimmer — different facets catch light differently
  float shimmer = dot(facetN, normalize(float3(1, 1, 0.5))) * 0.5 + 0.5;

  float3 col = crystalColor * (core + fresnel * 0.6 + shimmer * 0.3);

  // Soft alpha at edges so it fades into sky
  float alpha = saturate(core + fresnel * 0.5);

  return float4(col, alpha);

}
