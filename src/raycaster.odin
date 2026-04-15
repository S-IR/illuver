package main

import "core:math"
import la "core:math/linalg"
import "core:simd"
import "core:sort"


raycast_get_viewed_point :: proc(
	origin: [3]f32,
	rayDir: [3]f32,
) -> (
	closestPoint: u16,
	closestPointPosition: [3]f32,
	found: bool,
) {
	// assert(c != nil)
	assert(la.length(rayDir) > .99 && la.length(rayDir) < 1.01)
	// assert(la.length(rayDir) > .99 && la.length(rayDir) < 1.01)

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
				if math.abs(rayDir[i]) < math.F32_EPSILON {
					if origin[i] < expMin[i] || origin[i] > expMax[i] {
						intersectsExp = false
						break
					}
				} else {
					t1 := (expMin[i] - origin[i]) / rayDir[i]
					t2 := (expMax[i] - origin[i]) / rayDir[i]
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
				if math.abs(rayDir[i]) < math.F32_EPSILON {
					if origin[i] < boxMin[i] || origin[i] > boxMax[i] {
						intersectsOrig = false
						break
					}
				} else {
					t1 := (boxMin[i] - origin[i]) / rayDir[i]
					t2 := (boxMax[i] - origin[i]) / rayDir[i]
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
		origin.z,
		origin.z,
		origin.z,
		origin.z,
		origin.z,
		origin.z,
		origin.z,
		origin.z,
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
					vectorX := posX - origin.x
					vectorY := posY - origin.y
					vectorZSimd := vzSimd - cameraZSIMD
					distanceAlongViewSimd :=
						vectorX * rayDir.x + vectorY * rayDir.y + vectorZSimd * rayDir.z
					len2Simd := vectorX * vectorX + vectorY * vectorY + vectorZSimd * vectorZSimd
					distSqSimd := len2Simd - distanceAlongViewSimd * distanceAlongViewSimd
					baseIndex := index_into_point_arrays(x, y, z)

					for l in 0 ..< i32(8) {
						if z + i32(l) >= VERTS_PER_Z_DIR do break

						point := chunk.points[baseIndex + l]
						when VISUAL_REPRESENTATION_OF_NOISE_FN_RUN {
							if point == 0.0 do continue
						} else {
							if point == 0 do continue
						}

						t := simd.extract(distanceAlongViewSimd, l)
						distSq := simd.extract(distSqSimd, l)

						if t >= 0 && distSq <= HIT_RADIUS_SQ {
							// jitter := calculate_jitter(
							// 	i32(posX),
							// 	i32(posY),
							// 	i32(basePosZ) + i32(l),
							// 	seed,
							// )

							actualPos := point_real_world_position({posX, posY, basePosZ + f32(l)})

							realVecX := actualPos.x - origin.x
							realVecY := actualPos.y - origin.y
							realVecZ := actualPos.z - origin.z

							realT :=
								realVecX * rayDir.x + realVecY * rayDir.y + realVecZ * rayDir.z
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
compute_mouse_ray :: proc(
	mouseX, mouseY: f32,
	screenWidth, screenHeight: u32,
	view, proj: matrix[4, 4]f32,
) -> [3]f32 {

	ndcX := (2.0 * f32(mouseX) / f32(screenWidth)) - 1.0
	ndcY := 1.0 - (2.0 * f32(mouseY) / f32(screenHeight))

	inv := la.inverse(proj * view)

	near := float4{ndcX, ndcY, 0, 1}
	far := float4{ndcX, ndcY, 1, 1}

	nearW := inv * near
	farW := inv * far

	nearW.xyz /= nearW.w
	farW.xyz /= farW.w

	return la.normalize(farW.xyz - nearW.xyz)
}
