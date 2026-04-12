package main

import "core:math"
import la "core:math/linalg"
import "core:simd"
import "core:sort"


raycast_get_viewed_point :: proc(
	c: ^Camera,
) -> (
	closestPoint: PointType,
	closestPointPosition: [3]f32,
	found: bool,
) {
	assert(c != nil)
	assert(la.length(c.front) > .99 && la.length(c.front) < 1.01)
	HIT_RADIUS :: 1.0
	HIT_RADIUS_SQ :: HIT_RADIUS * HIT_RADIUS
	closestDist := math.INF_F32

	ChunkInfo :: struct {
		chunk: ^Chunk,
		tMin:  f32,
	}
	potentialChunks := make([dynamic]ChunkInfo, context.temp_allocator)

	for &chunkX in Chunks {
		for &chunk_ in chunkX {
			chunk := &chunk_
			boxMin := [3]f32{f32(chunk.pos[0]), f32(MIN_Y), f32(chunk.pos[1])}
			boxMax :=
				boxMin + [3]f32{f32(VERTS_PER_X_DIR), f32(VERTS_PER_Y_DIR), f32(VERTS_PER_Z_DIR)}

			// Expanded AABB for accurate culling (any point <= HIT_RADIUS from ray must intersect expanded box)
			expMin := boxMin - HIT_RADIUS
			expMax := boxMax + HIT_RADIUS

			// Ray intersect with expanded AABB
			tMinExp: f32 = 0
			tMaxExp: f32 = math.INF_F32
			intersectsExp := true
			for i in 0 ..< 3 {
				if math.abs(c.front[i]) < math.F32_EPSILON {
					if c.pos[i] < expMin[i] || c.pos[i] > expMax[i] {
						intersectsExp = false
						break
					}
				} else {
					t1 := (expMin[i] - c.pos[i]) / c.front[i]
					t2 := (expMax[i] - c.pos[i]) / c.front[i]
					if t1 > t2 {t1, t2 = t2, t1}
					tMinExp = max(tMinExp, t1)
					tMaxExp = min(tMaxExp, t2)
					if tMinExp > tMaxExp {
						intersectsExp = false
						break
					}
				}
			}
			if !intersectsExp || tMaxExp < 0 do continue

			// For sorting, use tMin to original AABB if intersects, else to expanded
			tMinOrig: f32 = 0
			tMaxOrig: f32 = math.INF_F32
			intersectsOrig := true
			for i in 0 ..< 3 {
				if math.abs(c.front[i]) < math.F32_EPSILON {
					if c.pos[i] < boxMin[i] || c.pos[i] > boxMax[i] {
						intersectsOrig = false
						break
					}
				} else {
					t1 := (boxMin[i] - c.pos[i]) / c.front[i]
					t2 := (boxMax[i] - c.pos[i]) / c.front[i]
					if t1 > t2 {t1, t2 = t2, t1}
					tMinOrig = max(tMinOrig, t1)
					tMaxOrig = min(tMaxOrig, t2)
					if tMinOrig > tMaxOrig {
						intersectsOrig = false
						break
					}
				}
			}
			sortT := intersectsOrig ? max(0, tMinOrig) : max(0, tMinExp)

			append(&potentialChunks, ChunkInfo{chunk = chunk, tMin = sortT})
		}
	}

	sort.quick_sort_proc(potentialChunks[:], proc(a, b: ChunkInfo) -> int {
		if a.tMin < b.tMin do return -1
		if a.tMin > b.tMin do return 1
		return 0
	})

	cameraZSIMD := #simd[8]f32 {
		c.pos.z,
		c.pos.z,
		c.pos.z,
		c.pos.z,
		c.pos.z,
		c.pos.z,
		c.pos.z,
		c.pos.z,
	}

	for info in potentialChunks {
		if info.tMin >= closestDist do break
		chunk := info.chunk
		for x: i32 = 0; x < VERTS_PER_X_DIR; x += 1 {
			for y: i32 = 0; y < VERTS_PER_Y_DIR; y += 1 {
				for z: i32 = 0; z < VERTS_PER_Z_DIR; z += 8 {
					posX := f32(chunk.pos[0] + x)
					posY := f32(MIN_Y + y)
					basePosZ := f32(chunk.pos[1] + z)
					vzSimd := #simd[8]f32 {
						basePosZ + 0,
						basePosZ + 1,
						basePosZ + 2,
						basePosZ + 3,
						basePosZ + 4,
						basePosZ + 5,
						basePosZ + 6,
						basePosZ + 7,
					}
					vectorX := posX - c.pos.x
					vectorY := posY - c.pos.y
					vectorZSimd := vzSimd - cameraZSIMD
					distanceAlongViewSimd :=
						vectorX * c.front.x + vectorY * c.front.y + vectorZSimd * c.front.z
					len2Simd := vectorX * vectorX + vectorY * vectorY + vectorZSimd * vectorZSimd
					distSqSimd := len2Simd - distanceAlongViewSimd * distanceAlongViewSimd
					baseIndex := index_into_point_arrays(x, y, z)

					for l in 0 ..< i32(8) {
						if z + i32(l) >= VERTS_PER_Z_DIR do break

						point := chunk.points[baseIndex + l]
						when VISUAL_REPRESENTATION_OF_NOISE_FN_RUN {
							if point == 0.0 do continue
						} else {
							if point == .Air do continue
						}

						t := simd.extract(distanceAlongViewSimd, l)
						distSq := simd.extract(distSqSimd, l)

						if t >= 0 && distSq <= HIT_RADIUS_SQ {
							jitter := calculate_jitter(
								i32(posX),
								i32(posY),
								i32(basePosZ) + i32(l),
								seed,
							)

							actualPos := [3]f32 {
								posX + jitter.x,
								posY + jitter.y,
								basePosZ + f32(l) + jitter.z,
							}

							// Recompute real distance to ray using jittered position
							realVecX := actualPos.x - c.pos.x
							realVecY := actualPos.y - c.pos.y
							realVecZ := actualPos.z - c.pos.z

							realT :=
								realVecX * c.front.x + realVecY * c.front.y + realVecZ * c.front.z
							realLen2 :=
								realVecX * realVecX + realVecY * realVecY + realVecZ * realVecZ
							realDistSq := realLen2 - realT * realT

							if realT >= 0 && realDistSq <= HIT_RADIUS_SQ {
								if realT < closestDist {
									closestDist = realT
									closestPoint = point
									closestPointPosition = actualPos
								}
							}
						}
					}}
			}
		}
	}

	found = closestDist != math.INF_F32
	return closestPoint, closestPointPosition, found
}
