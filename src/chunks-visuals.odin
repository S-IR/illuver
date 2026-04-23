package main
import "../modules/tracy"
import "../modules/vma"
import "algorithms"
import "camera"
import "core:container/lru"
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
import "core:path/filepath"
import "core:prof/spall"
import "core:simd"
import "core:sync"
import "core:thread"
import "core:time"
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

CHUNK_HEIGHTMAP_SIZE :: VERTS_PER_X_DIR * VERTS_PER_Z_DIR
NUM_WORKER_THREADS := 4
Chunk :: struct {
	points:            [VERTS_PER_X_DIR * VERTS_PER_Y_DIR * VERTS_PER_Z_DIR]u16,
	heightMap:         [CHUNK_HEIGHTMAP_SIZE]i32,
	buffers:           struct {
		vertices: [vkh.MAX_FRAMES_IN_FLIGHT]vkh.VkBufferPoolElem,
		// indices:      [vkh.MAX_FRAMES_IN_FLIGHT]vkh.VkBufferPoolElem,
		compute:  struct {
			pointsInput:     vkh.VkBufferPoolElem, // u16 input (uploaded when dirty)
			counter:         vkh.VkBufferPoolElem, // atomic counters (3x u32)
			uniform:         vkh.VkBufferPoolElem,
			stagingVertices: vkh.VkBufferPoolElem,
		},
	},
	copyTimelineValue: [vkh.MAX_FRAMES_IN_FLIGHT]u64,
	pos:               int2,
	pendingUpload:     [vkh.MAX_FRAMES_IN_FLIGHT]b32,
	mutex:             sync.Mutex,
	totalPoints:       u32,
	arena:             virtual.Arena,
	alloc:             mem.Allocator,
	dirty:             bool,
}


// chunk_point_get :: proc(c: ^Chunk, x, y, z: i32) -> PointType {
// 	return c.points[x * CUBES_PER_Y_DIR * CUBES_PER_Z_DIR + y * CUBES_PER_Z_DIR + z]
// }

CHUNKS_PER_DIRECTION :: 5

ENERGY_TICKING_DIRECTION_LEN :: CHUNKS_PER_DIRECTION
RenderedChunks := [CHUNKS_PER_DIRECTION][CHUNKS_PER_DIRECTION]Chunk{}


ChunkPrevEnergyCache: [dynamic]u16
CHUNK_MIDDLE_X_INDEX :: (CHUNKS_PER_DIRECTION / 2)
CHUNK_MIDDLE_Z_INDEX :: (CHUNKS_PER_DIRECTION / 2)

ChunkAtTheCenter := int2{}

WorldArena := vmem.Arena{}
WorldAllocator := mem.Allocator{}

chunks_init :: proc(c: ^camera.Camera) {
	chunkShutdown = false
	centerChunk := int2{i32(c.pos.x), i32(c.pos.z)} / CHUNK_SIZE
	half :: CHUNKS_PER_DIRECTION / 2


	err := vmem.arena_init_growing(&WorldArena)
	ensure(err == nil)
	WorldAllocator = vmem.arena_allocator(&WorldArena)

	chunkJobQueue = make([dynamic]ChunkJob, WorldAllocator)
	chunkWorkerStates = make([dynamic]ChunkWorkerState, gs.NUM_CORES - 1, WorldAllocator)
	chunkWorkerThreads = make([dynamic]^thread.Thread, gs.NUM_CORES - 1, WorldAllocator)
	lru.init(&IRRFCache, MAX_IRRFS_IN_MEMORY, WorldAllocator, WorldAllocator)
	IRRFCache.on_remove = irrf_cache_on_remove

	for i in 0 ..< gs.NUM_CORES - 1 {

		vkh.chk(
			vk.CreateCommandPool(
				vkh.device,
				&{
					sType = .COMMAND_POOL_CREATE_INFO,
					flags = {.RESET_COMMAND_BUFFER},
					queueFamilyIndex = vkh.computeQueueFamilyIndex,
				},
				nil,
				&chunkWorkerStates[i].computeCommandPool,
			),
		)


		vkh.chk(
			vk.AllocateCommandBuffers(
				vkh.device,
				&vk.CommandBufferAllocateInfo {
					sType = .COMMAND_BUFFER_ALLOCATE_INFO,
					commandPool = chunkWorkerStates[i].computeCommandPool,
					level = .PRIMARY,
					commandBufferCount = 1,
				},
				&chunkWorkerStates[i].computeCB,
			),
		)

		vk.CreateFence(
			vkh.device,
			&vk.FenceCreateInfo{sType = .FENCE_CREATE_INFO, flags = {.SIGNALED}},
			nil,
			&chunkWorkerStates[i].computeFence,
		)


	}
	for i in 0 ..< gs.NUM_CORES - 1 {
		idx := new(int, WorldAllocator)
		idx^ = i
		t := thread.create(chunk_worker_thread)
		t.data = idx
		chunkWorkerThreads[i] = t
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

	ChunkAtTheCenter = RenderedChunks[CHUNK_MIDDLE_X_INDEX][CHUNK_MIDDLE_Z_INDEX].pos

	ChunkPrevEnergyCache = make(
		[dynamic]u16,
		ENERGY_TICKING_DIRECTION_LEN * ENERGY_TICKING_DIRECTION_LEN * MAX_POINTS,
		WorldAllocator,
	)

}

energy_tick :: proc(energyTickType: bit_set[EnergyType]) {


	mem.zero(raw_data(ChunkPrevEnergyCache), size_of(ChunkPrevEnergyCache))
	for &chunkRow, x in RenderedChunks {
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

	for &chunkRow, x in RenderedChunks {
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
CHUNK_GPU_VERTEX_BUFFER_SIZE :: MAX_POINTS * size_of([4]f32) * 3

when VISUAL_REPRESENTATION_OF_NOISE_FN_RUN {
	render_chunk_init :: VISUAL_REPRESENTATION_OF_NOISE_FN_RUN_chunk_init

	VISUAL_REPRESENTATION_OF_NOISE_FN_RUN_chunk_init :: proc(
		xIdx, zIdx: int,
		pos: int2,
		state: ChunkWorkerState,
	) {
		chunk := &RenderedChunks[xIdx][zIdx]
		for i in 0 ..< vkh.MAX_FRAMES_IN_FLIGHT {
			if chunk.buffers.vertices[i].alloc != {} do continue
			assert(chunk.buffers.indices[i].buffer == {})
			assert(chunk.buffers.colors[i].buffer == {})

			vkh.chk(
				vma.create_buffer(
					vkh.allocator,
					{
						sType = .BUFFER_CREATE_INFO,
						size = vk.DeviceSize(3 * MAX_POINTS * size_of([3]f32)),
						usage = {.VERTEX_BUFFER},
					},
					{flags = {.Host_Access_Sequential_Write, .Mapped}, usage = .Auto},
					&chunk.buffers.vertices[i].buffer,
					&chunk.buffers.vertices[i].alloc,
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
			assert(chunk.buffers.vertices[i].alloc != {})
			assert(chunk.buffers.indices[i].alloc != {})
			assert(chunk.buffers.colors[i].alloc != {})


			vertBufferPtr: rawptr
			vkh.chk(vma.map_memory(vkh.allocator, chunk.buffers.vertices[i].alloc, &vertBufferPtr))
			mem.copy(
				vertBufferPtr,
				raw_data(staticVisiblePoints[0:staticVisiblePointsLen]),
				staticVisiblePointsLen * size_of(staticVisiblePoints[0]),
			)
			vma.unmap_memory(vkh.allocator, chunk.buffers.vertices[i].alloc)

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
		chunk := &RenderedChunks[state.xIdx][state.zIdx]
		chunk.pos = pos

		assert(chunk.pos[0] % CHUNK_STRIDE == 0)
		assert(chunk.pos[1] % CHUNK_STRIDE == 0)

		{
			tracy.Zone()
			for i in 0 ..< vkh.MAX_FRAMES_IN_FLIGHT {
				if chunk.buffers.vertices[i].buffer != {} do continue

				vkh.chk(
					vma.create_buffer(
						vkh.allocator,
						{
							sType = .BUFFER_CREATE_INFO,
							size = vk.DeviceSize(CHUNK_GPU_VERTEX_BUFFER_SIZE),
							usage = {.VERTEX_BUFFER, .TRANSFER_DST},
						},
						{
							flags = {.Host_Access_Sequential_Write, .Mapped},
							required_flags = {.HOST_VISIBLE},
							usage = .Auto,
						},
						&chunk.buffers.vertices[i].buffer,
						&chunk.buffers.vertices[i].alloc,
						nil,
					),
				)


			}
		}
		chunk_geometry_calc_buffers_create(chunk)

		if chunk.alloc == {} {
			chunk.alloc = virtual.arena_allocator(&chunk.arena)
		} else {
			free_all(chunk.alloc)
		}


		gottenDataFromIrrf :=
			false when DEBUG_MODE_IGNORE_SAVE else irrf_get_chunk(
				pos,
				&chunk.points,
				&chunk.heightMap,
			)


		// chunkXSimd := #simd[4]f64{posXF64, posXF64, posXF64, posXF64}
		// chunkZSimd := #simd[4]f64{posZF64, posZF64, posZF64, posZF64}

		// isCrystalblooomArr := [VERTS_PER_X_DIR * VERTS_PER_Z_DIR]bool{}
		if !gottenDataFromIrrf {
			defer irrf_set_chunk(chunk.pos, &chunk.points, &chunk.heightMap)
			tracy.Zone()

			posXF64 := f64(pos[0])
			posZF64 := f64(pos[1])
			chunkXYZ := float3{f32(pos[0]), 0, f32(pos[1])}
			chunkXYZI32 := [3]i32{i32(pos[0]), 0, i32(pos[1])}

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
		chunk_create_gpu_geometry(chunk, state, vkh.frameIndex)

	}
	U32_INVALID :: u32(0xFFFFFFFF)

	chunk_create_gpu_geometry :: proc(chunk: ^Chunk, state: ^ChunkWorkerState, frameIndex: u32) {
		tracy.Zone()
		chunk_geometry_calculate(chunk, state, chunkGeometryCalcPipeline)
		chunk_copy_current_to_other_frames(chunk, state, frameIndex)

	}

}


// geometry_process_vertex :: proc "contextless" (
// 	mapper: []INDEX_TYPE_USED_IN_CHUNKS,
// 	worldBase: [3]i32,
// 	base: [3]i32,
// 	offset: [3]i32,
// 	vertexArr: [][3]f32,
// 	vertexArrayLen: ^INDEX_TYPE_USED_IN_CHUNKS,
// 	seed: u64,
// ) -> INDEX_TYPE_USED_IN_CHUNKS {
// 	#no_bounds_check {
// 		idxVal :=
// 			(base.x + offset.x) * VERT_STRIDE_X +
// 			(base.y + offset.y) * VERT_STRIDE_Y +
// 			(base.z + offset.z)
// 		if mapper[idxVal] != U32_INVALID {
// 			return mapper[idxVal]
// 		}
// 		wx := worldBase.x + offset.x
// 		wy := worldBase.y + offset.y
// 		wz := worldBase.z + offset.z

// 		vertexArr[vertexArrayLen^] = point_real_world_position({f32(wx), f32(wy), f32(wz)})
// 		mapper[idxVal] = vertexArrayLen^
// 		curr := vertexArrayLen^
// 		vertexArrayLen^ += 1
// 		return curr
// 	}

// }
// get_point_type :: #force_inline proc "contextless" (
// 	base: [3]i32,
// 	offset: [3]i32,
// 	points: []u16,
// ) -> u16 {
// 	finalCoord := base + offset

// 	if finalCoord.x < 0 || finalCoord.x >= VERTS_PER_X_DIR do return 0
// 	if finalCoord.y < 0 || finalCoord.y >= VERTS_PER_Y_DIR do return 0
// 	if finalCoord.z < 0 || finalCoord.z >= VERTS_PER_Z_DIR do return 0

// 	index := index_into_point_arrays(finalCoord)
// 	#no_bounds_check {
// 		return points[index]
// 	}
// }

// get_offset_point_type_bounds_checked :: proc(base: [3]i32, offset: [3]i32, points: []u16) -> u16 {
// 	finalCoord := base + offset

// 	if finalCoord.x < 0 || finalCoord.x >= VERTS_PER_X_DIR do return 0
// 	if finalCoord.y < 0 || finalCoord.y >= VERTS_PER_Y_DIR do return 0
// 	if finalCoord.z < 0 || finalCoord.z >= VERTS_PER_Z_DIR do return 0

// 	index := index_into_point_arrays(finalCoord)
// 	return points[index]
// }
// get_or_create_mapper_idx :: proc "contextless" (
// 	mapper: []INDEX_TYPE_USED_IN_CHUNKS,
// 	worldCoord: [3]i32,
// 	idx: [3]i32,
// 	vertexArr: [][3]f32,
// 	vertexArrayLen: ^INDEX_TYPE_USED_IN_CHUNKS,
// ) -> INDEX_TYPE_USED_IN_CHUNKS {
// 	// assert(len(mapper) > 0)
// 	// assert(idx[0] >= 0 && idx[0] < VERTS_PER_X_DIR)
// 	// assert(idx[1] >= 0 && idx[1] < VERTS_PER_Y_DIR)
// 	// assert(idx[2] >= 0 && idx[2] < VERTS_PER_Z_DIR)
// 	// assert(len(vertexArr) > 0)
// 	// assert(vertexArrayLen != nil)

// 	#no_bounds_check {
// 		idxAsValue := index_into_point_arrays(idx)
// 		if mapper[idxAsValue] != U32_INVALID do return mapper[idxAsValue]
// 		finalCoord := point_real_world_position(
// 			[3]f32{f32(worldCoord.x), f32(worldCoord.y), f32(worldCoord.z)},
// 		)
// 		vertexArr[vertexArrayLen^] = finalCoord
// 		mapper[idxAsValue] = vertexArrayLen^
// 		currIdx := vertexArrayLen^
// 		vertexArrayLen^ += 1
// 		return currIdx

// 	}

// }
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
	return {fx, fy, fz} / 2
}

chunks_draw :: proc(
	cb: vk.CommandBuffer,
	triPipeline: ^vkh.PipelineData,
	pointPipeline: ^vkh.PipelineData,
	currCamera: ^camera.Camera,
) {
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

	for x in 0 ..< len(RenderedChunks) {
		for y in 0 ..< len(RenderedChunks[0]) {
			chunk := &RenderedChunks[x][y]
			if !is_chunk_in_camera_frustrum(chunk.pos, currCamera) do continue

			if chunk.copyTimelineValue[vkh.frameIndex] != 0 {
				waitInfo := vk.SemaphoreWaitInfo {
					sType          = .SEMAPHORE_WAIT_INFO,
					semaphoreCount = 1,
					pSemaphores    = &vkh.copyTimelineSemaphore,
					pValues        = &chunk.copyTimelineValue[vkh.frameIndex],
				}
				vk.WaitSemaphores(vkh.device, &waitInfo, max(u64))
				chunk.copyTimelineValue[vkh.frameIndex] = 0
			}

			vertexBuffer := chunk.buffers.vertices[vkh.frameIndex].buffer
			vertexOffset := vk.DeviceSize(0)
			vk.CmdBindVertexBuffers(cb, 0, 1, &vertexBuffer, &vertexOffset)

			cameraInfo := vk.DescriptorBufferInfo {
				buffer = vkh.cameraBuffers[vkh.frameIndex].buffer,
				offset = 0,
				range  = vkh.CameraUBOSize,
			}

			writes := [?]vk.WriteDescriptorSet {
				{
					sType = .WRITE_DESCRIPTOR_SET,
					dstBinding = 0,
					descriptorCount = 1,
					descriptorType = .UNIFORM_BUFFER,
					pBufferInfo = &cameraInfo,
				},
			}

			vk.CmdBindPipeline(cb, .GRAPHICS, triPipeline.pipeline)
			vk.CmdPushDescriptorSetKHR(
				cb,
				.GRAPHICS,
				triPipeline.layout,
				0,
				len(writes),
				raw_data(writes[:]),
			)

			pushTri := u32(0)
			vk.CmdPushConstants(
				cb,
				triPipeline.layout,
				{.VERTEX, .FRAGMENT},
				0,
				size_of(u32),
				&pushTri,
			)
			vk.CmdDraw(cb, chunk.totalPoints, 1, 0, 0)

			vk.CmdBindPipeline(cb, .GRAPHICS, pointPipeline.pipeline)
			vk.CmdPushDescriptorSetKHR(
				cb,
				.GRAPHICS,
				pointPipeline.layout,
				0,
				len(writes),
				raw_data(writes[:]),
			)

			pushPoint := u32(1)
			vk.CmdPushConstants(
				cb,
				pointPipeline.layout,
				{.VERTEX, .FRAGMENT},
				0,
				size_of(u32),
				&pushPoint,
			)
			vk.CmdDraw(cb, chunk.totalPoints, 1, 0, 0)
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

	for &chunkX in RenderedChunks {
		for &chunk in chunkX {
			chunk_destroy(&chunk)
		}
	}

	for &workerState in chunkWorkerStates {
		if workerState.computeCommandPool != {} {
			if workerState.computeCB != {} {
				vk.FreeCommandBuffers(
					vkh.device,
					workerState.computeCommandPool,
					1,
					&workerState.computeCB,
				)
			}
			vk.DestroyCommandPool(vkh.device, workerState.computeCommandPool, nil)
		}

		if workerState.computeFence != {} {
			vk.WaitForFences(vkh.device, 1, &workerState.computeFence, true, max(u64))
			vk.DestroyFence(vkh.device, workerState.computeFence, nil)
		}


	}
	vmem.arena_destroy(&WorldArena)


}
chunk_destroy :: proc(chunk: ^Chunk) {
	assert(chunk != nil)

	for i in 0 ..< vkh.MAX_FRAMES_IN_FLIGHT {
		if chunk.buffers.vertices[i].alloc != {} {
			vma.destroy_buffer(
				vkh.allocator,
				chunk.buffers.vertices[i].buffer,
				chunk.buffers.vertices[i].alloc,
			)
			chunk.buffers.vertices[i] = {}
		}


	}
	chunk_geometry_calc_buffers_destroy(chunk)

	chunk.buffers = {}

	free_all(chunk.alloc)
	chunk.pos = {0, 0}
	chunk.totalPoints = 0
}
