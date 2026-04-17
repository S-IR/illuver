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
import "gs"
import vk "vendor:vulkan"
import "vkh"

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
	points:        [VERTS_PER_X_DIR * VERTS_PER_Y_DIR * VERTS_PER_Z_DIR]u16,
	heightMap:     [VERTS_PER_X_DIR * VERTS_PER_Z_DIR]i32,
	buffers:       struct {
		pointsBuffer: [vkh.MAX_FRAMES_IN_FLIGHT]vkh.VkBufferPoolElem,
		indices:      [vkh.MAX_FRAMES_IN_FLIGHT]vkh.VkBufferPoolElem,
		colors:       [vkh.MAX_FRAMES_IN_FLIGHT]vkh.VkBufferPoolElem,
	},
	pos:           int2,
	pendingUpload: [vkh.MAX_FRAMES_IN_FLIGHT]b32,
	mutex:         sync.Mutex,
	totalPoints:   u32,
	totalIndices:  u32,
	arena:         virtual.Arena,
	alloc:         mem.Allocator,
	dirty:         bool,
}


// chunk_point_get :: proc(c: ^Chunk, x, y, z: i32) -> PointType {
// 	return c.points[x * CUBES_PER_Y_DIR * CUBES_PER_Z_DIR + y * CUBES_PER_Z_DIR + z]
// }

CHUNKS_PER_DIRECTION :: 5

ENERGY_TICKING_DIRECTION_LEN :: CHUNKS_PER_DIRECTION
Chunks := [CHUNKS_PER_DIRECTION][CHUNKS_PER_DIRECTION]Chunk{}

ChunkPrevEnergyCache: [dynamic]u16
CHUNK_MIDDLE_X_INDEX :: (CHUNKS_PER_DIRECTION / 2)
CHUNK_MIDDLE_Z_INDEX :: (CHUNKS_PER_DIRECTION / 2)

ChunkAtTheCenter := int2{}

WorldArena := vmem.Arena{}
WorldAllocator := mem.Allocator{}

chunks_init :: proc(c: ^camera.Camera) {
	centerChunk := int2{i32(c.pos.x), i32(c.pos.z)} / CHUNK_SIZE
	half :: CHUNKS_PER_DIRECTION / 2


	err := vmem.arena_init_growing(&WorldArena)
	ensure(err == nil)
	WorldAllocator = vmem.arena_allocator(&WorldArena)

	chunkJobQueue = make([dynamic]ChunkJob, WorldAllocator)
	chunkWorkerStates = make([dynamic]ChunkWorkerState, gs.NUM_CORES - 1, WorldAllocator)
	chunkWorkerThreads = make([dynamic]^thread.Thread, gs.NUM_CORES - 1, WorldAllocator)

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

	ChunkPrevEnergyCache = make(
		[dynamic]u16,
		ENERGY_TICKING_DIRECTION_LEN * ENERGY_TICKING_DIRECTION_LEN * MAX_POINTS,
		WorldAllocator,
	)

}

energy_tick :: proc(energyTickType: bit_set[EnergyType]) {


	mem.zero(raw_data(ChunkPrevEnergyCache), size_of(ChunkPrevEnergyCache))
	for &chunkRow, x in Chunks {
		for &chunk, z in chunkRow {
			start := index_into_energy_cache(x, z)
			// ensure((start + int(MAX_POINTS)) < len(ChunkPrevEnergyCache))
			assert(start >= 0)
			assert(int(start) + len(chunk.points) <= len(ChunkPrevEnergyCache))

			ptrStart := mem.ptr_offset(raw_data(ChunkPrevEnergyCache), start)
			mem.copy(
				ptrStart,
				raw_data(chunk.points[:]),
				len(chunk.points) * size_of(chunk.points[0]),
			)

			// ChunkPrevEnergyCache[start:start + MAX_POINTS] = chunk.points
			// ChunkPrevEnergyCache[x * CHUNKS_PER_DIRECTION + z * MAX_POINTS]
		}
	}

	for &chunkRow, x in Chunks {
		for &chunk, z in chunkRow {
			chunk_energy_tick_add_thread(x, z, energyTickType)
		}
	}
}
VERT_STRIDE_X :: VERTS_PER_Y_DIR * VERTS_PER_Z_DIR
VERT_STRIDE_Y :: VERTS_PER_Z_DIR
index_into_point_arrays_scalars :: #force_inline proc "contextless" (x, y, z: i32) -> i32 {
	return x * VERT_STRIDE_X + y * VERT_STRIDE_Y + z
}
index_into_point_arrays_vector :: #force_inline proc "contextless" (v: [3]i32) -> i32 {
	return v.x * VERT_STRIDE_X + v.y * VERT_STRIDE_Y + v.z
}
index_into_point_arrays :: proc {
	index_into_point_arrays_scalars,
	index_into_point_arrays_vector,
}
MAX_POINTS :: VERTS_PER_X_DIR * VERTS_PER_Y_DIR * VERTS_PER_Z_DIR
MAX_POINTS_INT :: int(MAX_POINTS)

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
		for i in 0 ..< vkh.MAX_FRAMES_IN_FLIGHT {
			if chunk.buffers.pointsBuffer[i].alloc != {} do continue
			assert(chunk.buffers.indices[i].buffer == {})
			assert(chunk.buffers.colors[i].buffer == {})

			vkh.chk(
				vma.create_buffer(
					vkh.allocator,
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
			vkh.chk(
				vma.create_buffer(
					vkh.allocator,
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

			vkh.chk(
				vma.create_buffer(
					vkh.allocator,
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
		// 		biomeWeights := get_biome_weights(worldX, worldZ, gs.seed)
		// 		height: i32 = 0
		// 		for biome, weight in biomeWeights {
		// 			if weight < MIN_BIOME_WEIGHT_TO_NOT_IGNORE do continue
		// 			height += i32(biome_height(biome, x, z, gs.seed) * (f64(weight) / 255.0))
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
		// 				// 	gs.seed,
		// 				// 	biomeWeights,
		// 				// )
		// 				chunk.points[idx] = procedural_point_type_noise_result(
		// 					worldXYZ.x,
		// 					worldXYZ.y,
		// 					worldXYZ.z,
		// 					gs.seed,
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
							// jitteringVector := (calculate_jitter)(
							// 	coordWithoutJitter.x,
							// 	coordWithoutJitter.y,
							// 	coordWithoutJitter.z,
							// 	gs.seed,
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

		for i in 0 ..< vkh.MAX_FRAMES_IN_FLIGHT {
			assert(chunk.buffers.pointsBuffer[i].alloc != {})
			assert(chunk.buffers.indices[i].alloc != {})
			assert(chunk.buffers.colors[i].alloc != {})


			vertBufferPtr: rawptr
			vkh.chk(
				vma.map_memory(vkh.allocator, chunk.buffers.pointsBuffer[i].alloc, &vertBufferPtr),
			)
			mem.copy(
				vertBufferPtr,
				raw_data(staticVisiblePoints[0:staticVisiblePointsLen]),
				staticVisiblePointsLen * size_of(staticVisiblePoints[0]),
			)
			vma.unmap_memory(vkh.allocator, chunk.buffers.pointsBuffer[i].alloc)

			index := chunk.buffers.indices[i]


			indexBufferPtr: rawptr
			vkh.chk(vma.map_memory(vkh.allocator, chunk.buffers.indices[i].alloc, &indexBufferPtr))
			mem.copy(
				indexBufferPtr,
				raw_data(staticIndices[0:staticIndicesLen]),
				staticIndicesLen * size_of(staticIndices[0]),
			)
			vma.unmap_memory(vkh.allocator, chunk.buffers.indices[i].alloc)


			colorBuferPtr: rawptr
			vkh.chk(vma.map_memory(vkh.allocator, chunk.buffers.colors[i].alloc, &colorBuferPtr))
			mem.copy(
				colorBuferPtr,
				raw_data(staticColors[0:staticColorsLen]),
				staticColorsLen * size_of(staticColors[0]),
			)
			vma.unmap_memory(vkh.allocator, chunk.buffers.colors[i].alloc)
		}


	}
} else {
	chunk_init :: proc(state: ^ChunkWorkerState) {
		tracy.Zone()
		pos := state.pos
		chunk := &Chunks[state.xIdx][state.zIdx]
		{
			tracy.Zone()
			for i in 0 ..< vkh.MAX_FRAMES_IN_FLIGHT {
				if chunk.buffers.pointsBuffer[i].buffer != {} do continue
				assert(chunk.buffers.indices[i].buffer == {})
				assert(chunk.buffers.colors[i].buffer == {})

				vkh.chk(
					vma.create_buffer(
						vkh.allocator,
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
				vkh.chk(
					vma.create_buffer(
						vkh.allocator,
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

				vkh.chk(
					vma.create_buffer(
						vkh.allocator,
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
					biomeWeights := get_biome_weights(worldX, worldZ, gs.seed)
					height: i32 = 0
					for weight, biome in biomeWeights {
						if weight < MIN_BIOME_WEIGHT_TO_NOT_IGNORE do continue
						height += i32(
							biome_height(biome, worldX, worldZ, gs.seed) * (f32(weight) * inv255),
						)
						height = math.clamp(height, MIN_Y + 1, MAX_Y - 1)
					}
					// height = 0
					assert(height >= MIN_Y)
					// isCrystalblooomArr[x * VERTS_PER_Z_DIR + z] =
					// 	biomeWeights[.Crystalbloom] > BIOME_THRESHOLD
					chunk.heightMap[x * VERTS_PER_Z_DIR + z] = height

					for yCoord: i32 = MIN_Y; yCoord <= height; yCoord += 1 {
						y := yCoord - MIN_Y
						idx := index_into_point_arrays(x, y, z)
						worldXYZ := [3]i32{worldX, yCoord, worldZ}
						pointVal := procedural_point_type(
							biomeWeights,
							worldXYZ.x,
							worldXYZ.y,
							worldXYZ.z,
							height,
							gs.seed,
						)
						assert(is_valid_point_u16(pointVal))
						chunk.points[idx] = pointVal

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
		chunk_create_gpu_geometry(chunk, state)

	}
	INVALID :: u32(0xFFFFFFFF)

	chunk_create_gpu_geometry :: proc(chunk: ^Chunk, state: ^ChunkWorkerState) {
		pos := state.pos

		staticVisiblePointsLen: INDEX_TYPE_USED_IN_CHUNKS = 0
		staticIndicesLen: int = 0
		staticColorsLen: int = 0

		visible := &state.visiblePoints
		indices := &state.indices
		colors := &state.colors


		points := &chunk.points
		mapper := &state.vertexMapper

		{
			tracy.Zone()
			mem.set(mapper, 0xFF, len(mapper) * size_of(mapper[0]))
		}

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

		// staticBarycentricsLen: int = 0
		// worldBase := [3]i32{state.pos.x, 0, state.pos[1]}
		#no_bounds_check {
			tracy.Zone()


			for x: i32 = 0; x < VERTS_PER_X_DIR - 1; x += 1 {
				worldX := pos[0] + x
				isEdgeX := x == 0 || x == VERTS_PER_X_DIR - 2
				for z: i32 = 0; z < VERTS_PER_Z_DIR - 1; z += 1 {

					isEdgeZ := z == 0 || z == VERTS_PER_Z_DIR - 2
					worldZ := pos[1] + z
					height := chunk.heightMap[x * VERTS_PER_Z_DIR + z]


					for y: i32 = 0; y <= height - MIN_Y; y += 1 {
						baseIndex := x * VERT_STRIDE_X + y * VERT_STRIDE_Y + z
						pointVal := points[baseIndex]
						if pointVal == 0 do continue

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
								neighbourIndices := baseIndex + p
								neighbour := #simd[8]u16 {
									u16(points[simd.extract(neighbourIndices, 0)]),
									u16(points[simd.extract(neighbourIndices, 1)]),
									u16(points[simd.extract(neighbourIndices, 2)]),
									u16(points[simd.extract(neighbourIndices, 3)]),
									u16(points[simd.extract(neighbourIndices, 4)]),
									u16(points[simd.extract(neighbourIndices, 5)]),
									u16(points[simd.extract(neighbourIndices, 6)]),
									u16(points[simd.extract(neighbourIndices, 7)]),
								}
								eqMask := simd.lanes_eq(neighbour, airSimd)
								anyAir := simd.reduce_or(eqMask) != 0
								if anyAir {
									isSurrounded = false
									break
								}
							}
							isSurrounded &= points[baseIndex + pointsNeighbourLeftCoords] != 0
							isSurrounded &= points[baseIndex + pointsNeighbourRightCoords] != 0
							if isSurrounded do continue

						}

						// Inline neighbor point fetches
						nx1 := x + 1; ny1 := y; nz1 := z
						oneZeroZero :=
							points[index_into_point_arrays(nx1, ny1, nz1)] if nx1 < VERTS_PER_X_DIR else 0

						nx2 := x + 1; ny2 := y + 1; nz2 := z
						oneOneZero :=
							points[index_into_point_arrays(nx2, ny2, nz2)] if nx2 < VERTS_PER_X_DIR && ny2 < VERTS_PER_Y_DIR else 0

						nx3 := x; ny3 := y + 1; nz3 := z
						zeroOneZero :=
							points[index_into_point_arrays(nx3, ny3, nz3)] if ny3 < VERTS_PER_Y_DIR else 0

						nx4 := x; ny4 := y; nz4 := z + 1
						zeroZeroOne :=
							points[index_into_point_arrays(nx4, ny4, nz4)] if nz4 < VERTS_PER_Z_DIR else 0

						nx5 := x; ny5 := y + 1; nz5 := z + 1
						zeroOneOne :=
							points[index_into_point_arrays(nx5, ny5, nz5)] if ny5 < VERTS_PER_Y_DIR && nz5 < VERTS_PER_Z_DIR else 0

						nx6 := x + 1; ny6 := y; nz6 := z + 1
						oneZeroOne :=
							points[index_into_point_arrays(nx6, ny6, nz6)] if nx6 < VERTS_PER_X_DIR && nz6 < VERTS_PER_Z_DIR else 0


						if pointVal != 0 && oneZeroZero != 0 && oneOneZero != 0 {
							i0 := geometry_process_vertex(
								mapper[:],
								worldBase,
								base,
								{0, 0, 0},
								visible[:],
								&staticVisiblePointsLen,
								gs.seed,
							)
							i1 := geometry_process_vertex(
								mapper[:],
								worldBase,
								base,
								{1, 0, 0},
								visible[:],
								&staticVisiblePointsLen,
								gs.seed,
							)
							i2 := geometry_process_vertex(
								mapper[:],
								worldBase,
								base,
								{1, 1, 0},
								visible[:],
								&staticVisiblePointsLen,
								gs.seed,
							)
							idx := staticIndicesLen
							indices[idx] = i0; indices[idx + 1] = i1; indices[idx + 2] = i2
							staticIndicesLen += 3
							colors[staticColorsLen] = triangle_decide_color(
								{pointVal, oneZeroZero, oneOneZero},
							)
							staticColorsLen += 1
						}
						if pointVal != 0 && oneOneZero != 0 && zeroOneZero != 0 {
							i0 := geometry_process_vertex(
								mapper[:],
								worldBase,
								base,
								{0, 0, 0},
								visible[:],
								&staticVisiblePointsLen,
								gs.seed,
							)
							i1 := geometry_process_vertex(
								mapper[:],
								worldBase,
								base,
								{1, 1, 0},
								visible[:],
								&staticVisiblePointsLen,
								gs.seed,
							)
							i2 := geometry_process_vertex(
								mapper[:],
								worldBase,
								base,
								{0, 1, 0},
								visible[:],
								&staticVisiblePointsLen,
								gs.seed,
							)
							idx := staticIndicesLen
							indices[idx] = i0; indices[idx + 1] = i1; indices[idx + 2] = i2
							staticIndicesLen += 3
							colors[staticColorsLen] = triangle_decide_color(
								{pointVal, oneOneZero, zeroOneZero},
							)
							staticColorsLen += 1
						}
						if pointVal != 0 && zeroZeroOne != 0 && zeroOneOne != 0 {
							i0 := geometry_process_vertex(
								mapper[:],
								worldBase,
								base,
								{0, 0, 0},
								visible[:],
								&staticVisiblePointsLen,
								gs.seed,
							)
							i1 := geometry_process_vertex(
								mapper[:],
								worldBase,
								base,
								{0, 0, 1},
								visible[:],
								&staticVisiblePointsLen,
								gs.seed,
							)
							i2 := geometry_process_vertex(
								mapper[:],
								worldBase,
								base,
								{0, 1, 1},
								visible[:],
								&staticVisiblePointsLen,
								gs.seed,
							)
							idx := staticIndicesLen
							indices[idx] = i0; indices[idx + 1] = i1; indices[idx + 2] = i2
							staticIndicesLen += 3
							colors[staticColorsLen] = triangle_decide_color(
								{pointVal, zeroZeroOne, zeroOneOne},
							)
							staticColorsLen += 1
						}
						if pointVal != 0 && zeroOneOne != 0 && zeroOneZero != 0 {
							i0 := geometry_process_vertex(
								mapper[:],
								worldBase,
								base,
								{0, 0, 0},
								visible[:],
								&staticVisiblePointsLen,
								gs.seed,
							)
							i1 := geometry_process_vertex(
								mapper[:],
								worldBase,
								base,
								{0, 1, 1},
								visible[:],
								&staticVisiblePointsLen,
								gs.seed,
							)
							i2 := geometry_process_vertex(
								mapper[:],
								worldBase,
								base,
								{0, 1, 0},
								visible[:],
								&staticVisiblePointsLen,
								gs.seed,
							)
							idx := staticIndicesLen
							indices[idx] = i0; indices[idx + 1] = i1; indices[idx + 2] = i2
							staticIndicesLen += 3
							colors[staticColorsLen] = triangle_decide_color(
								{pointVal, zeroOneOne, zeroOneZero},
							)
							staticColorsLen += 1
						}
						if pointVal != 0 && oneZeroZero != 0 && oneZeroOne != 0 {
							i0 := geometry_process_vertex(
								mapper[:],
								worldBase,
								base,
								{0, 0, 0},
								visible[:],
								&staticVisiblePointsLen,
								gs.seed,
							)
							i1 := geometry_process_vertex(
								mapper[:],
								worldBase,
								base,
								{1, 0, 0},
								visible[:],
								&staticVisiblePointsLen,
								gs.seed,
							)
							i2 := geometry_process_vertex(
								mapper[:],
								worldBase,
								base,
								{1, 0, 1},
								visible[:],
								&staticVisiblePointsLen,
								gs.seed,
							)
							idx := staticIndicesLen
							indices[idx] = i0; indices[idx + 1] = i1; indices[idx + 2] = i2
							staticIndicesLen += 3
							colors[staticColorsLen] = triangle_decide_color(
								{pointVal, oneZeroZero, oneZeroOne},
							)
							staticColorsLen += 1
						}
						if pointVal != 0 && oneZeroOne != 0 && zeroZeroOne != 0 {
							i0 := geometry_process_vertex(
								mapper[:],
								worldBase,
								base,
								{0, 0, 0},
								visible[:],
								&staticVisiblePointsLen,
								gs.seed,
							)
							i1 := geometry_process_vertex(
								mapper[:],
								worldBase,
								base,
								{1, 0, 1},
								visible[:],
								&staticVisiblePointsLen,
								gs.seed,
							)
							i2 := geometry_process_vertex(
								mapper[:],
								worldBase,
								base,
								{0, 0, 1},
								visible[:],
								&staticVisiblePointsLen,
								gs.seed,
							)
							idx := staticIndicesLen
							indices[idx] = i0; indices[idx + 1] = i1; indices[idx + 2] = i2
							staticIndicesLen += 3
							colors[staticColorsLen] = triangle_decide_color(
								{pointVal, oneZeroOne, zeroZeroOne},
							)
							staticColorsLen += 1
						}

					}
				}
			}}

		assert(staticVisiblePointsLen > 0)
		assert(staticIndicesLen > 0)
		assert(staticColorsLen > 0)
		assert(staticIndicesLen % 3 == 0)
		assert(staticColorsLen * 3 == staticIndicesLen)


		chunk.totalPoints = u32(staticVisiblePointsLen)
		chunk.totalIndices = u32(staticIndicesLen)

		safeIndices: [vkh.MAX_FRAMES_IN_FLIGHT]bool
		pendingFences := [vkh.MAX_FRAMES_IN_FLIGHT]vk.Fence{}
		pendingIndices := [vkh.MAX_FRAMES_IN_FLIGHT]u32{}
		pendingLen := 0

		for i in 0 ..< vkh.MAX_FRAMES_IN_FLIGHT {
			// A fence is "safe" if it's signaled OR if it hasn't been submitted yet
			// (which we know because the frame index hasn't wrapped past it)
			if vk.GetFenceStatus(vkh.device, vkh.fences[i]) == .SUCCESS {
				safeIndices[i] = true
			} else {
				pendingFences[pendingLen] = vkh.fences[i]
				pendingIndices[pendingLen] = i
				pendingLen += 1
			}
		}

		// Upload to all safe buffers immediately
		for i in 0 ..< vkh.MAX_FRAMES_IN_FLIGHT {
			if safeIndices[i] {
				upload_to_buffer(
					chunk,
					state,
					i,
					staticVisiblePointsLen,
					staticIndicesLen,
					staticColorsLen,
				)
			}
		}

		if pendingLen > 0 {
			vk.WaitForFences(
				vkh.device,
				u32(pendingLen),
				raw_data(pendingFences[0:pendingLen]),
				true,
				max(u64),
			)
			for i in 0 ..< pendingLen {
				upload_to_buffer(
					chunk,
					state,
					pendingIndices[i],
					staticVisiblePointsLen,
					staticIndicesLen,
					staticColorsLen,
				)
			}
		}
		upload_to_buffer :: proc(
			chunk: ^Chunk,
			state: ^ChunkWorkerState,
			i: u32,
			staticVisiblePointsLen: u32,
			staticIndicesLen, staticColorsLen: int,
		) {
			assert(chunk.buffers.pointsBuffer[i].alloc != {})
			assert(chunk.buffers.indices[i].alloc != {})
			assert(chunk.buffers.colors[i].alloc != {})


			vertBufferPtr: rawptr
			vkh.chk(
				vma.map_memory(vkh.allocator, chunk.buffers.pointsBuffer[i].alloc, &vertBufferPtr),
			)
			mem.copy(
				vertBufferPtr,
				raw_data(state.visiblePoints[0:staticVisiblePointsLen]),
				int(staticVisiblePointsLen) * size_of(state.visiblePoints[0]),
			)
			vma.unmap_memory(vkh.allocator, chunk.buffers.pointsBuffer[i].alloc)


			indexBufferPtr: rawptr
			vkh.chk(vma.map_memory(vkh.allocator, chunk.buffers.indices[i].alloc, &indexBufferPtr))
			mem.copy(
				indexBufferPtr,
				raw_data(state.indices[0:staticIndicesLen]),
				staticIndicesLen * size_of(state.indices[0]),
			)
			vma.unmap_memory(vkh.allocator, chunk.buffers.indices[i].alloc)


			colorBufferPtr: rawptr
			vkh.chk(vma.map_memory(vkh.allocator, chunk.buffers.colors[i].alloc, &colorBufferPtr))
			mem.copy(
				colorBufferPtr,
				raw_data(state.colors[0:staticColorsLen]),
				staticColorsLen * size_of(state.colors[0]),
			)
			vma.unmap_memory(vkh.allocator, chunk.buffers.colors[i].alloc)
		}
	}
	// for i in 0 ..< vkh.MAX_FRAMES_IN_FLIGHT {
	// 	// A fence is "safe" if it's signaled OR if it hasn't been submitted yet
	// 	// (which we know because the frame index hasn't wrapped past it)
	// 	if vk.GetFenceStatus(vkh.vkDevice, vkh.vkFences[i]) == .SUCCESS {
	// 		safeIndices[i] = true
	// 	} else {
	// 		append(&pendingFences, vkh.vkFences[i])
	// 		append(&pendingIndices, i)
	// 	}
	// }


	// {

	// tracy.Zone()
	// 	for i in 0 ..< vkh.MAX_FRAMES_IN_FLIGHT {

	// 		if vk.GetFenceStatus(vkh.vkDevice, vkh.vkFences[i]) != .NOT_READY {
	// 			vk.WaitForFences(vkh.vkDevice, 1, &vkh.vkFences[i], true, max(u64))
	// 		}

	// 		// vk.ResetFences(vkh.vkDevice, 1, &vkh.vkFences[i])


	// }
	// }
}


geometry_process_vertex :: proc "contextless" (
	mapper: []INDEX_TYPE_USED_IN_CHUNKS,
	worldBase: [3]i32,
	base: [3]i32,
	offset: [3]i32,
	vertexArr: [][3]f32,
	vertexArrayLen: ^INDEX_TYPE_USED_IN_CHUNKS,
	seed: u64,
) -> INDEX_TYPE_USED_IN_CHUNKS {
	#no_bounds_check {
		idxVal :=
			(base.x + offset.x) * VERT_STRIDE_X +
			(base.y + offset.y) * VERT_STRIDE_Y +
			(base.z + offset.z)
		if mapper[idxVal] != INVALID {
			return mapper[idxVal]
		}
		wx := worldBase.x + offset.x
		wy := worldBase.y + offset.y
		wz := worldBase.z + offset.z

		jitter := calculate_jitter(wx, wy, wz, gs.seed)
		vertexArr[vertexArrayLen^] = [3]f32{f32(wx), f32(wy), f32(wz)} + jitter
		mapper[idxVal] = vertexArrayLen^
		curr := vertexArrayLen^
		vertexArrayLen^ += 1
		return curr
	}

}
get_point_type :: #force_inline proc "contextless" (
	base: [3]i32,
	offset: [3]i32,
	points: []u16,
) -> u16 {
	finalCoord := base + offset

	if finalCoord.x < 0 || finalCoord.x >= VERTS_PER_X_DIR do return 0
	if finalCoord.y < 0 || finalCoord.y >= VERTS_PER_Y_DIR do return 0
	if finalCoord.z < 0 || finalCoord.z >= VERTS_PER_Z_DIR do return 0

	index := index_into_point_arrays(finalCoord)
	#no_bounds_check {
		return points[index]
	}
}

get_offset_point_type_bounds_checked :: proc(base: [3]i32, offset: [3]i32, points: []u16) -> u16 {
	finalCoord := base + offset

	if finalCoord.x < 0 || finalCoord.x >= VERTS_PER_X_DIR do return 0
	if finalCoord.y < 0 || finalCoord.y >= VERTS_PER_Y_DIR do return 0
	if finalCoord.z < 0 || finalCoord.z >= VERTS_PER_Z_DIR do return 0

	index := index_into_point_arrays(finalCoord)
	return points[index]
}
get_or_create_mapper_idx :: proc "contextless" (
	mapper: []INDEX_TYPE_USED_IN_CHUNKS,
	worldCoord: [3]i32,
	idx: [3]i32,
	vertexArr: [][3]f32,
	vertexArrayLen: ^INDEX_TYPE_USED_IN_CHUNKS,
) -> INDEX_TYPE_USED_IN_CHUNKS {
	// assert(len(mapper) > 0)
	// assert(idx[0] >= 0 && idx[0] < VERTS_PER_X_DIR)
	// assert(idx[1] >= 0 && idx[1] < VERTS_PER_Y_DIR)
	// assert(idx[2] >= 0 && idx[2] < VERTS_PER_Z_DIR)
	// assert(len(vertexArr) > 0)
	// assert(vertexArrayLen != nil)

	#no_bounds_check {
		idxAsValue := index_into_point_arrays(idx)
		if mapper[idxAsValue] != INVALID do return mapper[idxAsValue]
		finalCoord := point_real_world_position(
			[3]f32{f32(worldCoord.x), f32(worldCoord.y), f32(worldCoord.z)},
		)
		vertexArr[vertexArrayLen^] = finalCoord
		mapper[idxAsValue] = vertexArrayLen^
		currIdx := vertexArrayLen^
		vertexArrayLen^ += 1
		return currIdx

	}

}
point_real_world_position :: #force_inline proc "contextless" (worldXYZ: [3]f32) -> [3]f32 {
	// return worldXYZ
	return worldXYZ + calculate_jitter(i32(worldXYZ.x), i32(worldXYZ.y), i32(worldXYZ.z), gs.seed)
}
calculate_jitter :: #force_inline proc "contextless" (x, y, z: i32, seed: u64) -> [3]f32 {
	h := u32(x) * 0x9e3779b9 + u32(y) * 0x85ebca6b + u32(z) * 0x27d4eb2d + u32(gs.seed)
	h = (h ~ (h >> 13)) * 0x9e3779b9
	fx := f32(h & 0xFFFF) * (1.0 / 65536.0) - 0.5
	fy := f32((h >> 16) & 0xFFFF) * (1.0 / 65536.0) - 0.5
	fz := f32((h >> 24) & 0xFF) * (1.0 / 256.0) - 0.5
	return {fx, fy, fz}
}


chunks_draw :: proc(
	cb: vk.CommandBuffer,
	p: ^vkh.PipelineData,
	CameraUBO: vk.Buffer,
	CameraUBOSize: vk.DeviceSize,
	currCamera: ^camera.Camera,
) {
	vk.CmdBindPipeline(cb, .GRAPHICS, p.graphicsPipeline)
	vk.CmdSetViewport(
		cb,
		0,
		1,
		&vk.Viewport {
			width = f32(gs.screenWidth),
			height = -f32(gs.screenHeight),
			minDepth = 0,
			maxDepth = 1,
			y = f32(gs.screenHeight),
			x = 0,
		},
	)
	vk.CmdSetScissor(
		cb,
		0,
		1,
		&vk.Rect2D{extent = {width = gs.screenWidth, height = gs.screenHeight}},
	)
	for x in 0 ..< len(Chunks) {
		for y in 0 ..< len(Chunks[0]) {

			chunk := &Chunks[x][y]
			// if chunk.pos != {0, 0} do continue
			if !is_chunk_in_camera_frustrum(chunk.pos, currCamera) do continue
			if chunk.totalIndices == 0 do continue


			assert(chunk.buffers.pointsBuffer[vkh.frameIndex].alloc != {})
			vertexBuffer := chunk.buffers.pointsBuffer[vkh.frameIndex].buffer
			vertexOffset := vk.DeviceSize(0)

			vk.CmdBindVertexBuffers(cb, 0, 1, &vertexBuffer, &vertexOffset)
			#assert(INDEX_TYPE_USED_IN_CHUNKS == u32)

			vk.CmdBindIndexBuffer(cb, chunk.buffers.indices[vkh.frameIndex].buffer, 0, .UINT32)


			cameraInfo := vk.DescriptorBufferInfo {
				buffer = vkh.cameraBuffers[vkh.frameIndex].buffer,
				offset = 0,
				range  = vkh.CameraUBOSize,
			}

			colorInfo := vk.DescriptorBufferInfo {
				buffer = chunk.buffers.colors[vkh.frameIndex].buffer,
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

	for i in 0 ..< vkh.MAX_FRAMES_IN_FLIGHT {
		if chunk.buffers.pointsBuffer[i].alloc != {} {
			vma.destroy_buffer(
				vkh.allocator,
				chunk.buffers.pointsBuffer[i].buffer,
				chunk.buffers.pointsBuffer[i].alloc,
			)
			chunk.buffers.pointsBuffer[i] = {}
		}
		if chunk.buffers.indices[i].alloc != {} {
			vma.destroy_buffer(
				vkh.allocator,
				chunk.buffers.indices[i].buffer,
				chunk.buffers.indices[i].alloc,
			)
			chunk.buffers.indices[i] = {}
		}
		if chunk.buffers.colors[i].alloc != {} {
			vma.destroy_buffer(
				vkh.allocator,
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
