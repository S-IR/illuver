package main
import "../modules/tracy"
import "../modules/vma"
import "algorithms"
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

int3 :: [3]i32
int2 :: [2]i32


CHUNK_SIZE :: 16
CHUNK_STRIDE :: CHUNK_SIZE - 1

MIN_Y :: -128
MAX_Y :: 127
CHUNK_HEIGHT :: MAX_Y - MIN_Y
DEFAULT_SURFACE_LEVEL :: -1

WIDTH_OF_CELL :: f32(1)


VERTS_PER_X_DIR: i32 : auto_cast (CHUNK_SIZE / WIDTH_OF_CELL)
VERTS_PER_Y_DIR: i32 : auto_cast ((MAX_Y - MIN_Y + 1) / WIDTH_OF_CELL)
VERTS_PER_Z_DIR: i32 : auto_cast (CHUNK_SIZE / WIDTH_OF_CELL)

CUBES_PER_X_DIR: i32 : VERTS_PER_X_DIR - 1
CUBES_PER_Y_DIR: i32 : VERTS_PER_Y_DIR - 1
CUBES_PER_Z_DIR: i32 : VERTS_PER_Z_DIR - 1

NUM_WORKER_THREADS := 4
Chunk :: struct {
	pos:          int2,
	points:       [VERTS_PER_X_DIR * VERTS_PER_Y_DIR * VERTS_PER_Z_DIR]PointType,
	buffers:      struct {
		pointsBuffer: [MAX_FRAMES_IN_FLIGHT]VkBufferPoolElem,
		indices:      [MAX_FRAMES_IN_FLIGHT]VkBufferPoolElem,
		colors:       [MAX_FRAMES_IN_FLIGHT]VkBufferPoolElem,
	},
	totalPoints:  u32,
	totalIndices: u32,
	arena:        virtual.Arena,
	alloc:        mem.Allocator,
}


// chunk_point_get :: proc(c: ^Chunk, x, y, z: i32) -> PointType {
// 	return c.points[x * CUBES_PER_Y_DIR * CUBES_PER_Z_DIR + y * CUBES_PER_Z_DIR + z]
// }

CHUNKS_PER_DIRECTION :: 10

Chunks := [CHUNKS_PER_DIRECTION][CHUNKS_PER_DIRECTION]Chunk{}
CHUNK_MIDDLE_X_INDEX :: (CHUNKS_PER_DIRECTION / 2)
CHUNK_MIDDLE_Z_INDEX :: (CHUNKS_PER_DIRECTION / 2)

ChunkAtTheCenter := int2{}

WorldArena := vmem.Arena{}
WorldAllocator := mem.Allocator{}

chunks_init :: proc(c: ^Camera) {
	centerChunk := int2{i32(c.pos.x), i32(c.pos.z)} / CHUNK_SIZE
	half :: CHUNKS_PER_DIRECTION / 2


	err := vmem.arena_init_growing(&WorldArena)
	ensure(err == nil)
	WorldAllocator = vmem.arena_allocator(&WorldArena)

	chunkJobQueue = make([dynamic]ChunkJob, WorldAllocator)
	chunkWorkerStates = make([dynamic]ChunkWorkerState, NUM_CORES - 1, WorldAllocator)
	chunkWorkerThreads = make([dynamic]^thread.Thread, NUM_CORES - 1, WorldAllocator)

	for &t, i in chunkWorkerThreads {
		idx := new(int, WorldAllocator)
		idx^ = i
		t = thread.create(chunk_worker_thread)
		t.data = idx
		thread.start(t)
	}


	for x in 0 ..< CHUNKS_PER_DIRECTION {
		for z in 0 ..< CHUNKS_PER_DIRECTION {
			relX := i32(x - half)
			relZ := i32(z - half)
			worldChunkCoordX := centerChunk[0] + relX
			worldChunkCoordZ := centerChunk[1] + relZ
			pos := int2{worldChunkCoordX * CHUNK_STRIDE, worldChunkCoordZ * CHUNK_STRIDE}
			chunk_init_add_thread(x, z, pos)

		}
	}
	sync.wait(&chunkWorkersWG)

	ChunkAtTheCenter = Chunks[CHUNK_MIDDLE_X_INDEX][CHUNK_MIDDLE_Z_INDEX].pos
}


VERT_STRIDE_X :: VERTS_PER_Y_DIR * VERTS_PER_Z_DIR
VERT_STRIDE_Y :: VERTS_PER_Z_DIR
index_into_point_arrays_scalars :: #force_inline proc "contextless" (x, y, z: i32) -> i32 {

	return x * VERT_STRIDE_X + y * VERT_STRIDE_Y + z
}
index_into_point_arrays_vector :: #force_inline proc "contextless" (v: [3]i32) -> i32 {
	VERT_STRIDE_X :: VERTS_PER_Y_DIR * VERTS_PER_Z_DIR
	VERT_STRIDE_Y :: VERTS_PER_Z_DIR
	return v.x * VERT_STRIDE_X + v.y * VERT_STRIDE_Y + v.z
}
index_into_point_arrays :: proc {
	index_into_point_arrays_scalars,
	index_into_point_arrays_vector,
}
MAX_POINTS :: VERTS_PER_X_DIR * VERTS_PER_Y_DIR * VERTS_PER_Z_DIR
MAX_INDICES :: CUBES_PER_X_DIR * CUBES_PER_Y_DIR * CUBES_PER_Z_DIR * 36
MAX_COLORS :: MAX_INDICES
INDEX_TYPE_USED_IN_CHUNKS :: u32

when VISUAL_REPRESENTATION_OF_NOISE_FN_RUN {
	chunk_init :: VISUAL_REPRESENTATION_OF_NOISE_FN_RUN_chunk_init

	VISUAL_REPRESENTATION_OF_NOISE_FN_RUN_chunk_init :: proc(
		xIdx, zIdx: int,
		pos: int2,
		state: ChunkWorkerState,
	) {
		chunk := &Chunks[xIdx][zIdx]
		for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
			if chunk.buffers.pointsBuffer[i].alloc != {} do continue
			assert(chunk.buffers.indices[i].buffer == {})
			assert(chunk.buffers.colors[i].buffer == {})

			vk_chk(
				vma.create_buffer(
					vkAllocator,
					{
						sType = .BUFFER_CREATE_INFO,
						size = vk.DeviceSize(MAX_POINTS * size_of([3]f32)),
						usage = {.VERTEX_BUFFER},
					},
					{flags = {.Host_Access_Sequential_Write, .Mapped}, usage = .Auto},
					&chunk.buffers.pointsBuffer[i].buffer,
					&chunk.buffers.pointsBuffer[i].alloc,
					nil,
				),
			)
			vk_chk(
				vma.create_buffer(
					vkAllocator,
					{
						sType = .BUFFER_CREATE_INFO,
						size = vk.DeviceSize(MAX_INDICES * size_of(INDEX_TYPE_USED_IN_CHUNKS)),
						usage = {.INDEX_BUFFER},
					},
					{flags = {.Host_Access_Sequential_Write, .Mapped}, usage = .Auto},
					&chunk.buffers.indices[i].buffer,
					&chunk.buffers.indices[i].alloc,
					nil,
				),
			)

			vk_chk(
				vma.create_buffer(
					vkAllocator,
					{
						sType = .BUFFER_CREATE_INFO,
						size = vk.DeviceSize(MAX_COLORS * size_of([4]f32)),
						usage = {.STORAGE_BUFFER},
					},
					{flags = {.Host_Access_Sequential_Write, .Mapped}, usage = .Auto},
					&chunk.buffers.colors[i].buffer,
					&chunk.buffers.colors[i].alloc,
					nil,
				),
			)
		}


		if chunk.alloc == {} {
			chunk.alloc = virtual.arena_allocator(&chunk.arena)
		} else {
			free_all(chunk.alloc)
		}

		staticVisiblePoints := make(
			[dynamic]float3,
			len = MAX_POINTS,
			allocator = context.temp_allocator,
		)
		staticVisiblePointsLen: int = 0


		staticIndices := make(
			[dynamic]INDEX_TYPE_USED_IN_CHUNKS,
			len = MAX_INDICES,
			allocator = context.temp_allocator,
		)
		staticIndicesLen: int = 0

		staticColors := make([dynamic]float4, len = MAX_COLORS, allocator = context.temp_allocator)
		staticColorsLen: int = 0

		EXISTING_VERTICES_MAPPER := make(
			[dynamic]int,
			len = VERTS_PER_X_DIR * VERTS_PER_Y_DIR * VERTS_PER_Z_DIR,
			allocator = context.temp_allocator,
		)
		for &v in EXISTING_VERTICES_MAPPER do v = -1

		chunk.pos = pos

		posXF64 := f64(pos[0])
		posZF64 := f64(pos[1])
		chunkXYZ := float3{f32(pos[0]), 0, f32(pos[1])}
		chunkXYZI32 := [3]i32{i32(pos[0]), 0, i32(pos[1])}

		// chunkXSimd := #simd[4]f64{posXF64, posXF64, posXF64, posXF64}
		// chunkZSimd := #simd[4]f64{posZF64, posZF64, posZF64, posZF64}


		// for x: i32 = 0; x < VERTS_PER_X_DIR; x += 1 {
		// 	for z: i32 = 0; z < VERTS_PER_Z_DIR; z += 1 {
		// 		worldX := pos[0] + x
		// 		worldZ := pos[1] + z
		// 		biomeWeights := get_biome_weights(worldX, worldZ, seed)
		// 		height: i32 = 0
		// 		for biome, weight in biomeWeights {
		// 			if weight < MIN_BIOME_WEIGHT_TO_NOT_IGNORE do continue
		// 			height += i32(biome_height(biome, x, z, seed) * (f64(weight) / 255.0))
		// 		}
		// 		assert(height <= 1 && height >= 0)
		// 		when VISUAL_REPRESENTATION_OF_NOISE_FN_RUN_2D {
		// 			idx := index_into_point_arrays(x, 0, z)
		// 			chunk.points[idx] = height
		// 		} else {
		// 			for yCoord: i32 = MIN_Y; yCoord <= height; yCoord += 1 {
		// 				y := yCoord - MIN_Y
		// 				idx := index_into_point_arrays(x, y, z)
		// 				worldXYZ := chunkXYZI32 + [3]i32{x, yCoord, z}
		// 				// pointType := procedural_point_type(
		// 				// 	worldXYZ.x,
		// 				// 	worldXYZ.y,
		// 				// 	worldXYZ.z,
		// 				// 	seed,
		// 				// 	biomeWeights,
		// 				// )
		// 				chunk.points[idx] = procedural_point_type_noise_result(
		// 					worldXYZ.x,
		// 					worldXYZ.y,
		// 					worldXYZ.z,
		// 					seed,
		// 					biomeWeights,
		// 				)

		// 			}

		// 		}
		// 	}
		// }


		for x: i32 = 0; x < CUBES_PER_X_DIR; x += 1 {
			for z: i32 = 0; z < CUBES_PER_Z_DIR; z += 1 {
				for y: i32 = 0; y < CUBES_PER_Y_DIR; y += 1 {

					noiseResult := chunk.points[index_into_point_arrays(x, y, z)]
					if noiseResult == 0.0 do continue
					for localVert in 0 ..< 8 {
						offset := cubeVertices[localVert]
						vertIndex := [3]i32{x, y, z} + offset
						existingIdx := index_into_point_arrays(
							vertIndex.x,
							vertIndex.y,
							vertIndex.z,
						)
						if EXISTING_VERTICES_MAPPER[existingIdx] == -1 {
							coordWithoutJitter := [3]i32 {
								pos[0] + vertIndex.x,
								MIN_Y + vertIndex.y,
								pos[1] + vertIndex.z,
							}
							// jitteringVector := calculate_jitter(
							// 	coordWithoutJitter.x,
							// 	coordWithoutJitter.y,
							// 	coordWithoutJitter.z,
							// 	seed,
							// )
							finalPointCoord := [3]f32 {
								f32(coordWithoutJitter.x),
								f32(coordWithoutJitter.y),
								f32(coordWithoutJitter.z),
							}
							staticVisiblePoints[staticVisiblePointsLen] = finalPointCoord
							EXISTING_VERTICES_MAPPER[existingIdx] = staticVisiblePointsLen
							staticVisiblePointsLen += 1
						}
					}

					colorForThisCube := [4]f32 {
						noiseResult / 2,
						noiseResult / 2,
						noiseResult / 2,
						1,
					}
					for index, idx_ in cubeIndices { 	// index = cubeIndices[idx_]
						vertIndex := [3]i32{x, y, z} + cubeVertices[index]
						existingIdx := index_into_point_arrays(
							vertIndex.x,
							vertIndex.y,
							vertIndex.z,
						)
						existing := EXISTING_VERTICES_MAPPER[existingIdx]
						assert(existing != -1) // For debugging—should never hit now
						staticIndices[staticIndicesLen] = INDEX_TYPE_USED_IN_CHUNKS(existing)
						staticIndicesLen += 1
						if idx_ % 3 == 0 {
							staticColors[staticColorsLen] = colorForThisCube
							staticColorsLen += 1
						}
					}
				}
			}
		}


		assert(staticVisiblePointsLen > 0)
		assert(staticIndicesLen > 0)
		assert(staticColorsLen > 0)

		chunk.totalPoints = u32(staticVisiblePointsLen)
		chunk.totalIndices = u32(staticIndicesLen)

		for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
			assert(chunk.buffers.pointsBuffer[i].alloc != {})
			assert(chunk.buffers.indices[i].alloc != {})
			assert(chunk.buffers.colors[i].alloc != {})


			vertBufferPtr: rawptr
			vk_chk(
				vma.map_memory(vkAllocator, chunk.buffers.pointsBuffer[i].alloc, &vertBufferPtr),
			)
			mem.copy(
				vertBufferPtr,
				raw_data(staticVisiblePoints[0:staticVisiblePointsLen]),
				staticVisiblePointsLen * size_of(staticVisiblePoints[0]),
			)
			vma.unmap_memory(vkAllocator, chunk.buffers.pointsBuffer[i].alloc)

			index := chunk.buffers.indices[i]


			indexBufferPtr: rawptr
			vk_chk(vma.map_memory(vkAllocator, chunk.buffers.indices[i].alloc, &indexBufferPtr))
			mem.copy(
				indexBufferPtr,
				raw_data(staticIndices[0:staticIndicesLen]),
				staticIndicesLen * size_of(staticIndices[0]),
			)
			vma.unmap_memory(vkAllocator, chunk.buffers.indices[i].alloc)


			colorBuferPtr: rawptr
			vk_chk(vma.map_memory(vkAllocator, chunk.buffers.colors[i].alloc, &colorBuferPtr))
			mem.copy(
				colorBuferPtr,
				raw_data(staticColors[0:staticColorsLen]),
				staticColorsLen * size_of(staticColors[0]),
			)
			vma.unmap_memory(vkAllocator, chunk.buffers.colors[i].alloc)
		}


	}
} else {
	chunk_init :: proc(state: ^ChunkWorkerState) {
		tracy.Zone()
		pos := state.pos
		chunk := &Chunks[state.xIdx][state.zIdx]
		{
			tracy.Zone()
			for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
				if chunk.buffers.pointsBuffer[i].buffer != {} do continue
				assert(chunk.buffers.indices[i].buffer == {})
				assert(chunk.buffers.colors[i].buffer == {})

				vk_chk(
					vma.create_buffer(
						vkAllocator,
						{
							sType = .BUFFER_CREATE_INFO,
							size = vk.DeviceSize(MAX_POINTS * size_of([3]f32)),
							usage = {.VERTEX_BUFFER},
						},
						{flags = {.Host_Access_Sequential_Write, .Mapped}, usage = .Auto},
						&chunk.buffers.pointsBuffer[i].buffer,
						&chunk.buffers.pointsBuffer[i].alloc,
						nil,
					),
				)
				vk_chk(
					vma.create_buffer(
						vkAllocator,
						{
							sType = .BUFFER_CREATE_INFO,
							size = vk.DeviceSize(MAX_INDICES * size_of(INDEX_TYPE_USED_IN_CHUNKS)),
							usage = {.INDEX_BUFFER},
						},
						{flags = {.Host_Access_Sequential_Write, .Mapped}, usage = .Auto},
						&chunk.buffers.indices[i].buffer,
						&chunk.buffers.indices[i].alloc,
						nil,
					),
				)

				vk_chk(
					vma.create_buffer(
						vkAllocator,
						{
							sType = .BUFFER_CREATE_INFO,
							size = vk.DeviceSize(MAX_COLORS * size_of([4]f32)),
							usage = {.STORAGE_BUFFER},
						},
						{flags = {.Host_Access_Sequential_Write, .Mapped}, usage = .Auto},
						&chunk.buffers.colors[i].buffer,
						&chunk.buffers.colors[i].alloc,
						nil,
					),
				)
			}
		}

		allocZoneCtx := tracy.ZoneBegin(true, tracy.TRACY_CALLSTACK)
		if chunk.alloc == {} {
			chunk.alloc = virtual.arena_allocator(&chunk.arena)
		} else {
			free_all(chunk.alloc)
		}


		staticVisiblePointsLen: INDEX_TYPE_USED_IN_CHUNKS = 0
		staticIndicesLen: int = 0
		staticColorsLen: int = 0


		chunk.pos = pos
		tracy.ZoneEnd(allocZoneCtx)

		posXF64 := f64(pos[0])
		posZF64 := f64(pos[1])
		chunkXYZ := float3{f32(pos[0]), 0, f32(pos[1])}
		chunkXYZI32 := [3]i32{i32(pos[0]), 0, i32(pos[1])}

		// chunkXSimd := #simd[4]f64{posXF64, posXF64, posXF64, posXF64}
		// chunkZSimd := #simd[4]f64{posZF64, posZF64, posZF64, posZF64}

		// isCrystalblooomArr := [VERTS_PER_X_DIR * VERTS_PER_Z_DIR]bool{}
		state.vertexMapper = {}
		{
			tracy.Zone()
			BIOME_THRESHOLD :: 20
			for x: i32 = 0; x < VERTS_PER_X_DIR; x += 1 {
				worldX := pos[0] + x
				for z: i32 = 0; z < VERTS_PER_Z_DIR; z += 1 {
					worldZ := pos[1] + z
					biomeWeights := get_biome_weights(worldX, worldZ, seed)
					height: i32 = 0
					for weight, biome in biomeWeights {
						if weight < MIN_BIOME_WEIGHT_TO_NOT_IGNORE do continue
						height += i32(
							biome_height(biome, worldX, worldZ, seed) * (f32(weight) * inv255),
						)
						height = math.clamp(height, MIN_Y + 1, MAX_Y - 1)
					}
					assert(height >= MIN_Y)
					// isCrystalblooomArr[x * VERTS_PER_Z_DIR + z] =
					// 	biomeWeights[.Crystalbloom] > BIOME_THRESHOLD
					state.heightMap[x * VERTS_PER_Z_DIR + z] = height

					for yCoord: i32 = MIN_Y; yCoord <= height; yCoord += 1 {
						y := yCoord - MIN_Y
						idx := index_into_point_arrays(x, y, z)
						worldXYZ := [3]i32{worldX, yCoord, worldZ}
						pointType := procedural_point_type(
							biomeWeights,
							worldXYZ.x,
							worldXYZ.y,
							worldXYZ.z,
							height,
							seed,
						)

						chunk.points[idx] = pointType

					}
				}
			}

		}
		// for &h in state.heightMap do h = MAX_Y - 1
		// {

		// 	for dz: i32 = 0; dz < VERTS_PER_Z_DIR - 1; dz += 2 {
		// 		// state.heightMap[0 * VERTS_PER_Z_DIR + dz] = MAX_Y - 1
		// 		startingIdx := [3]i32{0, 0 + (MAX_Y - MIN_Y) / 2, dz}
		// 		chunk.points[index_into_point_arrays(startingIdx + cubeVertices[0])] = .LightPurpleGround
		// 		chunk.points[index_into_point_arrays(startingIdx + cubeVertices[1])] = .LightPurpleGround
		// 		chunk.points[index_into_point_arrays(startingIdx + cubeVertices[2])] = .LightPurpleGround
		// 		chunk.points[index_into_point_arrays(startingIdx + cubeVertices[3])] = .LightPurpleGround
		// 		chunk.points[index_into_point_arrays(startingIdx + cubeVertices[5])] = .LightPurpleGround
		// 		chunk.points[index_into_point_arrays(startingIdx + cubeVertices[7])] = .LightPurpleGround

		// 		// chunk.points[index_into_point_arrays(0, 0 + (MAX_Y - MIN_Y) / 2, dz + 1)] = .LightPurpleGround
		// 		// chunk.points[index_into_point_arrays(1, 0 + (MAX_Y - MIN_Y) / 2, dz + 1)] = .LightPurpleGround


		// 	}

		// }
		{
			tracy.Zone()


			airSimd := #simd[8]u16 {
				u16(PointType.Air),
				u16(PointType.Air),
				u16(PointType.Air),
				u16(PointType.Air),
				u16(PointType.Air),
				u16(PointType.Air),
				u16(PointType.Air),
				u16(PointType.Air),
			}

			points := &chunk.points
			mapper := &state.vertexMapper

			for x: i32 = 0; x < VERTS_PER_X_DIR - 1; x += 1 {
				worldX := pos[0] + x
				isEdgeX := x == 0 || x == VERTS_PER_X_DIR - 2
				for z: i32 = 0; z < VERTS_PER_Z_DIR - 1; z += 1 {

					isEdgeZ := z == 0 || z == VERTS_PER_Z_DIR - 2
					worldZ := pos[1] + z
					height := state.heightMap[x * VERTS_PER_Z_DIR + z]


					for y: i32 = 0; y < height - MIN_Y; y += 1 {
						baseIndex := x * VERT_STRIDE_X + y * VERT_STRIDE_Y + z
						pointType := points[baseIndex]
						if pointType == .Air do continue

						isEdgeY := y == 0 || y == height - MIN_Y - 1
						isChunkEdge := isEdgeX || isEdgeY || isEdgeZ
						yCoord := y + MIN_Y
						base := [3]i32{x, y, z}
						worldBase := [3]i32{worldX, yCoord, worldZ}
						// pointTypeSimd := #simd[8]u16 {
						// 	u16(pointType),
						// 	u16(pointType),
						// 	u16(pointType),
						// 	u16(pointType),
						// 	u16(pointType),
						// 	u16(pointType),
						// 	u16(pointType),
						// 	u16(pointType),
						// }
						if !isChunkEdge {
							isSurrounded := true
							for p in pointsSimdNeighbors {
								neighbourEdge := baseIndex + p
								neighbour := cast(#simd[8]u16)neighbourEdge
								eqMask := simd.lanes_eq(neighbour, airSimd)
								anyAir := simd.reduce_or(eqMask) != 0
								if anyAir {
									isSurrounded = false
									break
								}
							}
							isSurrounded &= points[baseIndex + pointsNeighbourLeftCoords] != .Air
							isSurrounded &= points[baseIndex + pointsNeighbourRightCoords] != .Air
							if isSurrounded do continue

						}

						oneZeroZero := get_point_type(base, {1, 0, 0}, chunk.points[:])
						oneOneZero := get_point_type(base, {1, 1, 0}, chunk.points[:])
						zeroOneZero := get_point_type(base, {0, 1, 0}, chunk.points[:])

						zeroZeroOne := get_point_type(base, {0, 0, 1}, chunk.points[:])
						zeroOneOne := get_point_type(base, {0, 1, 1}, chunk.points[:])

						oneZeroOne := get_point_type(base, {1, 0, 1}, chunk.points[:])

						PointTypePlusOffset :: struct {
							t: PointType,
							o: [3]i32,
						}
						possibleTriangles := [?][3]PointTypePlusOffset {
							[3]PointTypePlusOffset {
								{pointType, {0, 0, 0}},
								{oneZeroZero, {1, 0, 0}},
								{oneOneZero, {1, 1, 0}},
							},
							[3]PointTypePlusOffset {
								{pointType, {0, 0, 0}},
								{oneOneZero, {1, 1, 0}},
								{zeroOneZero, {0, 1, 0}},
							},
							[3]PointTypePlusOffset {
								{pointType, {0, 0, 0}},
								{zeroZeroOne, {0, 0, 1}},
								{zeroOneOne, {0, 1, 1}},
							},
							[3]PointTypePlusOffset {
								{pointType, {0, 0, 0}},
								{zeroOneOne, {0, 1, 1}},
								{zeroOneZero, {0, 1, 0}},
							},
							[3]PointTypePlusOffset {
								{pointType, {0, 0, 0}},
								{oneZeroZero, {1, 0, 0}},
								{oneZeroOne, {1, 0, 1}},
							},
							[3]PointTypePlusOffset {
								{pointType, {0, 0, 0}},
								{oneZeroOne, {1, 0, 1}},
								{zeroZeroOne, {0, 0, 1}},
							},
						}
						possibleTrianglesLoop: for possibleTriangle in possibleTriangles {
							for pPlusOffset in possibleTriangle {
								if pPlusOffset.t == .Air do continue possibleTrianglesLoop
							}
							p0 := possibleTriangle[0].t
							p1 := possibleTriangle[1].t
							p2 := possibleTriangle[2].t

							p0WorldCoord := worldBase + possibleTriangle[0].o
							p0Idx := get_or_create_mapper_idx(
								mapper[:],
								p0WorldCoord,
								base + possibleTriangle[0].o,
								state.visiblePoints[:],
								&staticVisiblePointsLen,
							)

							p1WorldCoord := worldBase + possibleTriangle[1].o
							p1Idx := get_or_create_mapper_idx(
								mapper[:],
								p1WorldCoord,
								base + possibleTriangle[1].o,
								state.visiblePoints[:],
								&staticVisiblePointsLen,
							)

							p2WorldCoord := worldBase + possibleTriangle[2].o
							p2Idx := get_or_create_mapper_idx(
								mapper[:],
								p2WorldCoord,
								base + possibleTriangle[2].o,
								state.visiblePoints[:],
								&staticVisiblePointsLen,
							)
							state.indices[staticIndicesLen + 0] = p0Idx
							state.indices[staticIndicesLen + 1] = p1Idx
							state.indices[staticIndicesLen + 2] = p2Idx

							staticIndicesLen += 3
							state.colors[staticColorsLen] = triangle_decide_color(
								{
									possibleTriangle[0].t,
									possibleTriangle[1].t,
									possibleTriangle[2].t,
								},
								{
									Random_Colors_Per_Point_Type[p0][staticVisiblePointsLen % len(Random_Colors_Per_Point_Type[p0])],
									Random_Colors_Per_Point_Type[p1][staticVisiblePointsLen % len(Random_Colors_Per_Point_Type[p1])],
									Random_Colors_Per_Point_Type[p2][staticVisiblePointsLen % len(Random_Colors_Per_Point_Type[p2])],
								},
							)
							staticColorsLen += 1

						}

					}
				}
			}
		}

		assert(staticVisiblePointsLen > 0)
		assert(staticIndicesLen > 0)
		assert(staticColorsLen > 0)
		assert(staticIndicesLen % 3 == 0)
		assert(staticColorsLen * 3 == staticIndicesLen)


		chunk.totalPoints = u32(staticVisiblePointsLen)
		chunk.totalIndices = u32(staticIndicesLen)

		{
			tracy.Zone()
			for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
				assert(chunk.buffers.pointsBuffer[i].alloc != {})
				assert(chunk.buffers.indices[i].alloc != {})
				assert(chunk.buffers.colors[i].alloc != {})


				vertBufferPtr: rawptr
				vk_chk(
					vma.map_memory(
						vkAllocator,
						chunk.buffers.pointsBuffer[i].alloc,
						&vertBufferPtr,
					),
				)
				mem.copy(
					vertBufferPtr,
					raw_data(state.visiblePoints[0:staticVisiblePointsLen]),
					int(staticVisiblePointsLen) * size_of(state.visiblePoints[0]),
				)
				vma.unmap_memory(vkAllocator, chunk.buffers.pointsBuffer[i].alloc)


				indexBufferPtr: rawptr
				vk_chk(
					vma.map_memory(vkAllocator, chunk.buffers.indices[i].alloc, &indexBufferPtr),
				)
				mem.copy(
					indexBufferPtr,
					raw_data(state.indices[0:staticIndicesLen]),
					staticIndicesLen * size_of(state.indices[0]),
				)
				vma.unmap_memory(vkAllocator, chunk.buffers.indices[i].alloc)


				colorBufferPtr: rawptr
				vk_chk(vma.map_memory(vkAllocator, chunk.buffers.colors[i].alloc, &colorBufferPtr))
				mem.copy(
					colorBufferPtr,
					raw_data(state.colors[0:staticColorsLen]),
					staticColorsLen * size_of(state.colors[0]),
				)
				vma.unmap_memory(vkAllocator, chunk.buffers.colors[i].alloc)
			}


		}
	}

}
get_point_type :: proc(base: [3]i32, offset: [3]i32, points: []PointType) -> PointType {
	finalCoord := base + offset

	if finalCoord.x < 0 || finalCoord.x >= VERTS_PER_X_DIR do return .Air
	if finalCoord.y < 0 || finalCoord.y >= VERTS_PER_Y_DIR do return .Air
	if finalCoord.z < 0 || finalCoord.z >= VERTS_PER_Z_DIR do return .Air

	index := index_into_point_arrays(finalCoord)
	return points[index]
}
get_or_create_mapper_idx :: proc(
	mapper: []Maybe(INDEX_TYPE_USED_IN_CHUNKS),
	worldCoord: [3]i32,
	idx: [3]i32,
	vertexArr: [][3]f32,
	vertexArrayLen: ^INDEX_TYPE_USED_IN_CHUNKS,
) -> INDEX_TYPE_USED_IN_CHUNKS {
	assert(len(mapper) > 0)
	assert(idx[0] >= 0 && idx[0] < VERTS_PER_X_DIR)
	assert(idx[1] >= 0 && idx[1] < VERTS_PER_Y_DIR)
	assert(idx[2] >= 0 && idx[2] < VERTS_PER_Z_DIR)
	assert(len(vertexArr) > 0)
	assert(vertexArrayLen != nil)


	idxAsValue := index_into_point_arrays(idx)
	switch v in mapper[idxAsValue] {
	case u32:
		return v
	case:
		finalCoord :=
			[3]f32{f32(worldCoord.x), f32(worldCoord.y), f32(worldCoord.z)} +
			calculate_jitter(worldCoord.x, worldCoord.y, worldCoord.z, seed)
		vertexArr[vertexArrayLen^] = finalCoord
		mapper[idxAsValue] = vertexArrayLen^
		currIdx := vertexArrayLen^
		vertexArrayLen^ += 1
		return currIdx
	}

}
calculate_jitter :: proc(x, y, z: i32, seed: u64) -> [3]f32 {
	ux := u64(x)
	uy := u64(y)
	uz := u64(z)
	h := ux * 73856093 + uy * 19349663 + uz * 83492791 + seed
	h = (h ~ (h >> 13)) * 0x27d4eb2d
	h = (h ~ (h >> 15)) * 0x85ebca6b
	h = h ~ (h >> 16)
	fx := f32((h) & 0xFFFF) / 65535.0 - 0.2
	fy := f32((h >> 16) & 0xFFFF) / 65535.0 - 0.2
	fz := f32((h >> 32) & 0xFFFF) / 65535.0 - 0.2
	return {fx, fy, fz}
}


chunks_shift_per_player_movement :: proc(c: ^Camera) {
	tracy.Zone()

	xzOfCurrentCenterChunk := int2{i32(c.pos.x), i32(c.pos.z)} / CHUNK_STRIDE
	xzOfPrevCenterChunk := Chunks[CHUNK_MIDDLE_X_INDEX][CHUNK_MIDDLE_Z_INDEX].pos / CHUNK_STRIDE
	if xzOfCurrentCenterChunk == xzOfPrevCenterChunk do return
	delta := xzOfCurrentCenterChunk - xzOfPrevCenterChunk
	half := CHUNKS_PER_DIRECTION / 2

	if delta.x != 0 {
		count := abs(delta.x)
		for i in 0 ..< count {
			if delta.x > 0 {
				for x in 0 ..< CHUNKS_PER_DIRECTION - 1 {
					for z in 0 ..< CHUNKS_PER_DIRECTION {
						firstBuffers := Chunks[x][z].buffers
						secondBuffers := Chunks[x + 1][z].buffers
						Chunks[x][z] = Chunks[x + 1][z]
						Chunks[x][z].buffers, Chunks[x + 1][z].buffers =
							secondBuffers, firstBuffers
						Chunks[x + 1][z].points = {}
						Chunks[x + 1][z].arena = {}
						Chunks[x + 1][z].alloc = {}
					}
				}
				for z in 0 ..< CHUNKS_PER_DIRECTION {
					relX := i32(CHUNKS_PER_DIRECTION - 1 - half) + i32(i)
					relZ := i32(z - half)
					pos := int2 {
						(xzOfCurrentCenterChunk[0] + relX) * CHUNK_STRIDE,
						(xzOfCurrentCenterChunk[1] + relZ) * CHUNK_STRIDE,
					}
					chunk_init_add_thread(CHUNKS_PER_DIRECTION - 1, z, pos)
				}
			} else {
				for x := CHUNKS_PER_DIRECTION - 1; x > 0; x -= 1 {
					for z in 0 ..< CHUNKS_PER_DIRECTION {
						firstBuffers := Chunks[x][z].buffers
						secondBuffers := Chunks[x - 1][z].buffers
						Chunks[x][z] = Chunks[x - 1][z]
						Chunks[x][z].buffers, Chunks[x - 1][z].buffers =
							secondBuffers, firstBuffers

						Chunks[x - 1][z].points = {}
						Chunks[x - 1][z].arena = {}
						Chunks[x - 1][z].alloc = {}
					}
				}
				for z in 0 ..< CHUNKS_PER_DIRECTION {
					relX := i32(0 - half) - i32(i)
					relZ := i32(z - half)
					pos := int2 {
						(xzOfCurrentCenterChunk[0] + relX) * CHUNK_STRIDE,
						(xzOfCurrentCenterChunk[1] + relZ) * CHUNK_STRIDE,
					}
					chunk_init_add_thread(0, z, pos)
				}
			}
		}
	}

	if delta[1] != 0 {
		count := abs(delta[1])
		for i in 0 ..< count {
			if delta[1] > 0 {
				for z in 0 ..< CHUNKS_PER_DIRECTION - 1 {
					for x in 0 ..< CHUNKS_PER_DIRECTION {
						firstBuffers := Chunks[x][z].buffers
						secondBuffers := Chunks[x][z + 1].buffers
						Chunks[x][z] = Chunks[x][z + 1]
						Chunks[x][z].buffers, Chunks[x][z + 1].buffers =
							secondBuffers, firstBuffers

						Chunks[x][z + 1].points = {}
						Chunks[x][z + 1].arena = {}
						Chunks[x][z + 1].alloc = {}
					}
				}
				for x in 0 ..< CHUNKS_PER_DIRECTION {
					relX := i32(x - half)
					relZ := i32(CHUNKS_PER_DIRECTION - 1 - half) + i32(i)
					pos := int2 {
						(xzOfCurrentCenterChunk[0] + relX) * CHUNK_STRIDE,
						(xzOfCurrentCenterChunk[1] + relZ) * CHUNK_STRIDE,
					}
					chunk_init_add_thread(x, CHUNKS_PER_DIRECTION - 1, pos)
				}
			} else {
				for z := CHUNKS_PER_DIRECTION - 1; z > 0; z -= 1 {
					for x in 0 ..< CHUNKS_PER_DIRECTION {
						firstBuffers := Chunks[x][z].buffers
						secondBuffers := Chunks[x][z - 1].buffers
						Chunks[x][z] = Chunks[x][z - 1]
						Chunks[x][z].buffers, Chunks[x][z - 1].buffers =
							secondBuffers, firstBuffers

						Chunks[x][z - 1].points = {}
						Chunks[x][z - 1].arena = {}
						Chunks[x][z - 1].alloc = {}
					}
				}
				for x in 0 ..< CHUNKS_PER_DIRECTION {
					relX := i32(x - half)
					relZ := i32(0 - half) - i32(i)
					pos := int2 {
						(xzOfCurrentCenterChunk[0] + relX) * CHUNK_STRIDE,
						(xzOfCurrentCenterChunk[1] + relZ) * CHUNK_STRIDE,
					}
					chunk_init_add_thread(x, 0, pos)
				}
			}
		}
	}
	sync.wait(&chunkWorkersWG)

}
chunks_draw :: proc(
	cb: vk.CommandBuffer,
	p: ^PipelineData,
	cameraUbo: vk.Buffer,
	cameraUboSize: vk.DeviceSize,
) {
	vk.CmdBindPipeline(cb, .GRAPHICS, p.graphicsPipeline)

	for x in 0 ..< len(Chunks) {
		for y in 0 ..< len(Chunks[0]) {

			chunk := &Chunks[x][y]
			// if chunk.pos != {0, 0} do continue
			if !is_chunk_in_camera_frustrum(chunk.pos, &camera) do continue
			if chunk.totalIndices == 0 do continue


			assert(chunk.buffers.pointsBuffer[vkFrameIndex].alloc != {})
			vertexBuffer := chunk.buffers.pointsBuffer[vkFrameIndex].buffer
			vertexOffset := vk.DeviceSize(0)

			vk.CmdBindVertexBuffers(cb, 0, 1, &vertexBuffer, &vertexOffset)
			#assert(INDEX_TYPE_USED_IN_CHUNKS == u32)

			vk.CmdBindIndexBuffer(cb, chunk.buffers.indices[vkFrameIndex].buffer, 0, .UINT32)


			cameraInfo := vk.DescriptorBufferInfo {
				buffer = cameraUbo,
				offset = 0,
				range  = cameraUboSize,
			}

			colorInfo := vk.DescriptorBufferInfo {
				buffer = chunk.buffers.colors[vkFrameIndex].buffer,
				offset = 0,
				range  = vk.DeviceSize(vk.WHOLE_SIZE),
			}

			writes := [?]vk.WriteDescriptorSet {
				{
					sType = .WRITE_DESCRIPTOR_SET,
					dstBinding = 0,
					descriptorCount = 1,
					descriptorType = .UNIFORM_BUFFER,
					pBufferInfo = &cameraInfo,
				},
				{
					sType = .WRITE_DESCRIPTOR_SET,
					dstBinding = 1,
					descriptorCount = 1,
					descriptorType = .STORAGE_BUFFER,
					pBufferInfo = &colorInfo,
				},
			}

			vk.CmdPushDescriptorSetKHR(
				cb,
				.GRAPHICS,
				p.layout,
				0,
				len(writes),
				raw_data(writes[:]),
			)

			vk.CmdDrawIndexed(cb, chunk.totalIndices, 1, 0, 0, 0)
		}
	}
}

chunks_destroy :: proc() {
	chunkShutdown = true
	for _ in chunkWorkerThreads {
		sync.sema_post(&chunkJobSema)
	}

	for t in chunkWorkerThreads {
		thread.join(t)
		thread.destroy(t)
	}

	for &chunkX in Chunks {
		for &chunk in chunkX {
			chunk_destroy(&chunk)
		}
	}

	vmem.arena_destroy(&WorldArena)


}
chunk_destroy :: proc(chunk: ^Chunk) {
	assert(chunk != nil)

	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		if chunk.buffers.pointsBuffer[i].alloc != {} {
			vma.destroy_buffer(
				vkAllocator,
				chunk.buffers.pointsBuffer[i].buffer,
				chunk.buffers.pointsBuffer[i].alloc,
			)
			chunk.buffers.pointsBuffer[i] = {}
		}
		if chunk.buffers.indices[i].alloc != {} {
			vma.destroy_buffer(
				vkAllocator,
				chunk.buffers.indices[i].buffer,
				chunk.buffers.indices[i].alloc,
			)
			chunk.buffers.indices[i] = {}
		}
		if chunk.buffers.colors[i].alloc != {} {
			vma.destroy_buffer(
				vkAllocator,
				chunk.buffers.colors[i].buffer,
				chunk.buffers.colors[i].alloc,
			)
			chunk.buffers.colors[i] = {}
		}
	}
	chunk.buffers = {}

	free_all(chunk.alloc)
	chunk.pos = {0, 0}
	chunk.totalPoints = 0
	chunk.totalIndices = 0
}
