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

chunk_set_point :: proc(worldPos: [3]f32, newType: u16) -> (changed: bool, prev: u16) {

	for x in 0 ..< CHUNKS_PER_DIRECTION {
		for z in 0 ..< CHUNKS_PER_DIRECTION {
			chunk := &Chunks[x][z]
			minF32 := [2]f32{f32(chunk.pos[0]), f32(chunk.pos[1])}
			maxF32 := [2]f32{f32(chunk.pos[0] + CHUNK_STRIDE), f32(chunk.pos[1] + CHUNK_STRIDE)}

			if worldPos.x < minF32[0] || worldPos.x > maxF32[0] do continue
			if worldPos.z < minF32[1] || worldPos.z > maxF32[1] do continue

			indexX := i32(math.round(worldPos.x - minF32[0]))
			indexZ := i32(math.round(worldPos.z - minF32[1]))
			indexY := i32(math.round(worldPos.y) - MIN_Y)

			assert(indexX >= 0 && indexX < VERTS_PER_X_DIR)
			assert(indexY >= 0 && indexY < VERTS_PER_Y_DIR)
			assert(indexZ >= 0 && indexZ < VERTS_PER_Z_DIR)

			chunk_point_edit_add_thread(x, z, indexX, indexY, indexZ, newType)
			changed = true
			prev = chunk.points[index_into_point_arrays(indexX, indexY, indexZ)]
		}
	}
	return changed, prev
}
chunks_frame_update :: proc(c: ^camera.Camera) {

	for x in 0 ..< CHUNKS_PER_DIRECTION {
		for z in 0 ..< CHUNKS_PER_DIRECTION {
			if Chunks[x][z].dirty {
				Chunks[x][z].dirty = false
				chunk_update_add_thread(x, z)
			}
		}
	}
	sync.wait(&chunkWorkersWG)
	chunks_shift_per_player_movement(c)
}
chunks_shift_per_player_movement :: proc(c: ^camera.Camera) {
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


is_chunk_in_camera_frustrum :: proc(pos: [2]i32, c: ^camera.Camera) -> bool {
	min := [3]f32{f32(pos[0]), f32(MIN_Y), f32(pos[1])}
	max := [3]f32{f32((pos[0] + CHUNK_SIZE)), f32(MAX_Y), f32((pos[1] + CHUNK_SIZE))}

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
