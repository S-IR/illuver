#version 450

#define SOLID_MODE 0
#define TEXT_MODE 1
layout(push_constant) uniform PushConstants {
    mat4 ortho;
    vec4 color;
    float pxRange;
    uint mode;
} pc;

#ifdef VERTEX
layout(location = 0) in vec2 inPos;
layout(location = 1) in vec2 inUV;

layout(location = 0) out vec2 outUV;
void main() {
    gl_Position = pc.ortho * vec4(inPos, 0.0, 1.0);
    outUV = inUV;
}
#endif

#ifdef FRAGMENT
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0) uniform sampler2D fontAtlas;

float median(vec3 v) {
    return max(min(v.r, v.g), min(max(v.r, v.g), v.b));
}

void main() {
    if (pc.mode == SOLID_MODE) {
        out_color = pc.color;
        return;
    }

    // SDF TEXT (original)
    vec3 textureSampler = texture(fontAtlas, uv).rgb;
    float sigDist = median(textureSampler) - 0.5;
    float opacity = clamp(sigDist * pc.pxRange + 0.5, 0.0, 1.0);
    if (opacity < 0.01) discard;
    out_color = vec4(pc.color.rgb, pc.color.a * opacity);
}
#endif
