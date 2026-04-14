package main
import "core:fmt"
import "core:sync"
import "core:thread"
ChunkWorkerState :: struct {
	vertexMapper:  [MAX_POINTS]Maybe(INDEX_TYPE_USED_IN_CHUNKS),
	visiblePoints: [MAX_POINTS][3]f32,
	colors:        [MAX_COLORS][4]f32,
	indices:       [MAX_INDICES]INDEX_TYPE_USED_IN_CHUNKS,
	xIdx, zIdx:    int,
	pos:           [2]i32,
}
chunkWorkerStates: [dynamic]ChunkWorkerState
chunkWorkersWG: sync.Wait_Group


chunkWorkerThreads: [dynamic]^thread.Thread

ChunkJobType :: enum {
	Init,
	Update,
	PointEdit,
}

ChunkJob :: struct {
	xIdx, zIdx: int,
	pos:        [2]i32,
	type:       ChunkJobType,
	edit:       struct {
		x, y, z:      i32,
		newPointType: PointType,
	},
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

		chunk := &Chunks[state.xIdx][state.zIdx]
		jobTypeStr, _ := fmt.enum_value_to_string(job.type)
		switch job.type {
		case .Init:
			chunk_init(state)
		case .Update:
			state.vertexMapper = {}
			chunk_create_gpu_geometry(chunk, state)
		case .PointEdit:
			chunk.points[index_into_point_arrays(job.edit.x, job.edit.y, job.edit.z)] =
				job.edit.newPointType

			heightMapIdx := job.edit.x * VERTS_PER_Z_DIR + job.edit.z
			if job.edit.newPointType == .Air {
				if chunk.heightMap[heightMapIdx] == job.edit.y + MIN_Y {
					currY := job.edit.y - 1
					for currY > 0 &&
					    chunk.points[index_into_point_arrays(job.edit.x, currY, job.edit.z)] ==
						    .Air {
						currY -= 1
					}
					chunk.heightMap[heightMapIdx] = currY + MIN_Y
				}
			} else {
				if job.edit.y + MIN_Y > chunk.heightMap[heightMapIdx] {
					chunk.heightMap[heightMapIdx] = job.edit.y + MIN_Y
				}
			}
			state.vertexMapper = {}
			chunk_create_gpu_geometry(chunk, state)
		}

		sync.wait_group_done(&chunkWorkersWG)
	}
}

chunk_init_add_thread :: proc(xIdx, zIdx: int, pos: [2]i32) {
	job := ChunkJob {
		xIdx = xIdx,
		zIdx = zIdx,
		pos  = pos,
	}
	sync.mutex_lock(&chunkJobMutex)
	append(&chunkJobQueue, job)
	sync.mutex_unlock(&chunkJobMutex)
	sync.wait_group_add(&chunkWorkersWG, 1)
	sync.sema_post(&chunkJobSema)
}
chunk_update_add_thread :: proc(xIdx, zIdx: int) {
	pos := Chunks[xIdx][zIdx].pos

	job := ChunkJob {
		xIdx = xIdx,
		zIdx = zIdx,
		pos  = Chunks[xIdx][zIdx].pos,
		type = .Update,
	}
	sync.mutex_lock(&chunkJobMutex)
	append(&chunkJobQueue, job)
	sync.mutex_unlock(&chunkJobMutex)
	sync.wait_group_add(&chunkWorkersWG, 1)
	sync.sema_post(&chunkJobSema)

}
chunk_point_edit_add_thread :: proc(
	xIdx, zIdx: int,
	indexX, indexY, indexZ: i32,
	newType: PointType,
) {
	job := ChunkJob {
		xIdx = xIdx,
		zIdx = zIdx,
		pos = Chunks[xIdx][zIdx].pos,
		type = .PointEdit,
		edit = {x = indexX, y = indexY, z = indexZ, newPointType = newType},
	}
	sync.mutex_lock(&chunkJobMutex)
	append(&chunkJobQueue, job)
	sync.mutex_unlock(&chunkJobMutex)
	sync.wait_group_add(&chunkWorkersWG, 1)
	sync.sema_post(&chunkJobSema)
}
