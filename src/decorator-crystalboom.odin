package main
import "core:math"
import "core:math/rand"
crystalbloom_create_tree :: proc(
	points: ^[MAX_POINTS]u16,
	heightMap: ^[CHUNK_HEIGHTMAP_SIZE]i32,
	worldXYZ, index: [3]i32,
	treeUpperBoundY: i32,
	decoratorNoise: f32,
	leavesRadius: i32,
) {
	assert(treeUpperBoundY >= MIN_Y && treeUpperBoundY < MAX_Y)
	if index.z >= CHUNK_STRIDE do return
	if index.x >= CHUNK_STRIDE do return


	twoDIdx := worldXYZ.xz
	// yDiff := worldXYZ.y - index.y
	for i: i32 = worldXYZ.y + 1; i < MAX_Y && i < treeUpperBoundY; i += 1 {
		iIdx := i - MIN_Y
		currIdx := [3]i32{index.x, iIdx, index.z}
		point_place_update_height(points, heightMap, currIdx, u16(PointType.PinkTrunk))
		point_place_update_height(points, heightMap, currIdx + {1, 0, 0}, u16(PointType.PinkTrunk))
		point_place_update_height(points, heightMap, currIdx + {0, 0, 1}, u16(PointType.PinkTrunk))

		// points[index_into_point_arrays(currIdx + {1, 0, 1})] = u16(PointType.PinkTrunk)

		// heightMap[index_into_height_map(twoDIdx + {1, 1})] = i

	}

	surround_with_leaves(
		points,
		heightMap,
		{index.x, (treeUpperBoundY - 1) - MIN_Y, index.z},
		leavesRadius,
	)

	surround_with_leaves :: proc(
		points: ^[MAX_POINTS]u16,
		heightMap: ^[CHUNK_HEIGHTMAP_SIZE]i32,
		middleIdx: [3]i32,
		leavesRadius: i32,
	) {
		assert(leavesRadius != 0)
		assert_point_array_index_valid(middleIdx)
		leavesSq := leavesRadius * leavesRadius
		for x := math.max(0, middleIdx.x - leavesRadius);
		    x <= CHUNK_STRIDE && x < (middleIdx.x + leavesRadius + 1);
		    x += 1 {

			for y := math.max(0, middleIdx.y - leavesRadius);
			    y < VERTS_PER_Y_DIR && y < (middleIdx.y + leavesRadius + 1);
			    y += 1 {
				for z := math.max(0, middleIdx.z - leavesRadius);
				    z <= CHUNK_STRIDE && z < (middleIdx.z + leavesRadius + 1);
				    z += 1 {
					dx := x - middleIdx.x
					dy := y - middleIdx.y
					dz := z - middleIdx.z

					if dx * dx + dy * dy + dz * dz > leavesSq do continue
					if u16_to_point_type(points[index_into_point_arrays(x, y, z)]) == PointType.PinkTrunk do continue
					if u16_to_point_type(points[index_into_point_arrays(x, y, z)]) == PointType.WhiteTreeLeaf do continue
					// if rand.float32() < .2 do continue
					point_place_update_height(
						points,
						heightMap,
						{x, y, z},
						u16(PointType.WhiteTreeLeaf),
					)

				}

			}
		}
	}
}
