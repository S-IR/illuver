package main
import "algorithms"
import "core:fmt"
import "core:math"
make_point :: #force_inline proc(pt: PointType, light, life, wisdom: u16) -> u16 {
	p := u16(pt)
	p = set_light(p, light)
	p = set_life(p, life)
	p = set_wisdom(p, wisdom)
	return p
}


biome_point_type :: #force_inline proc(
	points: ^[MAX_POINTS]u16,
	biome: Biome,
	worldXYZ, index: [3]i32,
	topY: i32,
	seed: u64,
) {
	switch biome {
	case .Crystalbloom:
		crystalbloom_point_type(points, worldXYZ, index, topY, seed)
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
		etherwind_point_type(points, worldXYZ, index, topY, seed)
		return
	}
	unreachable()
}

crystalbloom_point_type :: proc(
	points: ^[MAX_POINTS]u16,
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
		noise := algorithms.fbm_3d(
			f64(worldXYZ.x) * GRASS_SCALE,
			f64(worldXYZ.y) * GRASS_SCALE,
			f64(worldXYZ.z) * GRASS_SCALE,
			seed + 0x864,
			2,
			.5,
			.5,
		)
		if noise > 0.78 {
			points[index_into_point_arrays(index)] = u16(PointType.BlueDiamond)
			return
		} else if noise > 0.66 {
			points[index_into_point_arrays(index)] = u16(PointType.BlackCliff)
			return
		} else {
			points[index_into_point_arrays(index)] = u16(PointType.BlueDiamond)
			return

		}

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
	//todo
	points[index_into_point_arrays(index)] = u16(PointType.Water)
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
	biome: Biome,
	worldXYZ, index: [3]i32,
	topY: i32,
	seed: u64,
) {

	biome_point_type(points, biome, worldXYZ, index, topY, seed)

	if points[index_into_point_arrays(index)] == 0 do return

	energy_from_noise(points, worldXYZ, index, seed, biome)

}
