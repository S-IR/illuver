#version 450

#ifdef VERTEX

layout(location = 0) in vec3 inPosition;

layout(push_constant) uniform PushConstants {
    vec3 center;
    float time;
} push;

layout(set = 0, binding = 0) uniform CameraUBO {
    mat4 view;
    mat4 proj;
};

void main() {
    float angle = push.time;
    float c = cos(angle);
    float s = sin(angle);

    mat3 rotY = mat3(
            c, 0.0, s,
            0.0, 1.0, 0.0,
            -s, 0.0, c
        );

    vec3 localPos = rotY * inPosition;
    vec3 worldPos = localPos + push.center;

    gl_Position = proj * view * vec4(worldPos, 1.0);
}
#endif

#ifdef FRAGMENT
layout(location = 0) out vec4 outColor;

void main() {
    outColor = vec4(0.0, 0.85, 1.0, .35);
}
#endif
