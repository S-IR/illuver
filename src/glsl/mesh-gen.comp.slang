
[[vk::binding(0, 0)]] ByteAddressBuffer pointsBuffer; // point types
[[vk::binding(1, 0)]] RWByteAddressBuffer vertsOut; // float3 + u32 (point type padded)
// [[vk::binding(2, 0)]] RWByteAddressBuffer colorsOut; // vec4 array (16 bytes per element)
[[vk::binding(2, 0)]] RWByteAddressBuffer counter;  // uint vertexCount
[[vk::binding(3, 0)]] cbuffer ChunkInfo {
    int4 chunkMin;
    uint seed;
};

static const int VERTS_PER_X_DIR = 16;
static const int VERTS_PER_Y_DIR = 256;
static const int VERTS_PER_Z_DIR = 16;
static const int CUBES_PER_X_DIR = 15;
static const int CUBES_PER_Y_DIR = 255;
static const int CUBES_PER_Z_DIR = 15;
static const int VERT_STRIDE_X = VERTS_PER_Z_DIR * VERTS_PER_Y_DIR;
static const int VERT_STRIDE_Y = VERTS_PER_Z_DIR;

static const uint TYPE_MASK   = 1023u;
static const uint ENERGY_MASK = 3u;
static const uint LIGHT_SHIFT = 10;
static const uint LIFE_SHIFT  = 12;
static const uint WISDOM_SHIFT= 14;

enum PointType : uint16_t {
    Air                 = 0,
    YellowDirt          = 1,
    PurpleGround        = 2,
    LightPurpleGround   = 3,
    BlueDiamond         = 4,
    BlackCliff          = 5,
    PinkTrunk           = 6,
    WhiteTreeLeaf       = 7,
    Water               = 8
};

uint16_t getPoint(int3 cell) {
    if (cell.x < 0 || cell.x >= VERTS_PER_X_DIR) return uint16_t(PointType::Air);
    if (cell.y < 0 || cell.y >= VERTS_PER_Y_DIR) return uint16_t(PointType::Air);
    if (cell.z < 0 || cell.z >= VERTS_PER_Z_DIR) return uint16_t(PointType::Air);
    uint idx = cell.x * VERT_STRIDE_X + cell.y * VERT_STRIDE_Y + cell.z;
    return pointsBuffer.Load<uint16_t>(idx * 2);
}

PointType getPointType(uint16_t p) {
    return PointType(uint(p) & TYPE_MASK);
}
uint getLight(uint16_t p)    { return (uint(p) >> LIGHT_SHIFT)  & ENERGY_MASK; }
uint getLife(uint16_t p)     { return (uint(p) >> LIFE_SHIFT)   & ENERGY_MASK; }
uint getWisdom(uint16_t p)   { return (uint(p) >> WISDOM_SHIFT) & ENERGY_MASK; }

float3 energyToColor(uint16_t p) {
    float light  = float(getLight(p))  / 3.0;
    float life   = float(getLife(p))   / 3.0;
    float wisdom = float(getWisdom(p)) / 3.0;
    return float3(light, light + life, wisdom);
}

float3 baseColor(PointType type) {
    switch (type) {
        case PointType::YellowDirt:          return float3(159, 112, 75)  / 255.0;
        case PointType::PurpleGround:        return float3(36,  19,  97)  / 255.0;
        case PointType::LightPurpleGround:   return float3(141, 97,  237) / 255.0;
        case PointType::BlueDiamond:         return float3(0,   236, 231) / 255.0;
        case PointType::BlackCliff:          return float3(31,  22,  25)  / 255.0;
        case PointType::PinkTrunk:           return float3(229, 108, 125) / 255.0;
        case PointType::WhiteTreeLeaf:       return float3(218, 189, 252) / 255.0;
        case PointType::Water:               return float3(68,  131, 129) / 255.0;
        default:                             return float3(0.0);
    }
}

float4 triangleDecideColor(uint16_t p0, uint16_t p1, uint16_t p2) {
    PointType types[3] = { getPointType(p0), getPointType(p1), getPointType(p2) };
    uint16_t pts[3]   = { p0, p1, p2 };
    float3 finalColor = float3(0.0);
    for (int i = 0; i < 3; i++) {
        // float3 base   = baseColor(types[i]);
        // float3 energy = energyToColor(pts[i]);
        // float3 combined = base * 0.9 + energy * 0.1;
        // finalColor += combined;
        finalColor += baseColor(types[i]);
    }
    finalColor /= 3.0;
    return float4(finalColor, 1.0);
}

float3 calculateJitter(int3 world) {
    uint h = uint(world.x) * 0x9e3779b9u
           + uint(world.y) * 0x85ebca6bu
           + uint(world.z) * 0x27d4eb2du
           + seed;

    h = (h ^ (h >> 13)) * 0x9e3779b9u;

    float fx = float(h & 0xFFFFu)        * (1.0 / 65536.0) - 0.5;
    float fy = float((h >> 16) & 0xFFFFu) * (1.0 / 65536.0) - 0.5;
    float fz = float((h >> 24) & 0xFFu)   * (1.0 / 256.0)  - 0.5;

    return float3(fx, fy, fz) * 0.5;
}

float3 worldPosition(int3 local) {
    int3 world = chunkMin.xyz + local;
    return float3(world) + calculateJitter(world);
}

static const int3 triVerts[6][3] = {
    { int3(0,0,0), int3(1,0,0), int3(1,1,0) },
    { int3(0,0,0), int3(1,1,0), int3(0,1,0) },
    { int3(0,0,0), int3(0,0,1), int3(0,1,1) },
    { int3(0,0,0), int3(0,1,1), int3(0,1,0) },
    { int3(0,0,0), int3(1,0,0), int3(1,0,1) },
    { int3(0,0,0), int3(1,0,1), int3(0,0,1) }
};

static const int3 neighborOffsets[26] = {
    int3(1,0,0),  int3(-1,0,0), int3(0,1,0),  int3(0,-1,0), int3(0,0,1),  int3(0,0,-1),
    int3(1,1,0),  int3(1,-1,0), int3(-1,1,0), int3(-1,-1,0),
    int3(1,0,1),  int3(1,0,-1), int3(-1,0,1), int3(-1,0,-1),
    int3(0,1,1),  int3(0,1,-1), int3(0,-1,1), int3(0,-1,-1),
    int3(1,1,1),  int3(1,1,-1), int3(1,-1,1), int3(1,-1,-1),
    int3(-1,1,1), int3(-1,1,-1),int3(-1,-1,1),int3(-1,-1,-1)
};

bool isSurrounded(int3 cell) {
    for (int i = 0; i < 26; i++) {
        int3 neighbour = cell + neighborOffsets[i];
        if (getPointType(getPoint(neighbour)) == PointType::Air)
            return false;
    }
    return true;
}

[shader("compute")]
[numthreads(8, 8, 8)]
void main(uint3 id : SV_DispatchThreadID) {
    int3 cell = int3(id);
    if (cell.x >= CUBES_PER_X_DIR || cell.y >= CUBES_PER_Y_DIR || cell.z >= CUBES_PER_Z_DIR)
        return;

    uint16_t p000 = getPoint(cell);
    if (getPointType(p000) == PointType::Air)
        return;
    if (isSurrounded(cell))
        return;

    for (int t = 0; t < 6; t++) {
        int3 v0 = triVerts[t][0];
        int3 v1 = triVerts[t][1];
        int3 v2 = triVerts[t][2];

        uint16_t p0 = getPoint(cell + v0);
        uint16_t p1 = getPoint(cell + v1);
        uint16_t p2 = getPoint(cell + v2);

        if (getPointType(p0) == PointType::Air ||
            getPointType(p1) == PointType::Air ||
            getPointType(p2) == PointType::Air)
            continue;

        uint vIdx;
        counter.InterlockedAdd(0, 3, vIdx);

        float3 pos0 = worldPosition(cell + v0);
        float3 pos1 = worldPosition(cell + v1);
        float3 pos2 = worldPosition(cell + v2);

        uint offset = vIdx * 16;   // 16 bytes per vertex
        vertsOut.Store3(offset + 0,  asuint(pos0));
        vertsOut.Store(  offset + 12, uint(p0));
        vertsOut.Store3(offset + 16, asuint(pos1));
        vertsOut.Store(  offset + 28, uint(p1));
        vertsOut.Store3(offset + 32, asuint(pos2));
        vertsOut.Store(  offset + 44, uint(p2));
    }
}
