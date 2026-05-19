import "point.imported.slang";


[[vk::binding(0, 0)]]
ByteAddressBuffer pointsBuffer;
[[vk::binding(1, 0)]]
RWByteAddressBuffer vertsOut;
[[vk::binding(2, 0)]]
RWByteAddressBuffer counter;
[[vk::binding(3, 0)]]
cbuffer ChunkInfo {
  int4 chunkMin;
  uint seed;
};

static const int VERTS_PER_X_DIR = 16;
static const int VERTS_PER_Y_DIR = 32;
static const int VERTS_PER_Z_DIR = 16;
static const int CUBES_PER_X_DIR = 15;
static const int CUBES_PER_Y_DIR = 31;
static const int CUBES_PER_Z_DIR = 15;
static const int VERT_STRIDE_X = VERTS_PER_Z_DIR * VERTS_PER_Y_DIR;
static const int VERT_STRIDE_Y = VERTS_PER_Z_DIR;

static const uint VERTEX_STRIDE = 32;
static const uint MAX_OPAQUE_VERTS = uint(CUBES_PER_X_DIR * CUBES_PER_Y_DIR * CUBES_PER_Z_DIR * 36);
static const uint TRANSPARENT_COUNTER_BYTE_OFFSET = 4;

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

void writeVert(uint idx, float3 pos, float3 n, uint p) {
  uint o = idx * VERTEX_STRIDE;
  vertsOut.Store3(o,    asuint(pos));
  vertsOut.Store3(o+12, asuint(n));
  vertsOut.Store (o+24, p);
}

static const int3 triVerts[6][3] = {
  { int3(0, 0, 0), int3(1, 1, 0), int3(1, 0, 0) },
  { int3(0, 0, 0), int3(0, 1, 0), int3(1, 1, 0) },
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
    PointType neighbourPointType = getPointType(getPoint(neighbour));
    if (neighbourPointType == PointType::Air)
      return false;
    if (isTransparentPoint(neighbourPointType))
      return false;
  }
  return true;
}

[shader("compute")]
[numthreads(8, 8, 8)]
void main(uint3 id: SV_DispatchThreadID) {
  int3 cell = int3(id);

  if (cell.x >= CUBES_PER_X_DIR || cell.y >= CUBES_PER_Y_DIR ||
      cell.z >= CUBES_PER_Z_DIR)
    return;

  if (getPointType(getPoint(cell)) == PointType::Air)
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

    PointType p0pt = getPointType(p0);
    PointType p1pt = getPointType(p1);
    PointType p2pt = getPointType(p2);

    if (p0pt == PointType::Air || p1pt == PointType::Air || p2pt == PointType::Air)
      continue;

    // bool isTransparent = isTransparentPoint(p0pt) || isTransparentPoint(p1pt) || isTransparentPoint(p2pt);
    bool isTransparent = false;

    uint vIdx;
    if (!isTransparent) {
      counter.InterlockedAdd(0, 6, vIdx);
    } else {
      counter.InterlockedAdd(TRANSPARENT_COUNTER_BYTE_OFFSET, 6, vIdx);
      vIdx += MAX_OPAQUE_VERTS;
    }

    float3 pos0 = worldPosition(cell + v0);
    float3 pos1 = worldPosition(cell + v1);
    float3 pos2 = worldPosition(cell + v2);

    float3 n1 = normalize(cross(pos1 - pos0, pos2 - pos0));
    float3 n2 = normalize(cross(pos2 - pos0, pos1 - pos0));

    writeVert(vIdx+0, pos0, n1, uint(p0));
    writeVert(vIdx+1, pos1, n1, uint(p1));
    writeVert(vIdx+2, pos2, n1, uint(p2));
    writeVert(vIdx+3, pos0, n2, uint(p0));
    writeVert(vIdx+4, pos2, n2, uint(p2));
    writeVert(vIdx+5, pos1, n2, uint(p1));
  }
}
