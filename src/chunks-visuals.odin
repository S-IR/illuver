package main
import "../modules/tracy"
import "../modules/vma"
import "algorithms"
import "camera"
import "core:container/lru"
import "core:container/pool"
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


chunksPool: [dynamic]Chunk = nil
renderedChunks: [dynamic]^Chunk = nil
rc_idx :: #force_inline proc "contextless" (x, z: int) -> int {
	return x * CHUNKS_PER_DIRECTION + z
}
rc :: #force_inline proc "contextless" (x, z: int) -> ^Chunk {
	return renderedChunks[x * CHUNKS_PER_DIRECTION + z]
}
rc_set :: #force_inline proc "contextless" (x, z: int, c: ^Chunk) {
	renderedChunks[x * CHUNKS_PER_DIRECTION + z] = c
}

// ChunkPrevEnergyCache: [dynamic]u16
// CHUNK_MIDDLE_X_INDEX :: (CHUNKS_PER_DIRECTION / 2)
// CHUNK_MIDDLE_Z_INDEX :: (CHUNKS_PER_DIRECTION / 2)

// ChunkAtTheCenter := int2{}

WorldArena := vmem.Arena{}
WorldAllocator := mem.Allocator{}

chunks_init :: proc(c: ^camera.Camera) {
	chunkShutdown = false
	centerChunk := int2 {
		i32(math.floor(c.pos.x / f32(CHUNK_STRIDE))),
		i32(math.floor(c.pos.z / f32(CHUNK_STRIDE))),
	}
	half := CHUNKS_PER_DIRECTION / 2


	err := vmem.arena_init_growing(&WorldArena)
	ensure(err == nil)
	WorldAllocator = vmem.arena_allocator(&WorldArena)

	total := CHUNKS_PER_DIRECTION * CHUNKS_PER_DIRECTION
	chunksPool = make([dynamic]Chunk, total, WorldAllocator)
	renderedChunks = make([dynamic]^Chunk, total, WorldAllocator)
	for x in 0 ..< CHUNKS_PER_DIRECTION {
		for z in 0 ..< CHUNKS_PER_DIRECTION {
			rc_set(x, z, &chunksPool[x * CHUNKS_PER_DIRECTION + z])
		}
	}


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
			chunk_init_add_thread(rc(x, z), pos)

		}
	}
	sync.wait(&chunkWorkersWG)

	// ChunkAtTheCenter = rc(half, half).pos

	// ChunkPrevEnergyCache = make(
	// 	[dynamic]u16,
	// 	ENERGY_TICKING_DIRECTION_LEN * ENERGY_TICKING_DIRECTION_LEN * MAX_POINTS,
	// 	WorldAllocator,
	// )

}

// energy_tick :: proc(energyTickType: bit_set[EnergyType]) {


// 	mem.zero(raw_data(ChunkPrevEnergyCache), size_of(ChunkPrevEnergyCache))
// 	for &chunkRow, x in RenderedChunks {
// 		for &chunk, z in chunkRow {
// 			start := index_into_energy_cache(x, z)
// 			// ensure((start + int(MAX_POINTS)) < len(ChunkPrevEnergyCache))
// 			assert(start >= 0)
// 			assert(int(start) + len(chunk.points) <= len(ChunkPrevEnergyCache))

// 			ptrStart := mem.ptr_offset(raw_data(ChunkPrevEnergyCache), start)
// 			mem.copy(
// 				ptrStart,
// 				raw_data(chunk.points[:]),
// 				len(chunk.points) * size_of(chunk.points[0]),
// 			)

// 			// ChunkPrevEnergyCache[start:start + MAX_POINTS] = chunk.points
// 			// ChunkPrevEnergyCache[x * CHUNKS_PER_DIRECTION + z * MAX_POINTS]
// 		}
// 	}

// 	for &chunkRow, x in RenderedChunks {
// 		for &chunk, z in chunkRow {
// 			chunk_energy_tick_add_thread(x, z, energyTickType)
// 		}
// 	}
// }


chunk_init :: proc(chunk: ^Chunk, pos: [2]i32, state: ^ChunkWorkerState) {

	tracy.Zone()
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
	// Preserve fields that must survive re-init: GPU buffers (still owned by chunk),
	// the arena (already free_all'd above), the allocator handle, and the mutex
	// which the worker thread currently holds (zeroing it would invalidate the
	// lock held by the caller in chunk-worker_thread).
	chunkBuffers := chunk.buffers
	savedArena := chunk.arena
	savedAlloc := chunk.alloc
	savedMutex := chunk.mutex
	chunk^ = {}
	chunk.buffers = chunkBuffers
	chunk.arena = savedArena
	chunk.alloc = savedAlloc
	chunk.mutex = savedMutex
	chunk.pos = pos


	gottenDataFromIrrf :=
		false when DEBUG_MODE_IGNORE_SAVE else irrf_get_chunk(pos, &chunk.points, &chunk.heightMap)


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
					procedural_point_type(
						&chunk.points,
						&chunk.heightMap,
						biomeWeights,
						worldXYZ,
						{x, y, z},
						height,
						gs.seed,
					)
					assert(is_valid_point_u16(chunk.points[index_into_point_arrays(x, y, z)]))
					// chunk.points[idx] = pointVal

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
local_index_to_world_pos :: proc(chunkXZ: [2]i32, idx: [3]i32) -> [3]f32 {
	return point_real_world_position([3]i32{chunkXZ[0], MIN_Y, chunkXZ[1]} + idx)
}
point_real_world_position_f32 :: #force_inline proc "contextless" (worldXYZ: [3]f32) -> [3]f32 {
	// return worldXYZ
	return worldXYZ + calculate_jitter(i32(worldXYZ.x), i32(worldXYZ.y), i32(worldXYZ.z), gs.seed)
}
point_real_world_position_i32 :: #force_inline proc "contextless" (worldXYZ: [3]i32) -> [3]f32 {
	return(
		[3]f32{f32(worldXYZ.x), f32(worldXYZ.y), f32(worldXYZ.z)} +
		calculate_jitter(worldXYZ.x, worldXYZ.y, worldXYZ.z, gs.seed) \
	)

}
point_real_world_position :: proc {
	point_real_world_position_i32,
	point_real_world_position_f32,
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
	triPipeline: vkh.PipelineData,
	pointPipeline: vkh.PipelineData,
	currCamera: camera.Camera,
	sunUBOBuffer: vk.Buffer,
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

	for chunk in renderedChunks {
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


		writes := [?]vk.WriteDescriptorSet {
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstBinding = 0,
				descriptorCount = 1,
				descriptorType = .UNIFORM_BUFFER,
				pBufferInfo = &{
					buffer = vkh.cameraBuffers[vkh.frameIndex].buffer,
					offset = 0,
					range = vkh.CameraUBOSize,
				},
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstBinding = 1,
				descriptorCount = 1,
				descriptorType = .UNIFORM_BUFFER,
				pBufferInfo = &{
					buffer = sunUBOBuffer,
					offset = 0,
					range = vk.DeviceSize(size_of(SunUBO)),
				},
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

chunks_destroy :: proc() {
	chunkShutdown = true
	for _ in chunkWorkerThreads {
		sync.sema_post(&chunkJobSema)
	}

	for t in chunkWorkerThreads {
		thread.join(t)
		thread.destroy(t)
	}

	for &chunk in renderedChunks do chunk_destroy(chunk)


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
