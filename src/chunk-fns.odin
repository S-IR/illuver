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

chunk_set_point :: proc(worldPos: [3]f32, newType: PointType) -> (changed: bool, prev: u16) {

	for x in 0 ..< CHUNKS_PER_DIRECTION {
		for z in 0 ..< CHUNKS_PER_DIRECTION {
			chunk := &RenderedChunks[x][z]
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

			if u16_to_point_type(chunk.points[index_into_point_arrays(indexX, indexY, indexZ)]) == newType do continue
			changed = true
			prev = chunk.points[index_into_point_arrays(indexX, indexY, indexZ)]
			chunk_point_edit_add_thread(x, z, indexX, indexY, indexZ, u16(newType))
		}
	}
	return changed, prev
}
chunks_frame_update :: proc(c: ^camera.Camera) {

	for x in 0 ..< CHUNKS_PER_DIRECTION {
		for z in 0 ..< CHUNKS_PER_DIRECTION {
			if RenderedChunks[x][z].dirty {
				RenderedChunks[x][z].dirty = false
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
	xzOfPrevCenterChunk :=
		RenderedChunks[CHUNK_MIDDLE_X_INDEX][CHUNK_MIDDLE_Z_INDEX].pos / CHUNK_STRIDE
	if xzOfCurrentCenterChunk == xzOfPrevCenterChunk do return
	delta := xzOfCurrentCenterChunk - xzOfPrevCenterChunk
	half := CHUNKS_PER_DIRECTION / 2

	if delta.x != 0 {
		count := abs(delta.x)
		for i in 0 ..< count {
			if delta.x > 0 {
				for x in 0 ..< CHUNKS_PER_DIRECTION - 1 {
					for z in 0 ..< CHUNKS_PER_DIRECTION {
						firstBuffers := RenderedChunks[x][z].buffers
						secondBuffers := RenderedChunks[x + 1][z].buffers
						RenderedChunks[x][z] = RenderedChunks[x + 1][z]
						RenderedChunks[x][z].buffers, RenderedChunks[x + 1][z].buffers =
							secondBuffers, firstBuffers
						RenderedChunks[x + 1][z].points = {}
						RenderedChunks[x + 1][z].arena = {}
						RenderedChunks[x + 1][z].alloc = {}
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
						firstBuffers := RenderedChunks[x][z].buffers
						secondBuffers := RenderedChunks[x - 1][z].buffers
						RenderedChunks[x][z] = RenderedChunks[x - 1][z]
						RenderedChunks[x][z].buffers, RenderedChunks[x - 1][z].buffers =
							secondBuffers, firstBuffers

						RenderedChunks[x - 1][z].points = {}
						RenderedChunks[x - 1][z].arena = {}
						RenderedChunks[x - 1][z].alloc = {}
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
						firstBuffers := RenderedChunks[x][z].buffers
						secondBuffers := RenderedChunks[x][z + 1].buffers
						RenderedChunks[x][z] = RenderedChunks[x][z + 1]
						RenderedChunks[x][z].buffers, RenderedChunks[x][z + 1].buffers =
							secondBuffers, firstBuffers

						RenderedChunks[x][z + 1].points = {}
						RenderedChunks[x][z + 1].arena = {}
						RenderedChunks[x][z + 1].alloc = {}
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
						firstBuffers := RenderedChunks[x][z].buffers
						secondBuffers := RenderedChunks[x][z - 1].buffers
						RenderedChunks[x][z] = RenderedChunks[x][z - 1]
						RenderedChunks[x][z].buffers, RenderedChunks[x][z - 1].buffers =
							secondBuffers, firstBuffers

						RenderedChunks[x][z - 1].points = {}
						RenderedChunks[x][z - 1].arena = {}
						RenderedChunks[x][z - 1].alloc = {}
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

get_point_at_world_pos :: proc(worldGridPos: [3]f32, currCamera: camera.Camera) -> u16 {
	when ODIN_DEBUG {
		worldPosRounded := linalg.round(worldGridPos)
		assert(worldPosRounded == worldGridPos)
	}

	worldCoordXYZ := [3]i32{i32(worldGridPos.x), i32(worldGridPos.y), i32(worldGridPos.z)}

	if worldCoordXYZ.y < MIN_Y || worldCoordXYZ.y > MAX_Y {
		return 0
	}

	chunkCoordXZ := [2]i32 {
		i32(math.floor(f32(worldCoordXYZ.x) / CHUNK_STRIDE)),
		i32(math.floor(f32(worldCoordXYZ.z) / CHUNK_STRIDE)),
	}

	centerChunk := RenderedChunks[CHUNK_MIDDLE_X_INDEX][CHUNK_MIDDLE_Z_INDEX]
	centerChunkCoord := centerChunk.pos / CHUNK_STRIDE

	arrayIndex := [2]i32 {
		CHUNK_MIDDLE_X_INDEX + (chunkCoordXZ[0] - centerChunkCoord[0]),
		CHUNK_MIDDLE_Z_INDEX + (chunkCoordXZ[1] - centerChunkCoord[1]),
	}
	// assert(!(arrayIndex.x < 0 || arrayIndex.x >= CHUNKS_PER_DIRECTION))
	// assert(!(arrayIndex.y < 0 || arrayIndex.y >= CHUNKS_PER_DIRECTION))

	if arrayIndex.x < 0 || arrayIndex.x >= CHUNKS_PER_DIRECTION do return 0
	if arrayIndex.y < 0 || arrayIndex.y >= CHUNKS_PER_DIRECTION do return 0

	chunk := RenderedChunks[arrayIndex.x][arrayIndex.y]

	localXYZ := [3]i32 {
		worldCoordXYZ.x - chunk.pos.x,
		worldCoordXYZ.y - MIN_Y,
		worldCoordXYZ.z - chunk.pos.y,
	}

	assert(localXYZ.x >= 0 && localXYZ.x < VERTS_PER_X_DIR)
	assert(localXYZ.y >= 0 && localXYZ.y < VERTS_PER_Y_DIR)
	assert(localXYZ.z >= 0 && localXYZ.z < VERTS_PER_Z_DIR)

	return chunk.points[index_into_point_arrays(localXYZ)]
}
MAX_WALKABLE_SLOPE :: f32(0.6)

// TerrainSample :: struct {
// 	height:   f32, // world Y at camera XZ
// 	normal:   [3]f32, // surface normal of triangle below
// 	slopeCos: f32, // dot(normal, UP) — 1.0 = flat, 0.0 = vertical
// 	walkable: bool, // slope_cos above threshold
// }
sample_terrain_below :: proc(c: ^camera.Camera) {


	camWorldCoord := [2]i32{i32(math.floor(c.pos.x)), i32(math.floor(c.pos.z))}

	chunk := &RenderedChunks[CHUNKS_PER_DIRECTION / 2][CHUNKS_PER_DIRECTION / 2]
	when ODIN_DEBUG {
		goodX := localCoord[0] >= 0 && localCoord[0] < CHUNK_STRIDE
		goodZ := localCoord[1] >= 0 && localCoord[1] < CHUNK_STRIDE
		assert(goodZ)
		assert(goodX)
	}
	worldGridPosF32 := linalg.round(c.pos)
	worldGridPos := linalg.to_i32(worldGridPosF32)

	localCoordsInChunk := worldGridPos - [3]i32{chunk.pos[0], MIN_Y, chunk.pos[1]}


	floorYIndex: i32 = MIN_Y
	for iter: i32 = i32(math.floor(c.pos.y)); iter >= i32(MIN_Y); iter -= 1 {
		y := iter - MIN_Y
		assert(y >= 0 && y < i32(VERTS_PER_Y_DIR))

		if chunk.points[index_into_point_arrays(localCoordsInChunk.x, y, localCoordsInChunk.z)] !=
		   0 {
			floorYIndex = y
			break
		}

	}
	belowPointWorldPos := local_index_to_world_pos(
		chunk.pos,
		[3]i32{localCoordsInChunk.x, floorYIndex, localCoordsInChunk.z},
	)


	when ODIN_DEBUG {
		assert(c.pos.y - belowPointWorldPos.y > camera.PLAYER_SIZE)
	}

	areWeOnPlusX := c.pos.x - belowPointWorldPos.x > 0
	areWeOnPlusZ := c.pos.z - belowPointWorldPos.z > 0


	chunkOffsetForX := 0
	if areWeOnPlusX && localCoordsInChunk.x + 1 >= VERTS_PER_X_DIR do chunkOffsetForX = 1
	if !areWeOnPlusX && localCoordsInChunk.x - 1 < 0 do chunkOffsetForX = -1

	chunkOffsetForZ := 0
	if areWeOnPlusZ && localCoordsInChunk.z + 1 >= VERTS_PER_Z_DIR do chunkOffsetForZ = 1
	if !areWeOnPlusZ && localCoordsInChunk.z - 1 < 0 do chunkOffsetForZ = -1

	corner2Chunk := &RenderedChunks[(CHUNKS_PER_DIRECTION / 2) + chunkOffsetForX][CHUNKS_PER_DIRECTION / 2]
	corner3Chunk := &RenderedChunks[(CHUNKS_PER_DIRECTION / 2)][(CHUNKS_PER_DIRECTION / 2) + chunkOffsetForZ]
	corner4Chunk := &RenderedChunks[(CHUNKS_PER_DIRECTION / 2) + chunkOffsetForX][(CHUNKS_PER_DIRECTION / 2) + chunkOffsetForZ]

	corner1 := belowPointWorldPos
	corner2, corner3, corner4: [3]f32

	get_closest_point_in_grid :: proc(chunk: ^Chunk, gridCoord: [3]i32) -> (res: [3]i32) {
		assert(gridCoord.x >= 0 && gridCoord.x < VERTS_PER_X_DIR)
		assert(gridCoord.y >= 0 && gridCoord.y < VERTS_PER_Y_DIR)
		assert(gridCoord.z >= 0 && gridCoord.z < VERTS_PER_Z_DIR)

		closestBorderY: i32 = MIN_Y
		if MAX_Y - 1 - gridCoord.y < MIN_Y - gridCoord.y {
			closestBorderY = MAX_Y - 1
		}
		for i: i32 = 0; (gridCoord.y + i < MAX_Y) || (gridCoord.y - i > MIN_Y); i += 1 {
			reachedTop := gridCoord.y + i >= MAX_Y
			reachedBottom := gridCoord.y - i <= MIN_Y
			topPoint, bottomPoint: u16

			topCoords := [3]i32{gridCoord.x, gridCoord.y + i, gridCoord.z}
			bottomCoords := [3]i32{gridCoord.x, gridCoord.y - i, gridCoord.z}
			if !reachedTop do topPoint = chunk.points[index_into_point_arrays(topCoords)]
			if !reachedBottom do bottomPoint = chunk.points[index_into_point_arrays(bottomCoords)]

			foundTop := !reachedTop && topPoint != 0
			foundBottom := !reachedBottom && bottomPoint != 0

			if foundTop {
				res = topCoords
				if reachedBottom do return res
			}

			if foundBottom {
				res = bottomCoords
				if reachedTop do return res
			}
			if foundTop && foundBottom {
				topRealPos := local_index_to_world_pos(chunk.pos, topCoords)
				bottomRealPos := local_index_to_world_pos(chunk.pos, bottomCoords)
				startPointRealPos := local_index_to_world_pos(chunk.pos, gridCoord)

				diffTop := topRealPos.y - startPointRealPos.y
				diffBottom := startPointRealPos.y - bottomRealPos.y

				topIsSmaller := diffTop < diffBottom
				if topIsSmaller {
					return topCoords
				} else {
					return bottomCoords
				}

			}

		}
		return {gridCoord.x, closestBorderY, gridCoord.z}

	}

	{
		offsetForX: i32 = 1 if areWeOnPlusX else -1
		offsetForZ: i32 = 1 if areWeOnPlusZ else -1

		corner2LocalCoord := localCoordsInChunk + {offsetForX, 0, 0}
		corner2LocalCoord.x /= VERTS_PER_X_DIR
		corner2 = local_index_to_world_pos(
			corner2Chunk.pos,
			get_closest_point_in_grid(corner2Chunk, corner2LocalCoord),
		)


		corner3LocalCoord := localCoordsInChunk + {0, 0, offsetForZ}
		corner3LocalCoord.z /= VERTS_PER_Z_DIR
		corner3 = local_index_to_world_pos(
			corner3Chunk.pos,
			get_closest_point_in_grid(corner3Chunk, corner3LocalCoord),
		)


		corner4LocalCoord := localCoordsInChunk + {offsetForX, 0, offsetForZ}
		corner4LocalCoord.z /= VERTS_PER_Z_DIR
		corner4LocalCoord.x /= VERTS_PER_X_DIR
		corner4 = local_index_to_world_pos(
			corner4Chunk.pos,
			get_closest_point_in_grid(corner4Chunk, corner4LocalCoord),
		)


	}
	point_in_triangle_xz :: proc(p, a, b, c: [3]f32) -> bool {
		cross :: proc(a, b: [2]f32) -> f32 {return a.x * b.y - a.y * b.x}

		d1 := cross(p.xz - a.xz, b.xz - a.xz)
		d2 := cross(p.xz - b.xz, c.xz - b.xz)
		d3 := cross(p.xz - c.xz, a.xz - c.xz)

		hasNeg := (d1 < 0) || (d2 < 0) || (d3 < 0)
		hasPos := (d1 > 0) || (d2 > 0) || (d3 > 0)
		return !(hasNeg || hasPos)
	}

	a, b, cc_: [3]f32
	if point_in_triangle_xz(c.pos, corner1, corner2, corner3) {
		a, b, cc_ = corner1, corner2, corner3
	} else {
		a, b, cc_ = corner4, corner2, corner3
	}

	edge1 := b - a
	edge2 := c - a
	normal := linalg.normalize(linalg.cross(edge1, edge2))
	if normal.y < 0 do normal = -normal
	height :=
		corner1.y -
		(normal.x * (c.pos.x - corner1.x) + normal.z * (c.pos.z - corner1.z)) / normal.y

}
