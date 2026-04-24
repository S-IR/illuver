import "point.imported.slang";

[[vk::binding(0, 0)]]
ByteAddressBuffer pointsBuffer; // point types
[[vk::binding(1, 0)]]
RWByteAddressBuffer vertsOut; // float3 + u32 (point type padded)
// [[vk::binding(2, 0)]] RWByteAddressBuffer colorsOut; // vec4 array (16 bytes
// per element)
[[vk::binding(2, 0)]]
RWByteAddressBuffer counter; // uint vertexCount
[[vk::binding(3, 0)]]
cbuffer ChunkInfo {
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
uint16_t getPoint(int3 cell) {
  if (cell.x < 0 || cell.x >= VERTS_PER_X_DIR)
    return uint16_t(PointType::Air);
  if (cell.y < 0 || cell.y >= VERTS_PER_Y_DIR)
    return uint16_t(PointType::Air);
  if (cell.z < 0 || cell.z >= VERTS_PER_Z_DIR)
    return uint16_t(PointType::Air);
  uint idx = cell.x * VERT_STRIDE_X + cell.y * VERT_STRIDE_Y + cell.z;
  return pointsBuffer.Load<uint16_t>(idx * 2);
}
float3 calculateJitter(int3 world) {
  uint h = uint(world.x) * 0x9e3779b9u + uint(world.y) * 0x85ebca6bu +
           uint(world.z) * 0x27d4eb2du + seed;

  h = (h ^ (h >> 13)) * 0x9e3779b9u;

  float fx = float(h & 0xFFFFu) * (1.0 / 65536.0) - 0.5;
  float fy = float((h >> 16) & 0xFFFFu) * (1.0 / 65536.0) - 0.5;
  float fz = float((h >> 24) & 0xFFu) * (1.0 / 256.0) - 0.5;

  return float3(fx, fy, fz) * 0.5;
}

float3 worldPosition(int3 local) {
  int3 world = chunkMin.xyz + local;
  return float3(world) + calculateJitter(world);
}

static const int3 triVerts[6][3] = {
  { int3(0, 0, 0), int3(1, 0, 0), int3(1, 1, 0) },
  { int3(0, 0, 0), int3(1, 1, 0), int3(0, 1, 0) },
  { int3(0, 0, 0), int3(0, 0, 1), int3(0, 1, 1) },
  { int3(0, 0, 0), int3(0, 1, 1), int3(0, 1, 0) },
  { int3(0, 0, 0), int3(1, 0, 0), int3(1, 0, 1) },
  { int3(0, 0, 0), int3(1, 0, 1), int3(0, 0, 1) }
};

static const int3 neighborOffsets[26] = {
  int3(1, 0, 0),   int3(-1, 0, 0),  int3(0, 1, 0),  int3(0, -1, 0),
  int3(0, 0, 1),   int3(0, 0, -1),  int3(1, 1, 0),  int3(1, -1, 0),
  int3(-1, 1, 0),  int3(-1, -1, 0), int3(1, 0, 1),  int3(1, 0, -1),
  int3(-1, 0, 1),  int3(-1, 0, -1), int3(0, 1, 1),  int3(0, 1, -1),
  int3(0, -1, 1),  int3(0, -1, -1), int3(1, 1, 1),  int3(1, 1, -1),
  int3(1, -1, 1),  int3(1, -1, -1), int3(-1, 1, 1), int3(-1, 1, -1),
  int3(-1, -1, 1), int3(-1, -1, -1)
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
void main(uint3 id: SV_DispatchThreadID) {
  int3 cell = int3(id);
  // if (id.x == 0 && id.y == 0 && id.z == 0) {
  //   // Store the first cell's point value into counter just to see it
  //   counter.Store(0, uint(getPoint(int3(0, 0, 0))));
  //   return; // then exit, to keep it simple
  // }

  if (cell.x >= CUBES_PER_X_DIR || cell.y >= CUBES_PER_Y_DIR ||
      cell.z >= CUBES_PER_Z_DIR)
    return;

  uint16_t p000 = getPoint(cell);
  if (getPointType(p000) == PointType::Air) {
    return;
  }

  if (isSurrounded(cell)) {
    return;
  }

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

    uint offset = vIdx * 16; // 16 bytes per vertex
    vertsOut.Store3(offset + 0, asuint(pos0));
    vertsOut.Store(offset + 12, uint(p0));
    vertsOut.Store3(offset + 16, asuint(pos1));
    vertsOut.Store(offset + 28, uint(p1));
    vertsOut.Store3(offset + 32, asuint(pos2));
    vertsOut.Store(offset + 44, uint(p2));
  }
}
