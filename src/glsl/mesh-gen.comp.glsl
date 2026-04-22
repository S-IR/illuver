#version 450
#extension GL_EXT_shader_16bit_storage : require
#extension GL_EXT_shader_explicit_arithmetic_types_int16 : require
#extension GL_EXT_scalar_block_layout : require

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

#define VERTS_PER_X_DIR 16
#define VERTS_PER_Y_DIR 256
#define VERTS_PER_Z_DIR 16
#define CUBES_PER_X_DIR 15
#define CUBES_PER_Y_DIR 255
#define CUBES_PER_Z_DIR 15
#define VERT_STRIDE_X VERTS_PER_Z_DIR * VERTS_PER_Y_DIR
#define VERT_STRIDE_Y VERTS_PER_Z_DIR

#define TYPE_MASK        1023u
#define ENERGY_MASK      3u
#define LIGHT_SHIFT      10
#define LIFE_SHIFT       12
#define WISDOM_SHIFT     14

#define PT_AIR                 uint16_t(0)
#define PT_YELLOW_DIRT         uint16_t(1)
#define PT_PURPLE_GROUND       uint16_t(2)
#define PT_LIGHT_PURPLE_GROUND uint16_t(3)
#define PT_BLUE_DIAMOND        uint16_t(4)
#define PT_BLACK_CLIFF         uint16_t(5)
#define PT_PINK_TRUNK          uint16_t(6)
#define PT_WHITE_TREE_LEAF     uint16_t(7)
#define PT_WATER               uint16_t(8)

layout(set = 0, binding = 0) readonly buffer PointsIn {
    uint16_t points[];
};

layout(scalar, set = 0, binding = 1) writeonly buffer VertsOut {
    vec3 verts[];
};
layout(set = 0, binding = 2) writeonly buffer ColOut {
    vec4 colors[];
};
layout(set = 0, binding = 3) buffer Counters {
    uint vertexCount;
    uint triCount;
};
layout(set = 0, binding = 4) uniform ChunkInfo {
    ivec4 chunkMin;
    uint seed;
};

uint16_t getPoint(ivec3 cell) {
    if (cell.x < 0 || cell.x >= VERTS_PER_X_DIR) return PT_AIR;
    if (cell.y < 0 || cell.y >= VERTS_PER_Y_DIR) return PT_AIR;
    if (cell.z < 0 || cell.z >= VERTS_PER_Z_DIR) return PT_AIR;
    uint idx = cell.x * VERT_STRIDE_X + cell.y * VERT_STRIDE_Y + cell.z;
    return points[idx];
}
uint getPointType(uint16_t p) {
    return uint(p) & TYPE_MASK;
}
uint getLight(uint16_t p) {
    return (uint(p) >> LIGHT_SHIFT) & ENERGY_MASK;
}
uint getLife(uint16_t p) {
    return (uint(p) >> LIFE_SHIFT) & ENERGY_MASK;
}
uint getWisdom(uint16_t p) {
    return (uint(p) >> WISDOM_SHIFT) & ENERGY_MASK;
}

vec3 energyToColor(uint16_t p) {
    float light = float(getLight(p)) / 3.0;
    float life = float(getLife(p)) / 3.0;
    float wisdom = float(getWisdom(p)) / 3.0;
    return vec3(light, light + life, wisdom);
}

vec3 baseColor(uint type) {
    switch (type) {
        case PT_YELLOW_DIRT:
        return vec3(159, 112, 75) / 255.0;
        case PT_PURPLE_GROUND:
        return vec3(36, 19, 97) / 255.0;
        case PT_LIGHT_PURPLE_GROUND:
        return vec3(141, 97, 237) / 255.0;
        case PT_BLUE_DIAMOND:
        return vec3(0, 236, 231) / 255.0;
        case PT_BLACK_CLIFF:
        return vec3(31, 22, 25) / 255.0;
        case PT_PINK_TRUNK:
        return vec3(229, 108, 125) / 255.0;
        case PT_WHITE_TREE_LEAF:
        return vec3(218, 189, 252) / 255.0;
        case PT_WATER:
        return vec3(68, 131, 129) / 255.0;
        default:
        return vec3(0.0);
    }
}

vec4 triangleDecideColor(uint16_t p0, uint16_t p1, uint16_t p2) {
    uint types[3] = {
            getPointType(p0),
            getPointType(p1),
            getPointType(p2)
        };
    uint16_t pts[3] = {
            p0,
            p1,
            p2
        };
    vec3 finalColor = vec3(0.0);
    for (int i = 0; i < 3; i++) {
        vec3 base = baseColor(types[i]);
        vec3 energy = energyToColor(pts[i]);
        vec3 combined = base * 0.9 + energy * 0.1;
        finalColor += combined;
    }
    finalColor /= 3.0;
    return vec4(finalColor, 1.0);
}

uint hash31(vec3 p) {
    uvec3 up = uvec3(p);
    uint h = seed;
    h ^= up.x * 0x9e3779b9u + up.y * 0x85ebca6bu + up.z * 0x27d4eb2du;
    h = (h ^ (h >> 13)) * 0x9e3779b9u;
    return h;
}
float hashFloat(vec3 p) {
    return float(hash31(p) & 0xFFFFu) * (1.0 / 65536.0) - 0.5;
}
vec3 jitter(vec3 worldPos) {
    return vec3(hashFloat(worldPos), hashFloat(worldPos + vec3(1, 2, 3)), hashFloat(worldPos + vec3(3, 2, 1))) * 0.5;
}
vec3 worldPosition(ivec3 local) {
    vec3 w = vec3(ivec3(chunkMin) + local);
    return w + jitter(w);
}

const ivec3 triVerts[6][3] = {
        {
            ivec3(0, 0, 0),
            ivec3(1, 0, 0),
            ivec3(1, 1, 0)
        },
        {
            ivec3(0, 0, 0),
            ivec3(1, 1, 0),
            ivec3(0, 1, 0)
        },
        {
            ivec3(0, 0, 0),
            ivec3(0, 0, 1),
            ivec3(0, 1, 1)
        },
        {
            ivec3(0, 0, 0),
            ivec3(0, 1, 1),
            ivec3(0, 1, 0)
        },
        {
            ivec3(0, 0, 0),
            ivec3(1, 0, 0),
            ivec3(1, 0, 1)
        },
        {
            ivec3(0, 0, 0),
            ivec3(1, 0, 1),
            ivec3(0, 0, 1)
        }
    };

const ivec3 neighborOffsets[26] = {
        ivec3(1, 0, 0),
        ivec3(-1, 0, 0),
        ivec3(0, 1, 0),
        ivec3(0, -1, 0),
        ivec3(0, 0, 1),
        ivec3(0, 0, -1),
        ivec3(1, 1, 0),
        ivec3(1, -1, 0),
        ivec3(-1, 1, 0),
        ivec3(-1, -1, 0),
        ivec3(1, 0, 1),
        ivec3(1, 0, -1),
        ivec3(-1, 0, 1),
        ivec3(-1, 0, -1),
        ivec3(0, 1, 1),
        ivec3(0, 1, -1),
        ivec3(0, -1, 1),
        ivec3(0, -1, -1),
        ivec3(1, 1, 1),
        ivec3(1, 1, -1),
        ivec3(1, -1, 1),
        ivec3(1, -1, -1),
        ivec3(-1, 1, 1),
        ivec3(-1, 1, -1),
        ivec3(-1, -1, 1),
        ivec3(-1, -1, -1)
    };

bool isSurrounded(ivec3 cell) {
    for (int i = 0; i < 26; i++) {
        ivec3 neighbour = cell + neighborOffsets[i];
        if (getPointType(getPoint(neighbour)) == PT_AIR) {
            return false;
        }
    }
    return true;
}

void main() {
    ivec3 cell = ivec3(gl_GlobalInvocationID);
    if (cell.x >= CUBES_PER_X_DIR || cell.y >= CUBES_PER_Y_DIR || cell.z >= CUBES_PER_Z_DIR) return;

    uint16_t p000 = getPoint(cell);
    if (getPointType(p000) == PT_AIR) return;
    if (isSurrounded(cell)) return;

    for (int t = 0; t < 6; t++) {
        ivec3 v0 = triVerts[t][0];
        ivec3 v1 = triVerts[t][1];
        ivec3 v2 = triVerts[t][2];

        uint16_t p0 = getPoint(cell + v0);
        uint16_t p1 = getPoint(cell + v1);
        uint16_t p2 = getPoint(cell + v2);

        if (getPointType(p0) == PT_AIR || getPointType(p1) == PT_AIR || getPointType(p2) == PT_AIR) continue;

        uint vIdx = atomicAdd(vertexCount, 3);
        verts[vIdx + 0] = worldPosition(cell + v0);
        verts[vIdx + 1] = worldPosition(cell + v1);
        verts[vIdx + 2] = worldPosition(cell + v2);

        uint triIdx = atomicAdd(triCount, 1);
        colors[triIdx] = triangleDecideColor(p0, p1, p2);
    }
}
// #version 450

// layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

// layout(set = 0, binding = 1) writeonly buffer VertsOut {
//     vec3 verts[];
// };
// layout(set = 0, binding = 2) writeonly buffer ColOut {
//     vec4 colors[];
// };
// layout(set = 0, binding = 3) buffer Counters {
//     uint vertexCount;
//     uint triCount;
// };

// void main() {
//     if (gl_GlobalInvocationID.x == 0) {
//         vertexCount = 3;
//         triCount = 1;
//         verts[0] = vec3(0.0, 0.0, 0.0);
//         verts[1] = vec3(1.0, 0.0, 0.0);
//         verts[2] = vec3(0.0, 1.0, 0.0);
//         colors[0] = vec4(1.0, 0.0, 0.0, 1.0);
//     }
// }
