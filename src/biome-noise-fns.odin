package main
import "algorithms"
import "core:fmt"
import "core:math"
import "core:math/noise"
import "core:math/rand"
make_point :: #force_inline proc(pt: PointType, light, life, wisdom: u16) -> u16 {
	p := u16(pt)
	p = set_light(p, light)
	p = set_life(p, life)
	p = set_wisdom(p, wisdom)
	return p
}


biome_point_type :: #force_inline proc(
	points: ^[MAX_POINTS]u16,
	heightMap: ^[CHUNK_HEIGHTMAP_SIZE]i32,
	biome: Biome,
	worldXYZ, index: [3]i32,
	topY: i32,
	seed: u64,
) {
	if u16_to_point_type(points[index_into_point_arrays(index)]) != .Air {
		return
	}
	// points[index_into_point_arrays(index)] = u16(PointType.VeilStone)
	// return
	// fmt.println("worldXYZ", worldXYZ)
	switch biome {
	case .Crystalbloom:
		crystalbloom_point_type(points, heightMap, worldXYZ, index, topY, seed)
		return
	case .Gorglai:
		gorglai_point_type(points, worldXYZ, index, topY, seed)
		return

	case .Arakholm:
		arakholm_point_type(points, worldXYZ, index, topY, seed)
		return

	case .Merplia:
		merplia_point_type(points, worldXYZ, index, topY, seed)
		return

	case .Wintercrown:
		wintercrown_point_type(points, worldXYZ, index, topY, seed)
		return

	case .Scholathorn:
		scholathorn_point_type(points, worldXYZ, index, topY, seed)
		return

	case .Adwaron:
		adwaron_point_type(points, worldXYZ, index, topY, seed)
		return

	case .Etherwind:
		etherwind_point_type(points, heightMap, worldXYZ, index, topY, seed)
		return
	}
	unreachable()
}

crystalbloom_point_type :: proc(
	points: ^[MAX_POINTS]u16,
	heightMap: ^[CHUNK_HEIGHTMAP_SIZE]i32,
	worldXYZ, index: [3]i32,
	topY: i32,
	seed: u64,
) {
	CRYSTALBLOOM_GRASS_DEPTH :: 5
	CRYSTALBLOOM_LOAM_DEPTH :: 15
	CRYSTALBLOOM_MID_DEPTH :: 45

	assert(topY >= worldXYZ.y)
	diffY := topY - worldXYZ.y


	if diffY < CRYSTALBLOOM_LOAM_DEPTH {
		GRASS_SCALE :: 0.02
		fbmNoise := algorithms.fbm_3d(
			f64(worldXYZ.x) * GRASS_SCALE,
			f64(worldXYZ.y) * GRASS_SCALE,
			f64(worldXYZ.z) * GRASS_SCALE,
			seed + 0x864,
			2,
			.5,
			.5,
		)
		chosenBlock := u16(PointType.BlueDiamond)
		if fbmNoise > 0.78 {
			chosenBlock = u16(PointType.LightPurpleGround)
		} else if fbmNoise > 0.60 {
			chosenBlock = u16(PointType.BlackCliff)
		}

		if chosenBlock != u16(PointType.BlueDiamond) {
			TREE_SCALE: f64 : .5
			decoratorNoise := noise.noise_2d(
				transmute(i64)seed,
				{f64(worldXYZ.x) * TREE_SCALE, f64(worldXYZ.z) * TREE_SCALE},
			)
			decoratorIf: if worldXYZ.y == (topY - 1) && rand.float32() < .02 {
				MIN_TREE_RADIUS :: 3
				leavesRadius: i32 = MIN_TREE_RADIUS + i32(math.round(rand.float32() * 2))

				MIN_HEIGHT_SIZE :: 12
				treeUpperBound: i32 = MIN_HEIGHT_SIZE + 1 + i32(math.round(decoratorNoise * 6))
				treeUpperBoundY := worldXYZ.y + treeUpperBound

				lowerBoundV2 := index.xz - leavesRadius
				upperBoundV2 := index.xz + leavesRadius
				if chunk_point_oob({lowerBoundV2[0], index.y, lowerBoundV2[1]}) do break decoratorIf
				if chunk_point_oob({upperBoundV2[0], treeUpperBoundY + leavesRadius - (worldXYZ.y - index.y), upperBoundV2[1]}) do break decoratorIf

				crystalbloom_create_tree(
					points = points,
					heightMap = heightMap,
					worldXYZ = worldXYZ,
					index = index,
					treeUpperBoundY = treeUpperBoundY,
					decoratorNoise = decoratorNoise,
					leavesRadius = leavesRadius,
				)
			}

		}
		points[index_into_point_arrays(index)] = chosenBlock
		return

	}


	// --- Mid zone horizontal corridors ---
	if diffY < CRYSTALBLOOM_MID_DEPTH {
		CORRIDOR_SCALE_XZ :: 0.005
		CORRIDOR_SCALE_Y :: 0.07
		corridor := algorithms.fbm_3d(
			f64(worldXYZ.x) * CORRIDOR_SCALE_XZ,
			f64(worldXYZ.y) * CORRIDOR_SCALE_Y,
			f64(worldXYZ.z) * CORRIDOR_SCALE_XZ,
			seed + 0xACAD,
			3,
			2.0,
			0.5,
		)
		if corridor > 0.71 {
			points[index_into_point_arrays(index)] = u16(PointType.Air)
			return
		}

		points[index_into_point_arrays(index)] = u16(PointType.VeilStone)
		return
	}

	// --- Deep zone horizontal corridors ---
	if worldXYZ.y != MIN_Y {
		CORRIDOR_SCALE_XZ :: 0.02
		CORRIDOR_SCALE_Y :: 0.08
		corridor := algorithms.fbm_3d(
			f64(worldXYZ.x) * CORRIDOR_SCALE_XZ,
			f64(worldXYZ.y) * CORRIDOR_SCALE_Y,
			f64(worldXYZ.z) * CORRIDOR_SCALE_XZ,
			seed + 0x1234,
			3,
			2.0,
			0.45,
		)
		if corridor > 0.70 {
			points[index_into_point_arrays(index)] = u16(PointType.Air)
			return
		}
		if corridor > 0.65 {
			points[index_into_point_arrays(index)] = u16(PointType.SharditeMineral)
			return
		}
		points[index_into_point_arrays(index)] = u16(PointType.AbyssStone)
		return
	} else {
		points[index_into_point_arrays(index)] = u16(PointType.AbyssStone)
		return
	}
}

gorglai_point_type :: proc(
	points: ^[MAX_POINTS]u16,
	worldXYZ, index: [3]i32,
	topY: i32,
	seed: u64,
) {
	diffY := topY - worldXYZ.y
	GORGLAI_ABOVE_LEVEL :: 20
	GORGLAI_CANYON_LEVEL :: -15

	GORGLAI_UNDERGROUND_LEVEL :: -65

	if worldXYZ.y > GORGLAI_ABOVE_LEVEL {
		GORGLAI_PEAK_LEVEL :: 55

		STRIP_XZ_SCALE :: .09
		STRIP_Y_SCALE :: 0.000000002
		mawbeakNoise := noise.noise_3d_improve_xz(
		transmute(i64)(seed + 0x864),
		{
			f64(worldXYZ.x) * STRIP_XZ_SCALE,
			f64(worldXYZ.y) * STRIP_Y_SCALE,
			f64(worldXYZ.z) * STRIP_XZ_SCALE,
		},
		// 2,
		// .5,
		// .5,
		)
		if mawbeakNoise > .45 {
			points[index_into_point_arrays(index)] = u16(PointType.MawbeakRock)
			return
		}


		GROUND_SCALE :: 0.0096
		groundTypeNoise := algorithms.fbm_3d(
			f64(worldXYZ.x) * GROUND_SCALE,
			f64(worldXYZ.y) * GROUND_SCALE,
			f64(worldXYZ.z) * GROUND_SCALE,
			seed + 0x864,
			2,
			.5,
			.5,
		)
		PEAK_STARTING_HEIGHT :: 45
		PEAK_PADDING :: 10


		diffToPeak := f32(
			math.clamp(f64(worldXYZ.y - PEAK_STARTING_HEIGHT) / f64(PEAK_PADDING), 0.0, 1.0),
		)
		peakBlend := f64(diffToPeak) * 0.3
		adjustedNoise := f64(groundTypeNoise) + peakBlend

		if adjustedNoise > .66 {
			points[index_into_point_arrays(index)] = u16(PointType.Peakor)
			return
		}
		points[index_into_point_arrays(index)] = u16(PointType.Gorgveil)
		return
	}
	if worldXYZ.y > GORGLAI_CANYON_LEVEL && worldXYZ.y <= GORGLAI_ABOVE_LEVEL {
		GROUND_SCALE :: 0.00096
		groundTypeNoise := algorithms.fbm_3d(
			f64(worldXYZ.x) * GROUND_SCALE,
			f64(worldXYZ.y) * GROUND_SCALE,
			f64(worldXYZ.z) * GROUND_SCALE,
			seed + 0x864,
			2,
			.5,
			.5,
		)
		if groundTypeNoise > .66 {
			points[index_into_point_arrays(index)] = u16(PointType.AvigniSoil)
			return
		} else if groundTypeNoise > .62 {
			points[index_into_point_arrays(index)] = u16(PointType.AstanaiGrass)
			return
		} else {
			points[index_into_point_arrays(index)] = u16(PointType.Gorgveil)
			return
		}
	}
	#assert(MIN_Y < GORGLAI_UNDERGROUND_LEVEL)
	if worldXYZ.y > GORGLAI_UNDERGROUND_LEVEL {
		CANYON_TOP_PADDING :: GORGLAI_ABOVE_LEVEL - GORGLAI_CANYON_LEVEL
		diffToPeak := f32(
			math.clamp(f64(worldXYZ.y - GORGLAI_CANYON_LEVEL) / f64(CANYON_TOP_PADDING), 0.0, 1.0),
		)
		if diffToPeak >= 1.0 {
			points[index_into_point_arrays(index)] = u16(PointType.Gorgveil)
			return
		}
		CANYON_GROUND_SCALE_XZ :: 0.004
		CANYON_GROUND_SCALE_Y :: 0.004

		canyonNoise := algorithms.worley_3d(
			f64(worldXYZ.x) * CANYON_GROUND_SCALE_XZ,
			f64(worldXYZ.y) * CANYON_GROUND_SCALE_Y,
			f64(worldXYZ.z) * CANYON_GROUND_SCALE_XZ,
			seed + 0x864,
		)
		adjustedNoise := f64(canyonNoise) + f64(diffToPeak) * 0.3

		if adjustedNoise > .51 {
			points[index_into_point_arrays(index)] = u16(PointType.Air)
			return
		} else if adjustedNoise > .39 {
			points[index_into_point_arrays(index)] = u16(PointType.Gorgveil)
			return
		}
		points[index_into_point_arrays(index)] = u16(PointType.Canyonite)
		return
	}
	if worldXYZ.y != MIN_Y {
		UNDERGROUND_CANYON_SIZE_XZ :: 0.028
		UNDERGROUND_CANYON_SIZE_Y :: 0.028
		undergroundCanyonNoise := algorithms.worley_3d(
			f64(worldXYZ.x) * UNDERGROUND_CANYON_SIZE_XZ,
			f64(worldXYZ.y) * UNDERGROUND_CANYON_SIZE_Y,
			f64(worldXYZ.z) * UNDERGROUND_CANYON_SIZE_XZ,
			seed + 0x864,
		)

		if undergroundCanyonNoise > .50 {
			points[index_into_point_arrays(index)] = u16(PointType.Canyonite)
			return
		} else if undergroundCanyonNoise > .45 {
			points[index_into_point_arrays(index)] = u16(PointType.Air)
			return
		}
		points[index_into_point_arrays(index)] = u16(PointType.Avrasar)
		return
	}
	points[index_into_point_arrays(index)] = u16(PointType.Avrasar)
	return
	//todo
}
arakholm_point_type :: proc(
	points: ^[MAX_POINTS]u16,
	worldXYZ, index: [3]i32,
	topY: i32,
	seed: u64,
) {
	//todo
	points[index_into_point_arrays(index)] = u16(PointType.Water)
}
merplia_point_type :: proc(
	points: ^[MAX_POINTS]u16,
	worldXYZ, index: [3]i32,
	topY: i32,
	seed: u64,
) {
	//todo
	points[index_into_point_arrays(index)] = u16(PointType.Water)
}
wintercrown_point_type :: proc(
	points: ^[MAX_POINTS]u16,
	worldXYZ, index: [3]i32,
	topY: i32,
	seed: u64,
) {
	//todo
	points[index_into_point_arrays(index)] = u16(PointType.Water)
}

scholathorn_point_type :: proc(
	points: ^[MAX_POINTS]u16,
	worldXYZ, index: [3]i32,
	topY: i32,
	seed: u64,
) {
	//todo
	points[index_into_point_arrays(index)] = u16(PointType.Water)
}
adwaron_point_type :: proc(
	points: ^[MAX_POINTS]u16,
	worldXYZ, index: [3]i32,
	topY: i32,
	seed: u64,
) {
	//todo

	ADWARON_FIRST_LEVEL_DEEPNESS :: 10
	ADWARON_SECOND_LEVEL_DEEPNESS :: 40

	// points[index_into_point_arrays(index)] = u16(PointType.Water)
	diffY := topY - worldXYZ.y

	if diffY < ADWARON_FIRST_LEVEL_DEEPNESS {
		points[index_into_point_arrays(index)] = u16(PointType.EnchantedSoil)
		SCALE: f64 : 0.02
		noise := algorithms.worley_3d(
			f64(worldXYZ.x) * SCALE,
			f64(worldXYZ.y) * SCALE,
			f64(worldXYZ.z) * SCALE,
			seed,
		)
		if noise > .62 {
			points[index_into_point_arrays(index)] = u16(PointType.Air)
			return
		} else if noise > .42 {
			points[index_into_point_arrays(index)] = u16(PointType.EnchantedPasture)
			return
		} else {
			points[index_into_point_arrays(index)] = u16(PointType.EnchantedSoil)
			return
		}
	} else if diffY < ADWARON_SECOND_LEVEL_DEEPNESS {
		SCALEXZ: f64 : 0.02
		SCALEY: f64 : 0.02

		noise := algorithms.worley_3d(
			f64(worldXYZ.x) * SCALEXZ,
			f64(worldXYZ.y) * SCALEY,
			f64(worldXYZ.z) * SCALEXZ,
			seed,
		)
		if noise > .41 {
			points[index_into_point_arrays(index)] = u16(PointType.Air)
			return
		} else {
			points[index_into_point_arrays(index)] = u16(PointType.MagicAbsorbingRock)
			return
		}

	} else if worldXYZ.y == MIN_Y {
		points[index_into_point_arrays(index)] = u16(PointType.PulsingStone)
		return
	} else {
		points[index_into_point_arrays(index)] = u16(PointType.EnchantedSoil)
		SCALE: f64 : 0.03
		noise := algorithms.worley_3d(
			f64(worldXYZ.x) * SCALE,
			f64(worldXYZ.y) * SCALE,
			f64(worldXYZ.z) * SCALE,
			seed,
		)
		if noise > .38 {
			points[index_into_point_arrays(index)] = u16(PointType.Air)
			return
		} else {
			points[index_into_point_arrays(index)] = u16(PointType.PulsingStone)
			return
		}
	}
	unreachable()

}

etherwind_point_type :: proc(
	points: ^[MAX_POINTS]u16,
	heightMap: ^[CHUNK_HEIGHTMAP_SIZE]i32,
	worldXYZ, index: [3]i32,
	topY: i32,
	seed: u64,
) {
	//todo
	points[index_into_point_arrays(index)] = u16(PointType.Water)
}


energy_from_noise :: #force_inline proc(
	points: ^[MAX_POINTS]u16,
	worldXYZ, index: [3]i32,
	seed: u64,
	biome: Biome,
) {

	n := procedural_point_type_noise_result(worldXYZ.x, worldXYZ.y, worldXYZ.z, seed, biome)

	light := u16(math.clamp(int(n * 4.0), 0, 3))
	life := u16(math.clamp(int((1.0 - n) * 4.0), 0, 3))
	wisdom := u16(math.clamp(int(math.abs(n - 0.5) * 8.0), 0, 3))
	prev := u16_to_point_type(points[index_into_point_arrays(index)])
	points[index_into_point_arrays(index)] = make_point(prev, light, life, wisdom)
}
biome_point :: #force_inline proc(
	points: ^[MAX_POINTS]u16,
	heightMap: ^[CHUNK_HEIGHTMAP_SIZE]i32,
	biome: Biome,
	worldXYZ, index: [3]i32,
	topY: i32,
	seed: u64,
) {

	biome_point_type(points, heightMap, biome, worldXYZ, index, topY, seed)

	if points[index_into_point_arrays(index)] == 0 do return

	energy_from_noise(points, worldXYZ, index, seed, biome)

}
