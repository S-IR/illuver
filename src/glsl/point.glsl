#version 450

#ifdef VERTEX
layout(set = 0, binding = 0) uniform CameraUBO {
    mat4 view;
    mat4 proj;
};

layout(location = 0) in vec3 inPosition;

void main() {
    vec4 viewVector = view * vec4(inPosition, 1.0);
    vec4 projVector = proj * viewVector;
    gl_Position = projVector;
}
#endif

#ifdef FRAGMENT
layout(set = 0, binding = 1) readonly buffer TriangleColorsSBO {
    vec4 colors[];
};

layout(location = 0) out vec4 outColor;

void main() {
    outColor = colors[gl_PrimitiveID];
}
#endif
