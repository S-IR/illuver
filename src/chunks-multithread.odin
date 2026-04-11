package main
import "core:sync"
import "core:thread"
ChunkWorkerState :: struct {
	xIdx, zIdx:    int,
	pos:           [2]i32,
	visiblePoints: [MAX_POINTS][3]f32,
	indices:       [MAX_INDICES]INDEX_TYPE_USED_IN_CHUNKS,
	colors:        [MAX_COLORS][4]f32,
	vertexMapper:  [VERTS_PER_X_DIR * VERTS_PER_Y_DIR * VERTS_PER_Z_DIR]Maybe(INDEX_TYPE_USED_IN_CHUNKS),
	heightMap:     [VERTS_PER_X_DIR * VERTS_PER_Z_DIR]i32,
}
chunkWorkerStates: [dynamic]ChunkWorkerState
chunkWorkersWG: sync.Wait_Group


chunkWorkerThreads: [dynamic]^thread.Thread
ChunkJob :: struct {
	xIdx, zIdx: int,
	pos:        [2]i32,
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

		state.xIdx = job.xIdx
		state.zIdx = job.zIdx
		state.pos = job.pos
		chunk_init(state)
		sync.wait_group_done(&chunkWorkersWG)
	}
}

chunk_init_add_thread :: proc(xIdx, zIdx: int, pos: [2]i32) {
	job := ChunkJob{xIdx, zIdx, pos}
	sync.mutex_lock(&chunkJobMutex)
	append(&chunkJobQueue, job)
	sync.mutex_unlock(&chunkJobMutex)
	sync.wait_group_add(&chunkWorkersWG, 1)
	sync.sema_post(&chunkJobSema)
}
