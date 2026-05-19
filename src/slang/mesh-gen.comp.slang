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

[[vk::binding(4, 0)]]
RWByteAddressBuffer indicesOut;

static const int VERTS_PER_X_DIR = 16;
static const int VERTS_PER_Y_DIR = 32;
static const int VERTS_PER_Z_DIR = 16;
static const int CUBES_PER_X_DIR = 15;
static const int CUBES_PER_Y_DIR = 31;
static const int CUBES_PER_Z_DIR = 15;
static const int VERT_STRIDE_X = VERTS_PER_Z_DIR * VERTS_PER_Y_DIR;
static const int VERT_STRIDE_Y = VERTS_PER_Z_DIR;

static const uint VERTEX_STRIDE = 16;
static const uint MAX_VERTS = VERTS_PER_X_DIR * VERTS_PER_Y_DIR * VERTS_PER_Z_DIR;

//CHANGE IN ODIN WHEN CHANGING HERE AND VICE VERSA
static const uint MAX_OPAQUE_INDICES =  CUBES_PER_X_DIR * CUBES_PER_Y_DIR * CUBES_PER_Z_DIR * 36;
static const uint MAX_TRANSPARENT_INDICES =  MAX_OPAQUE_INDICES ;


uint gridIdx(int3 p) {
    return uint(p.x) * VERT_STRIDE_X + uint(p.y) * VERT_STRIDE_Y + uint(p.z);
}

uint16_t getPoint(int3 cell) {
  if (cell.x < 0 || cell.x >= VERTS_PER_X_DIR) return uint16_t(PointType::Air);
  if (cell.y < 0 || cell.y >= VERTS_PER_Y_DIR) return uint16_t(PointType::Air);
  if (cell.z < 0 || cell.z >= VERTS_PER_Z_DIR) return uint16_t(PointType::Air);
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

void writeVert(int3 p, uint pointVal) {
    uint byteOffset = gridIdx(p) * VERTEX_STRIDE;
    vertsOut.Store3(byteOffset + 0,  asuint(worldPosition(p)));
    vertsOut.Store (byteOffset + 12, pointVal);
}

void writeTriangle(uint idxByteOffset, uint v0, uint v1, uint v2) {
    indicesOut.Store(idxByteOffset + 0, v0);
    indicesOut.Store(idxByteOffset + 4, v1);
    indicesOut.Store(idxByteOffset + 8, v2);
}

static const int3 triVerts[6][3] = {
  { int3(0,0,0), int3(1,1,0), int3(1,0,0) },
  { int3(0,0,0), int3(0,1,0), int3(1,1,0) },
  { int3(0,0,0), int3(0,0,1), int3(0,1,1) },
  { int3(0,0,0), int3(0,1,1), int3(0,1,0) },
  { int3(0,0,0), int3(1,0,0), int3(1,0,1) },
  { int3(0,0,0), int3(1,0,1), int3(0,0,1) }
};

static const int3 neighborOffsets[26] = {
  int3(1,0,0),   int3(-1,0,0),  int3(0,1,0),  int3(0,-1,0),
  int3(0,0,1),   int3(0,0,-1),  int3(1,1,0),  int3(1,-1,0),
  int3(-1,1,0),  int3(-1,-1,0), int3(1,0,1),  int3(1,0,-1),
  int3(-1,0,1),  int3(-1,0,-1), int3(0,1,1),  int3(0,1,-1),
  int3(0,-1,1),  int3(0,-1,-1), int3(1,1,1),  int3(1,1,-1),
  int3(1,-1,1),  int3(1,-1,-1), int3(-1,1,1), int3(-1,1,-1),
  int3(-1,-1,1), int3(-1,-1,-1)
};

bool isSurrounded(int3 cell) {
  for (int i = 0; i < 26; i++) {
    PointType pt = getPointType(getPoint(cell + neighborOffsets[i]));
    if (isTransparentPoint(pt))
        return false;
    if (pt == PointType::Air)
        return false;
  }
  return true;
}

bool isSurroundedByWater(int3 cell) {
  for (int i = 0; i < 26; i++) {
    if (!isTransparentPoint(getPointType(getPoint(cell + neighborOffsets[i]))))
      return false;
  }
  return true;
}

[shader("compute")]
[numthreads(8, 8, 8)]
void main(uint3 id: SV_DispatchThreadID) {
  int3 cell = int3(id);

  if (cell.x >= CUBES_PER_X_DIR || cell.y >= CUBES_PER_Y_DIR || cell.z >= CUBES_PER_Z_DIR)
    return;

  PointType cellType = getPointType(getPoint(cell));

  if (cellType == PointType::Air)
    return;

  if (isTransparentPoint(cellType) && isSurroundedByWater(cell))
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
    uint transparentCount = isTransparentPoint(p0pt) +  isTransparentPoint(p1pt) + isTransparentPoint(p2pt);


    if (p0pt == PointType::Air || p1pt == PointType::Air || p2pt == PointType::Air)
        continue;
    bool isTransparent = transparentCount == 3;
    if (transparentCount > 0 && transparentCount < 3)
        continue;


    int3 c0 = cell + v0;
    int3 c1 = cell + v1;
    int3 c2 = cell + v2;

    writeVert(c0, uint(p0));
    writeVert(c1, uint(p1));
    writeVert(c2, uint(p2));

    uint iIdx;
    static uint INTERLOCKED_AMOUNT = 3;
    if (!isTransparent) {
      counter.InterlockedAdd(0, INTERLOCKED_AMOUNT, iIdx);
    } else {
      counter.InterlockedAdd(4, INTERLOCKED_AMOUNT, iIdx);
      iIdx += MAX_OPAQUE_INDICES;
    }
    writeTriangle(iIdx * 4, gridIdx(c0), gridIdx(c1), gridIdx(c2));

  }
}
