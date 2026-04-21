
package main
import "../modules/tracy"
import "base:intrinsics"
import "core:fmt"
import "core:math"
import "core:simd"
import "core:sync"
import "core:thread"
ChunkWorkerState :: struct {
	vertexMapper:  [MAX_POINTS]INDEX_TYPE_USED_IN_CHUNKS,
	visiblePoints: [MAX_POINTS][3]f32,
	colors:        [MAX_COLORS][4]f32,
	indices:       [MAX_INDICES]INDEX_TYPE_USED_IN_CHUNKS,
	xIdx, zIdx:    int,
	pos:           [2]i32,
}
chunkWorkerStates: [dynamic]ChunkWorkerState
chunkWorkersWG: sync.Wait_Group


chunkWorkerThreads: [dynamic]^thread.Thread


EditUpdateJob :: struct {
	x, y, z:      i32,
	newPointType: u16,
}
EnergyTickJob :: struct {
	chunkX, chunkZ: int,
	energyTickType: bit_set[EnergyType],
}
UpdateJob :: struct {}
InitJob :: struct {}

ChunkJobType :: union {
	EditUpdateJob,
	UpdateJob,
	InitJob,
	EnergyTickJob,
}
ChunkJob :: struct {
	xIdx, zIdx: int,
	pos:        [2]i32,
	type:       ChunkJobType,
}

chunkJobQueue: [dynamic]ChunkJob
chunkJobMutex: sync.Mutex
chunkJobSema: sync.Sema
chunkShutdown: b32
chunk_worker_thread :: proc(t: ^thread.Thread) {
	workerIdx := ((^int)(t.data))^
	state := &chunkWorkerStates[workerIdx]
	for {
		sync.sema_wait(&chunkJobSema)
		if chunkShutdown do break
		sync.mutex_lock(&chunkJobMutex)
		if len(chunkJobQueue) == 0 {
			sync.mutex_unlock(&chunkJobMutex)
			continue
		}
		job := chunkJobQueue[0]
		ordered_remove(&chunkJobQueue, 0)
		sync.mutex_unlock(&chunkJobMutex)

		state^ = {}
		state.xIdx = job.xIdx
		state.zIdx = job.zIdx
		state.pos = job.pos

		chunk := &RenderedChunks[state.xIdx][state.zIdx]
		jobTypeStr, _ := fmt.enum_value_to_string(job.type)
		sync.mutex_lock(&chunk.mutex)

		switch v in job.type {
		case EnergyTickJob:
			tracy.Zone()
			startX: i32 = 0
			endX := i32(VERTS_PER_X_DIR)
			startZ: i32 = 0
			endZ := i32(VERTS_PER_Z_DIR)

			startY := i32(MIN_Y + 1)
			for x in startX ..< endX {
				for z in startZ ..< endZ {
					endY := math.min(chunk.heightMap[x * VERTS_PER_Z_DIR + z], MAX_Y)
					energyTickIteration: for yHeight in startY ..< endY {
						y := i32(yHeight - MIN_Y)
						baseIdx := index_into_point_arrays([3]i32{x, y, z})

						point, isWorldEdge := energy_cache_get(state.xIdx, state.zIdx, x, y, z)
						if isWorldEdge do continue energyTickIteration

						neighbors: [6]u16
						neighbors[0], _ = energy_cache_get(state.xIdx, state.zIdx, x - 1, y, z) // left
						neighbors[1], _ = energy_cache_get(state.xIdx, state.zIdx, x + 1, y, z) // right
						neighbors[2], _ = energy_cache_get(state.xIdx, state.zIdx, x, y - 1, z) // down
						neighbors[3], _ = energy_cache_get(state.xIdx, state.zIdx, x, y + 1, z) // up
						neighbors[4], _ = energy_cache_get(state.xIdx, state.zIdx, x, y, z - 1) // back
						neighbors[5], _ = energy_cache_get(state.xIdx, state.zIdx, x, y, z + 1) // front

						chunk.points[baseIdx] = point_tick_energy(
							point,
							neighbors,
							v.energyTickType,
						)
					}
				}
			}

			chunk_create_gpu_geometry(chunk, state)
		case InitJob:
			chunk_init(state)
		case UpdateJob:
			chunk_create_gpu_geometry(chunk, state)
		case EditUpdateJob:
			chunk.points[index_into_point_arrays(v.x, v.y, v.z)] = v.newPointType

			heightMapIdx := v.x * VERTS_PER_Z_DIR + v.z
			if u16_to_point_type(v.newPointType) == .Air {
				if chunk.heightMap[heightMapIdx] == v.y + MIN_Y {
					currY := v.y - 1
					for currY > 0 &&
					    u16_to_point_type(
						    chunk.points[index_into_point_arrays(v.x, currY, v.z)],
					    ) ==
						    .Air {
						currY -= 1
					}
					chunk.heightMap[heightMapIdx] = currY + MIN_Y
				}
			} else {
				if v.y + MIN_Y > chunk.heightMap[heightMapIdx] {
					chunk.heightMap[heightMapIdx] = v.y + MIN_Y
				}
			}
			irrf_set_chunk(chunk.pos, &chunk.points, &chunk.heightMap)
			chunk_create_gpu_geometry(chunk, state)
		}
		sync.mutex_unlock(&chunk.mutex)
		sync.wait_group_done(&chunkWorkersWG)
	}
}
index_into_energy_cache :: #force_inline proc "contextless" (x, z: int) -> i32 {

	chunkIndexIntoEnergyCacheInt := (x * ENERGY_TICKING_DIRECTION_LEN + z) * MAX_POINTS_INT


	// when ODIN_DEBUG {
	// 	a, of1 := intrinsics.overflow_mul(x, ENERGY_TICKING_DIRECTION_LEN)
	// 	b, of2 := intrinsics.overflow_mul(a, MAX_POINTS_INT)
	// 	c, of3 := intrinsics.overflow_mul(z, MAX_POINTS_INT)
	// 	res, of4 := intrinsics.overflow_add(b, c)

	// 	assert(!of1 && !of2 && !of3 && !of4)
	// 	assert(chunkIndexIntoEnergyCacheInt < int(max(i32)))

	// 	// assert(res >= 0)
	// }

	chunkIndexIntoEnergyCache := i32(chunkIndexIntoEnergyCacheInt)


	return chunkIndexIntoEnergyCache
}
// Wraps ChunkPrevEnergyCache access, handling cross-chunk boundaries transparently.
// chunkX, chunkZ: the "home" chunk indices
// localX, localY, localZ: point coords relative to home chunk (can be -1 or VERTS_PER_X_DIR etc.)
// returns (value, ok) - ok=false means it's a world edge, treat as 0 or skip
energy_cache_get :: #force_inline proc "contextless" (
	chunkX, chunkZ: int,
	localX, localY, localZ: i32,
) -> (
	res: u16,
	isWorldEdge: bool,
) {
	cx := chunkX
	lx := localX
	cz := chunkZ
	lz := localZ

	if lx < 0 {
		cx -= 1
		lx = VERTS_PER_X_DIR - 1 + lx + 1
		if cx < 0 do return 0, true
	} else if lx >= VERTS_PER_X_DIR {
		cx += 1
		lx = lx - VERTS_PER_X_DIR
		if cx >= ENERGY_TICKING_DIRECTION_LEN do return 0, true
	}

	// Handle Z overflow
	if lz < 0 {
		cz -= 1
		lz = VERTS_PER_Z_DIR - 1 + lz + 1
		if cz < 0 do return 0, true
	} else if lz >= VERTS_PER_Z_DIR {
		cz += 1
		lz = lz - VERTS_PER_Z_DIR
		if cz >= ENERGY_TICKING_DIRECTION_LEN do return 0, true
	}

	baseChunk := index_into_energy_cache(cx, cz)
	idx := baseChunk + index_into_point_arrays([3]i32{lx, localY, lz})
	return ChunkPrevEnergyCache[idx], false
}
chunk_init_add_thread :: proc(xIdx, zIdx: int, pos: [2]i32) {
	job := ChunkJob {
		xIdx = xIdx,
		zIdx = zIdx,
		pos  = pos,
		type = InitJob{},
	}
	sync.mutex_lock(&chunkJobMutex)
	append(&chunkJobQueue, job)
	sync.mutex_unlock(&chunkJobMutex)
	sync.wait_group_add(&chunkWorkersWG, 1)
	sync.sema_post(&chunkJobSema)
}
chunk_update_add_thread :: proc(xIdx, zIdx: int) {
	pos := RenderedChunks[xIdx][zIdx].pos

	job := ChunkJob {
		xIdx = xIdx,
		zIdx = zIdx,
		pos  = RenderedChunks[xIdx][zIdx].pos,
		type = UpdateJob{},
	}
	chunk_send_job(job)

}

chunk_point_edit_add_thread :: proc(xIdx, zIdx: int, indexX, indexY, indexZ: i32, newType: u16) {
	job := ChunkJob {
		xIdx = xIdx,
		zIdx = zIdx,
		pos = RenderedChunks[xIdx][zIdx].pos,
		type = EditUpdateJob{x = indexX, y = indexY, z = indexZ, newPointType = newType},
	}
	chunk_send_job(job)

}
chunk_energy_tick_add_thread :: proc(xIdx, zIdx: int, energyTickType: bit_set[EnergyType]) {
	job := ChunkJob {
		xIdx = xIdx,
		zIdx = zIdx,
		pos = RenderedChunks[xIdx][zIdx].pos,
		type = EnergyTickJob{energyTickType = energyTickType},
	}

	chunk_send_job(job)

}
chunk_send_job :: proc(job: ChunkJob) {
	sync.mutex_lock(&chunkJobMutex)
	append(&chunkJobQueue, job)
	sync.mutex_unlock(&chunkJobMutex)
	sync.wait_group_add(&chunkWorkersWG, 1)
	sync.sema_post(&chunkJobSema)
}
