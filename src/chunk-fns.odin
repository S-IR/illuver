package main
import "../modules/tracy"
import "../modules/vma"
import "algorithms"
import "camera"
import "core:container/small_array"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/noise"
import "core:math/rand"
import "core:mem"
import "core:mem/virtual"
import vmem "core:mem/virtual"
import "core:os"
import "core:prof/spall"
import "core:simd"
import "core:sync"
import "core:thread"
import vk "vendor:vulkan"
import "vkh"


// CHUNK_SIZE :: 16


MIN_Y :: -128
MAX_Y :: MIN_Y + (CHUNK_STRIDE_Y * IRRF_CHUNKS_PER_FILE_PER_Y_DIR * 2)
#assert(MAX_Y > 0)
// CHUNK_HEIGHT :: MAX_Y - MIN_Y
DEFAULT_SURFACE_LEVEL :: -1


VERTS_PER_X_DIR: i32 : 16
VERTS_PER_Z_DIR: i32 : 16
#assert(VERTS_PER_X_DIR == VERTS_PER_Z_DIR)

VERTS_PER_Y_DIR: i32 : 32

CHUNK_STRIDE_XZ :: VERTS_PER_X_DIR - 1
CHUNK_STRIDE_Y :: VERTS_PER_Y_DIR - 1

CUBES_PER_X_DIR: i32 : VERTS_PER_X_DIR - 1
CUBES_PER_Y_DIR: i32 : VERTS_PER_Y_DIR - 1
CUBES_PER_Z_DIR: i32 : VERTS_PER_Z_DIR - 1

CHUNK_HEIGHTMAP_SIZE :: VERTS_PER_X_DIR * VERTS_PER_Z_DIR
NUM_WORKER_THREADS := 4
MAX_OPAQUE_VERTS :: CUBES_PER_X_DIR * CUBES_PER_Y_DIR * CUBES_PER_Z_DIR * 36
VERTEX_BUFFER_SIZE :: MAX_OPAQUE_VERTS * size_of(PointVertexInput)

Chunk :: struct {
	points:                                    [VERTS_PER_X_DIR *
	VERTS_PER_Y_DIR *
	VERTS_PER_Z_DIR]u16,
	heightMap:                                 [CHUNK_HEIGHTMAP_SIZE]i32,
	buffers:                                   struct {
		vertices: [vkh.MAX_FRAMES_IN_FLIGHT]vkh.BufferAlloc,
		compute:  struct {
			pointsInput:     vkh.BufferAlloc,
			counter:         vkh.BufferAlloc,
			uniform:         vkh.BufferAlloc,
			stagingVertices: vkh.BufferAlloc,
		},
	},
	copyTimelineValue:                         [vkh.MAX_FRAMES_IN_FLIGHT]u64,
	pos:                                       [3]i32,
	pendingUpload:                             [vkh.MAX_FRAMES_IN_FLIGHT]b32,
	mutex:                                     sync.RW_Mutex,
	totalOpaquePoints: u32,
	arena:                                     virtual.Arena,
	alloc:                                     mem.Allocator,
	dirty:                                     bool,
}


// chunk_point_get :: proc(c: ^Chunk, x, y, z: i32) -> PointType {
// 	return c.points[x * CUBES_PER_Y_DIR * CUBES_PER_Z_DIR + y * CUBES_PER_Z_DIR + z]
// }

//MUST NOT BE PAIR
CHUNKS_PER_XZ_DIRECTION: i32 = 5
// #assert(CHUNKS_PER_XZ_DIRECTION % 2 != 0)

//MUST NOT BE PAIR
CHUNKS_PER_Y_DIRECTION: i32 = 3
// #assert(CHUNKS_PER_Y_DIRECTION % 2 != 0)
// #assert(CHUNKS_PER_DIRECTION < int(max(i32)))
ENERGY_TICKING_DIRECTION_LEN := CHUNKS_PER_XZ_DIRECTION

VERT_STRIDE_X :: VERTS_PER_Y_DIR * VERTS_PER_Z_DIR
VERT_STRIDE_Y :: VERTS_PER_Z_DIR
index_into_point_arrays_scalars :: #force_inline proc(x, y, z: i32) -> i32 {
	assert(x >= 0 && x < VERTS_PER_X_DIR)
	assert(y >= 0 && y < VERTS_PER_Y_DIR)
	assert(z >= 0 && z < VERTS_PER_Z_DIR)

	return x * VERT_STRIDE_X + y * VERT_STRIDE_Y + z
}
index_into_point_arrays_vector :: #force_inline proc(v: [3]i32) -> i32 {
	assert(v.x >= 0 && v.x < VERTS_PER_X_DIR)
	assert(v.y >= 0 && v.y < VERTS_PER_Y_DIR)
	assert(v.z >= 0 && v.z < VERTS_PER_Z_DIR)

	return v.x * VERT_STRIDE_X + v.y * VERT_STRIDE_Y + v.z
}
index_into_point_arrays_vector_contextless :: #force_inline proc "contextless" (v: [3]i32) -> i32 {
	return v.x * VERT_STRIDE_X + v.y * VERT_STRIDE_Y + v.z
}
index_into_point_arrays :: proc {
	index_into_point_arrays_scalars,
	index_into_point_arrays_vector,
}

index_into_height_map_scalars :: #force_inline proc "contextless" (x, z: i32) -> i32 {
	return x * VERTS_PER_Z_DIR + z
}
index_into_height_map_vector :: #force_inline proc "contextless" (v: [2]i32) -> i32 {
	return v.x * VERTS_PER_Z_DIR + v.y
}
index_into_height_map :: proc {
	index_into_height_map_scalars,
	index_into_height_map_vector,
}
MAX_POINTS :: VERTS_PER_X_DIR * VERTS_PER_Y_DIR * VERTS_PER_Z_DIR
MAX_POINTS_INT :: int(MAX_POINTS)

MAX_INDICES :: CUBES_PER_X_DIR * CUBES_PER_Y_DIR * CUBES_PER_Z_DIR * 36
MAX_COLORS :: MAX_INDICES
INDEX_TYPE_USED_IN_CHUNKS :: u32
chunk_set_point :: proc(worldPos: [3]f32, newType: PointType) -> (changed: bool, prev: u16) {

	worldPosI32 := linalg.to_i32(linalg.round(worldPos))
	for chunk in renderedChunks {
		min := chunk.pos
		max := min + [3]i32{CHUNK_STRIDE_XZ, CHUNK_STRIDE_Y, CHUNK_STRIDE_XZ}

		if worldPosI32.x < min.x || worldPosI32.x > max.x do continue
		if worldPosI32.y < min.y || worldPosI32.y > max.y do continue
		if worldPosI32.z < min.z || worldPosI32.z > max.z do continue

		index := worldPosI32 - min

		if u16_to_point_type(chunk.points[index_into_point_arrays(index)]) == newType do continue
		changed = true
		prev = chunk.points[index_into_point_arrays(index)]
		chunk_point_edit_add_thread(chunk, index.x, index.y, index.z, u16(newType))
	}

	return changed, prev
}
chunks_frame_update :: proc(c: ^camera.Camera) {

	for &chunk in renderedChunks {
		if !chunk.dirty do continue
		chunk_update_add_thread(chunk)
		chunk.dirty = false
	}

	sync.wait(&chunkWorkersWG)
	chunks_shift_per_player_movement(c)
}
chunks_shift_per_player_movement :: proc(c: ^camera.Camera) {
	tracy.Zone()
	half := [3]i32 {
		CHUNKS_PER_XZ_DIRECTION / 2,
		CHUNKS_PER_Y_DIRECTION / 2,
		CHUNKS_PER_XZ_DIRECTION / 2,
	}
	stride := [3]i32{CHUNK_STRIDE_XZ, CHUNK_STRIDE_Y, CHUNK_STRIDE_XZ}

	xyzCurr := linalg.to_i32(
		linalg.floor(
			c.pos / [3]f32{f32(CHUNK_STRIDE_XZ), f32(CHUNK_STRIDE_Y), f32(CHUNK_STRIDE_XZ)},
		),
	)
	xyzPrev := rc(half).pos / stride

	if xyzCurr == xyzPrev do return

	delta := xyzCurr - xyzPrev

	shift_chunks :: proc(dir: enum {
			X,
			Y,
			Z,
		}, delta: i32, xyzCurr, half: [3]i32) {
		if delta == 0 do return
		count := abs((delta))
		isPositiveShift := delta > 0

		if dir == .X {
			recycled := make(
				[dynamic]^Chunk,
				count * CHUNKS_PER_Y_DIRECTION * CHUNKS_PER_XZ_DIRECTION,
				context.temp_allocator,
			)
			idx :: #force_inline proc(p, y, z: i32) -> i32 {return(
					p * CHUNKS_PER_Y_DIRECTION * CHUNKS_PER_XZ_DIRECTION +
					y * CHUNKS_PER_XZ_DIRECTION +
					z \
				)}

			if isPositiveShift {
				for p in 0 ..< count {
					for y in 0 ..< CHUNKS_PER_Y_DIRECTION {
						for z in 0 ..< CHUNKS_PER_XZ_DIRECTION {
							recycled[idx(p, y, z)] = rc(p, y, z)
						}
					}
				}
				for x in 0 ..< CHUNKS_PER_XZ_DIRECTION - count {
					for y in 0 ..< CHUNKS_PER_Y_DIRECTION {
						for z in 0 ..< CHUNKS_PER_XZ_DIRECTION {
							rc_set(x, y, z, rc(x + count, y, z))
						}
					}
				}
				for p in 0 ..< count {
					nx := CHUNKS_PER_XZ_DIRECTION - 1 - p
					for y in 0 ..< CHUNKS_PER_Y_DIRECTION {
						for z in 0 ..< CHUNKS_PER_XZ_DIRECTION {
							rc_set(nx, y, z, recycled[idx(p, y, z)])
							posChunkCoord := xyzCurr + [3]i32{i32(nx), i32(y), i32(z)} - half
							pos :=
								posChunkCoord * {CHUNK_STRIDE_XZ, CHUNK_STRIDE_Y, CHUNK_STRIDE_XZ}
							chunk_init_add_thread(rc(nx, y, z), pos)
						}
					}
				}
			} else {
				for p in 0 ..< count {
					sx := CHUNKS_PER_XZ_DIRECTION - 1 - p
					for y in 0 ..< CHUNKS_PER_Y_DIRECTION {
						for z in 0 ..< CHUNKS_PER_XZ_DIRECTION {
							recycled[idx(p, y, z)] = rc(sx, y, z)
						}
					}
				}
				for x := CHUNKS_PER_XZ_DIRECTION - 1; x >= count; x -= 1 {
					for y in 0 ..< CHUNKS_PER_Y_DIRECTION {
						for z in 0 ..< CHUNKS_PER_XZ_DIRECTION {
							rc_set(x, y, z, rc(x - count, y, z))
						}
					}
				}
				for p in 0 ..< count {
					nx := p
					for y in 0 ..< CHUNKS_PER_Y_DIRECTION {
						for z in 0 ..< CHUNKS_PER_XZ_DIRECTION {
							rc_set(nx, y, z, recycled[idx(p, y, z)])
							posChunkCoord := xyzCurr + [3]i32{i32(nx), i32(y), i32(z)} - half
							pos :=
								posChunkCoord * {CHUNK_STRIDE_XZ, CHUNK_STRIDE_Y, CHUNK_STRIDE_XZ}
							chunk_init_add_thread(rc(nx, y, z), pos)
						}
					}
				}
			}
			return
		}

		if dir == .Y {
			recycled := make(
				[dynamic]^Chunk,
				count * CHUNKS_PER_XZ_DIRECTION * CHUNKS_PER_XZ_DIRECTION,
				context.temp_allocator,
			)
			idx :: #force_inline proc(p, x, z: i32) -> i32 {return(
					p * CHUNKS_PER_XZ_DIRECTION * CHUNKS_PER_XZ_DIRECTION +
					x * CHUNKS_PER_XZ_DIRECTION +
					z \
				)}

			if isPositiveShift {
				for p in 0 ..< count {
					for x in 0 ..< CHUNKS_PER_XZ_DIRECTION {
						for z in 0 ..< CHUNKS_PER_XZ_DIRECTION {
							recycled[idx(p, x, z)] = rc(x, p, z)
						}
					}
				}
				for y in 0 ..< CHUNKS_PER_Y_DIRECTION - count {
					for x in 0 ..< CHUNKS_PER_XZ_DIRECTION {
						for z in 0 ..< CHUNKS_PER_XZ_DIRECTION {
							rc_set(x, y, z, rc(x, y + count, z))
						}
					}
				}
				for p in 0 ..< count {
					ny := CHUNKS_PER_Y_DIRECTION - 1 - p
					for x in 0 ..< CHUNKS_PER_XZ_DIRECTION {
						for z in 0 ..< CHUNKS_PER_XZ_DIRECTION {
							rc_set(x, ny, z, recycled[idx(p, x, z)])
							posChunkCoord := xyzCurr + [3]i32{i32(x), i32(ny), i32(z)} - half
							pos :=
								posChunkCoord * {CHUNK_STRIDE_XZ, CHUNK_STRIDE_Y, CHUNK_STRIDE_XZ}
							chunk_init_add_thread(rc(x, ny, z), pos)
						}
					}
				}
			} else {
				for p in 0 ..< count {
					sy := CHUNKS_PER_Y_DIRECTION - 1 - p
					for x in 0 ..< CHUNKS_PER_XZ_DIRECTION {
						for z in 0 ..< CHUNKS_PER_XZ_DIRECTION {
							recycled[idx(p, x, z)] = rc(x, sy, z)
						}
					}
				}
				for y := CHUNKS_PER_Y_DIRECTION - 1; y >= count; y -= 1 {
					for x in 0 ..< CHUNKS_PER_XZ_DIRECTION {
						for z in 0 ..< CHUNKS_PER_XZ_DIRECTION {
							rc_set(x, y, z, rc(x, y - count, z))
						}
					}
				}
				for p in 0 ..< count {
					ny := p
					for x in 0 ..< CHUNKS_PER_XZ_DIRECTION {
						for z in 0 ..< CHUNKS_PER_XZ_DIRECTION {
							rc_set(x, ny, z, recycled[idx(p, x, z)])
							posChunkCoord := xyzCurr + [3]i32{i32(x), i32(ny), i32(z)} - half
							pos :=
								posChunkCoord * {CHUNK_STRIDE_XZ, CHUNK_STRIDE_Y, CHUNK_STRIDE_XZ}
							chunk_init_add_thread(rc(x, ny, z), pos)
						}
					}
				}
			}
			return
		}

		if dir == .Z {
			recycled := make(
				[dynamic]^Chunk,
				count * CHUNKS_PER_XZ_DIRECTION * CHUNKS_PER_Y_DIRECTION,
				context.temp_allocator,
			)
			idx :: #force_inline proc(p, x, y: i32) -> i32 {return(
					p * CHUNKS_PER_XZ_DIRECTION * CHUNKS_PER_Y_DIRECTION +
					x * CHUNKS_PER_Y_DIRECTION +
					y \
				)}

			if isPositiveShift {
				for p in 0 ..< count {
					for x in 0 ..< CHUNKS_PER_XZ_DIRECTION {
						for y in 0 ..< CHUNKS_PER_Y_DIRECTION {
							recycled[idx(p, x, y)] = rc(x, y, p)
						}
					}
				}
				for z in 0 ..< CHUNKS_PER_XZ_DIRECTION - count {
					for x in 0 ..< CHUNKS_PER_XZ_DIRECTION {
						for y in 0 ..< CHUNKS_PER_Y_DIRECTION {
							rc_set(x, y, z, rc(x, y, z + count))
						}
					}
				}
				for p in 0 ..< count {
					nz := CHUNKS_PER_XZ_DIRECTION - 1 - p
					for x in 0 ..< CHUNKS_PER_XZ_DIRECTION {
						for y in 0 ..< CHUNKS_PER_Y_DIRECTION {
							rc_set(x, y, nz, recycled[idx(p, x, y)])
							posChunkCoord := xyzCurr + [3]i32{i32(x), i32(y), i32(nz)} - half
							pos :=
								posChunkCoord * {CHUNK_STRIDE_XZ, CHUNK_STRIDE_Y, CHUNK_STRIDE_XZ}
							chunk_init_add_thread(rc(x, y, nz), pos)
						}
					}
				}
			} else {
				for p in 0 ..< count {
					sz := CHUNKS_PER_XZ_DIRECTION - 1 - p
					for x in 0 ..< CHUNKS_PER_XZ_DIRECTION {
						for y in 0 ..< CHUNKS_PER_Y_DIRECTION {
							recycled[idx(p, x, y)] = rc(x, y, sz)
						}
					}
				}
				for z := CHUNKS_PER_XZ_DIRECTION - 1; z >= count; z -= 1 {
					for x in 0 ..< CHUNKS_PER_XZ_DIRECTION {
						for y in 0 ..< CHUNKS_PER_Y_DIRECTION {
							rc_set(x, y, z, rc(x, y, z - count))
						}
					}
				}
				for p in 0 ..< count {
					nz := p
					for x in 0 ..< CHUNKS_PER_XZ_DIRECTION {
						for y in 0 ..< CHUNKS_PER_Y_DIRECTION {
							rc_set(x, y, nz, recycled[idx(p, x, y)])
							posChunkCoord := xyzCurr + [3]i32{i32(x), i32(y), i32(nz)} - half
							pos :=
								posChunkCoord * {CHUNK_STRIDE_XZ, CHUNK_STRIDE_Y, CHUNK_STRIDE_XZ}
							chunk_init_add_thread(rc(x, y, nz), pos)
						}
					}
				}
			}
			return
		}
	}
	if delta.x != 0 {shift_chunks(.X, delta.x, xyzCurr, half)}
	if delta.y != 0 {shift_chunks(.Y, delta.y, xyzCurr, half)}
	if delta.z != 0 {shift_chunks(.Z, delta.z, xyzCurr, half)}

	assert(chunk_contains_point(rc(half).pos, camera.curr.pos))
}


is_chunk_in_camera_frustrum :: proc(pos: [3]i32, c: camera.Camera) -> bool {
	min := linalg.to_f32(pos)
	max :=
		min + linalg.to_f32([3]i32{CHUNK_STRIDE_XZ + 1, CHUNK_STRIDE_Y + 1, CHUNK_STRIDE_XZ + 1})

	view, proj := camera.Camera_view_proj(c)
	vp := proj * view

	vp = linalg.transpose(vp)
	planes := [6][4]f32 {
		vp[3] + vp[0], // left
		vp[3] - vp[0], // right
		vp[3] + vp[1], // bottom
		vp[3] - vp[1], // top
		vp[3] + vp[2], // near
		vp[3] - vp[2], // far
	}
	for i in 0 ..< 6 {
		n := planes[i].xyz
		len := linalg.length(n)
		planes[i] /= len
	}
	for plane in planes {
		if !camera.aabb_vs_plane(min, max, plane) {
			return false
		}
	}

	return true
}

get_point_at_world_pos :: proc(worldGridPos: [3]f32, currCamera: camera.Camera) -> u16 {
	when ODIN_DEBUG {
		worldPosRounded := linalg.round(worldGridPos)
		assert(worldPosRounded == worldGridPos)
	}

	worldCoordXYZ := linalg.to_i32(linalg.round(worldGridPos))

	//oob check
	if worldCoordXYZ.y < MIN_Y || worldCoordXYZ.y > MAX_Y {
		when ODIN_DEBUG {
			fmt.printfln("OOB call to get_point_at_world_pos", worldGridPos)
		}
		return 0
	}

	strideVector := [3]i32{CHUNK_STRIDE_XZ, CHUNK_STRIDE_Y, CHUNK_STRIDE_XZ}
	chunkCoord :=
		linalg.to_i32(
			linalg.floor(
				linalg.to_f32(worldCoordXYZ) /
				[3]f32{f32(CHUNK_STRIDE_XZ), f32(CHUNK_STRIDE_Y), f32(CHUNK_STRIDE_XZ)},
			),
		) *
		strideVector
	middleVisibleChunkIndex := [3]i32 {
		CHUNKS_PER_XZ_DIRECTION / 2,
		CHUNKS_PER_Y_DIRECTION / 2,
		CHUNKS_PER_XZ_DIRECTION / 2,
	}
	centerChunk := rc(middleVisibleChunkIndex)
	centerChunkCoord := centerChunk.pos


	assert(chunk_contains_point(centerChunk.pos, currCamera.pos))
	arrayIndex := middleVisibleChunkIndex + ((chunkCoord - centerChunkCoord) / strideVector)

	// assert(!(arrayIndex.x < 0 || arrayIndex.x >= CHUNKS_PER_DIRECTION))
	// assert(!(arrayIndex.y < 0 || arrayIndex.y >= CHUNKS_PER_DIRECTION))
	// if arrayIndex.x < 0 || arrayIndex.x >= i32(CHUNKS_PER_XZ_DIRECTION) do return 0
	// if arrayIndex.y < 0 || arrayIndex.y >= i32(CHUNKS_PER_XZ_DIRECTION) do return 0

	chunk := rc(arrayIndex)

	localXYZ := worldCoordXYZ - chunk.pos
	assert_point_array_index_valid(localXYZ)

	return chunk.points[index_into_point_arrays(localXYZ)]
}
chunk_contains_point :: proc(chunkXZ: [3]i32, pos: [3]f32) -> bool {
	posXZ := linalg.to_i32(linalg.round(pos))
	diff := posXZ - chunkXZ

	xGood := diff.x >= 0 && diff.x <= CHUNK_STRIDE_XZ
	yGood := diff.y >= 0 && diff.y <= CHUNK_STRIDE_Y
	zGood := diff.z >= 0 && diff.z <= CHUNK_STRIDE_XZ

	return xGood && yGood && zGood
}
assert_height_map_index_valid_scalars :: #force_inline proc(x, z: i32) {
	when ODIN_DEBUG {
		assert(x >= 0 && x < VERTS_PER_X_DIR)
		assert(z >= 0 && z < VERTS_PER_Z_DIR)
	}
}
assert_height_map_index_valid_vector :: #force_inline proc(v: [2]i32) {
	when ODIN_DEBUG {
		assert(v.x >= 0 && v.x < VERTS_PER_X_DIR)
		assert(v.y >= 0 && v.y < VERTS_PER_Z_DIR)
	}
}
assert_height_map_index_valid :: proc {
	assert_height_map_index_valid_scalars,
	assert_height_map_index_valid_vector,
}

assert_point_array_index_valid_scalars :: #force_inline proc(x, y, z: i32) {
	when ODIN_DEBUG {
		assert(x >= 0 && x < VERTS_PER_X_DIR)
		assert(y >= 0 && y < VERTS_PER_Y_DIR)
		assert(z >= 0 && z < VERTS_PER_Z_DIR)
	}
}
assert_point_array_index_valid_vector :: #force_inline proc(v: [3]i32) {
	when ODIN_DEBUG {
		assert(v.x >= 0 && v.x < VERTS_PER_X_DIR)
		assert(v.y >= 0 && v.y < VERTS_PER_Y_DIR)
		assert(v.z >= 0 && v.z < VERTS_PER_Z_DIR)
	}
}
assert_point_array_index_valid :: proc {
	assert_point_array_index_valid_scalars,
	assert_point_array_index_valid_vector,
}
point_place_update_height :: #force_inline proc(
	points: ^[MAX_POINTS]u16,
	heightMap: ^[CHUNK_HEIGHTMAP_SIZE]i32,
	index: [3]i32,
	val: u16,
) {
	assert_point_array_index_valid(index)
	points[index_into_point_arrays(index)] = val
	heightMap[index_into_height_map(index.xz)] = math.max(
		heightMap[index_into_height_map(index.xz)],
		index.y,
	)

}
chunk_point_oob :: proc(index: [3]i32) -> bool {
	if index.x < 0 || index.x >= VERTS_PER_X_DIR do return true

	if index.z < 0 || index.z >= VERTS_PER_Z_DIR do return true
	if index.y < 0 || index.y >= VERTS_PER_Y_DIR do return true

	return false
}
MAX_WALKABLE_SLOPE :: f32(0.6)

// TerrainSample :: struct {
// 	height:   f32, // world Y at camera XZ
// 	normal:   [3]f32, // surface normal of triangle below
// 	slopeCos: f32, // dot(normal, UP) — 1.0 = flat, 0.0 = vertical
// 	walkable: bool, // slope_cos above threshold
// }
// sample_terrain_below :: proc(c: ^camera.Camera) {


// 	camWorldCoord := [2]i32{i32(math.floor(c.pos.x)), i32(math.floor(c.pos.z))}

// 	chunk := &RenderedChunks[CHUNKS_PER_DIRECTION / 2][CHUNKS_PER_DIRECTION / 2]
// 	when ODIN_DEBUG {
// 		goodX := localCoord[0] >= 0 && localCoord[0] < CHUNK_STRIDE
// 		goodZ := localCoord[1] >= 0 && localCoord[1] < CHUNK_STRIDE
// 		assert(goodZ)
// 		assert(goodX)
// 	}
// 	worldGridPosF32 := linalg.round(c.pos)
// 	worldGridPos := linalg.to_i32(worldGridPosF32)

// 	localCoordsInChunk := worldGridPos - [3]i32{chunk.pos[0], MIN_Y, chunk.pos[1]}


// 	floorYIndex: i32 = MIN_Y
// 	for iter: i32 = i32(math.floor(c.pos.y)); iter >= i32(MIN_Y); iter -= 1 {
// 		y := iter - MIN_Y
// 		assert(y >= 0 && y < i32(VERTS_PER_Y_DIR))

// 		if chunk.points[index_into_point_arrays(localCoordsInChunk.x, y, localCoordsInChunk.z)] !=
// 		   0 {
// 			floorYIndex = y
// 			break
// 		}

// 	}
// 	belowPointWorldPos := local_index_to_world_pos(
// 		chunk.pos,
// 		[3]i32{localCoordsInChunk.x, floorYIndex, localCoordsInChunk.z},
// 	)


// 	when ODIN_DEBUG {
// 		assert(c.pos.y - belowPointWorldPos.y > camera.PLAYER_SIZE)
// 	}

// 	areWeOnPlusX := c.pos.x - belowPointWorldPos.x > 0
// 	areWeOnPlusZ := c.pos.z - belowPointWorldPos.z > 0


// 	chunkOffsetForX := 0
// 	if areWeOnPlusX && localCoordsInChunk.x + 1 >= VERTS_PER_X_DIR do chunkOffsetForX = 1
// 	if !areWeOnPlusX && localCoordsInChunk.x - 1 < 0 do chunkOffsetForX = -1

// 	chunkOffsetForZ := 0
// 	if areWeOnPlusZ && localCoordsInChunk.z + 1 >= VERTS_PER_Z_DIR do chunkOffsetForZ = 1
// 	if !areWeOnPlusZ && localCoordsInChunk.z - 1 < 0 do chunkOffsetForZ = -1

// 	corner2Chunk := &RenderedChunks[(CHUNKS_PER_DIRECTION / 2) + chunkOffsetForX][CHUNKS_PER_DIRECTION / 2]
// 	corner3Chunk := &RenderedChunks[(CHUNKS_PER_DIRECTION / 2)][(CHUNKS_PER_DIRECTION / 2) + chunkOffsetForZ]
// 	corner4Chunk := &RenderedChunks[(CHUNKS_PER_DIRECTION / 2) + chunkOffsetForX][(CHUNKS_PER_DIRECTION / 2) + chunkOffsetForZ]

// 	corner1 := belowPointWorldPos
// 	corner2, corner3, corner4: [3]f32

// 	get_closest_point_in_grid :: proc(chunk: ^Chunk, gridCoord: [3]i32) -> (res: [3]i32) {
// 		assert(gridCoord.x >= 0 && gridCoord.x < VERTS_PER_X_DIR)
// 		assert(gridCoord.y >= 0 && gridCoord.y < VERTS_PER_Y_DIR)
// 		assert(gridCoord.z >= 0 && gridCoord.z < VERTS_PER_Z_DIR)

// 		closestBorderY: i32 = MIN_Y
// 		if MAX_Y - 1 - gridCoord.y < MIN_Y - gridCoord.y {
// 			closestBorderY = MAX_Y - 1
// 		}
// 		for i: i32 = 0; (gridCoord.y + i < MAX_Y) || (gridCoord.y - i > MIN_Y); i += 1 {
// 			reachedTop := gridCoord.y + i >= MAX_Y
// 			reachedBottom := gridCoord.y - i <= MIN_Y
// 			topPoint, bottomPoint: u16

// 			topCoords := [3]i32{gridCoord.x, gridCoord.y + i, gridCoord.z}
// 			bottomCoords := [3]i32{gridCoord.x, gridCoord.y - i, gridCoord.z}
// 			if !reachedTop do topPoint = chunk.points[index_into_point_arrays(topCoords)]
// 			if !reachedBottom do bottomPoint = chunk.points[index_into_point_arrays(bottomCoords)]

// 			foundTop := !reachedTop && topPoint != 0
// 			foundBottom := !reachedBottom && bottomPoint != 0

// 			if foundTop {
// 				res = topCoords
// 				if reachedBottom do return res
// 			}

// 			if foundBottom {
// 				res = bottomCoords
// 				if reachedTop do return res
// 			}
// 			if foundTop && foundBottom {
// 				topRealPos := local_index_to_world_pos(chunk.pos, topCoords)
// 				bottomRealPos := local_index_to_world_pos(chunk.pos, bottomCoords)
// 				startPointRealPos := local_index_to_world_pos(chunk.pos, gridCoord)

// 				diffTop := topRealPos.y - startPointRealPos.y
// 				diffBottom := startPointRealPos.y - bottomRealPos.y

// 				topIsSmaller := diffTop < diffBottom
// 				if topIsSmaller {
// 					return topCoords
// 				} else {
// 					return bottomCoords
// 				}

// 			}

// 		}
// 		return {gridCoord.x, closestBorderY, gridCoord.z}

// 	}

// 	{
// 		offsetForX: i32 = 1 if areWeOnPlusX else -1
// 		offsetForZ: i32 = 1 if areWeOnPlusZ else -1

// 		corner2LocalCoord := localCoordsInChunk + {offsetForX, 0, 0}
// 		corner2LocalCoord.x /= VERTS_PER_X_DIR
// 		corner2 = local_index_to_world_pos(
// 			corner2Chunk.pos,
// 			get_closest_point_in_grid(corner2Chunk, corner2LocalCoord),
// 		)


// 		corner3LocalCoord := localCoordsInChunk + {0, 0, offsetForZ}
// 		corner3LocalCoord.z /= VERTS_PER_Z_DIR
// 		corner3 = local_index_to_world_pos(
// 			corner3Chunk.pos,
// 			get_closest_point_in_grid(corner3Chunk, corner3LocalCoord),
// 		)


// 		corner4LocalCoord := localCoordsInChunk + {offsetForX, 0, offsetForZ}
// 		corner4LocalCoord.z /= VERTS_PER_Z_DIR
// 		corner4LocalCoord.x /= VERTS_PER_X_DIR
// 		corner4 = local_index_to_world_pos(
// 			corner4Chunk.pos,
// 			get_closest_point_in_grid(corner4Chunk, corner4LocalCoord),
// 		)


// 	}
// 	point_in_triangle_xz :: proc(p, a, b, c: [3]f32) -> bool {
// 		cross :: proc(a, b: [2]f32) -> f32 {return a.x * b.y - a.y * b.x}

// 		d1 := cross(p.xz - a.xz, b.xz - a.xz)
// 		d2 := cross(p.xz - b.xz, c.xz - b.xz)
// 		d3 := cross(p.xz - c.xz, a.xz - c.xz)

// 		hasNeg := (d1 < 0) || (d2 < 0) || (d3 < 0)
// 		hasPos := (d1 > 0) || (d2 > 0) || (d3 > 0)
// 		return !(hasNeg || hasPos)
// 	}

// 	a, b, cc_: [3]f32
// 	if point_in_triangle_xz(c.pos, corner1, corner2, corner3) {
// 		a, b, cc_ = corner1, corner2, corner3
// 	} else {
// 		a, b, cc_ = corner4, corner2, corner3
// 	}

// 	edge1 := b - a
// 	edge2 := cc_ - a
// 	normal := linalg.normalize(linalg.cross(edge1, edge2))
// 	if normal.y < 0 do normal = -normal
// 	height :=
// 		corner1.y -
// 		(normal.x * (c.pos.x - corner1.x) + normal.z * (c.pos.z - corner1.z)) / normal.y

// }
