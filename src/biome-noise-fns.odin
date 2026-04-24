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
		gorglai_point_type(points, worldXYZ, index, seed)
		return

	case .Arakholm:
		arakholm_point_type(points, worldXYZ, index, seed)
		return

	case .Merplia:
		merplia_point_type(points, worldXYZ, index, seed)
		return

	case .Wintercrown:
		wintercrown_point_type(points, worldXYZ, index, seed)
		return

	case .Scholathorn:
		scholathorn_point_type(points, worldXYZ, index, seed)
		return

	case .Adwaron:
		adwaron_point_type(points, worldXYZ, index, seed)
		return

	case .Etherwind:
		etherwind_point_type(points, worldXYZ, index, seed)
		return
	}
	unreachable()
}
CRYSTALBLOOM_GRASS_DEPTH :: 2
CRYSTALBLOOM_LOAM_DEPTH :: 5
CRYSTALBLOOM_MID_DEPTH :: 45

CRYSTALBLOOM_SHARD_WALL :: 0.06
CRYSTALBLOOM_COLOSSAL_WALL :: 0.05

crystalbloom_point_type :: proc(
	points: ^[MAX_POINTS]u16,
	worldXYZ, index: [3]i32,
	topY: i32,
	seed: u64,
) {
	diffY := topY - worldXYZ.y


	inMidZone := diffY < CRYSTALBLOOM_MID_DEPTH

	if !inMidZone {
		noise := algorithms.fbm_3d(
			f64(worldXYZ.x),
			f64(worldXYZ.y),
			f64(worldXYZ.z),
			seed + 0x864,
			2,
			.5,
			.5,
		)
		if noise > 0.78 {
			points[index_into_point_arrays(index)] = u16(PointType.BlueDiamond)
			return
		} else if noise > 0.72 {
			points[index_into_point_arrays(index)] = u16(PointType.BlackCliff)
			return
		} else if noise > 0.68 {
			points[index_into_point_arrays(index)] = u16(PointType.Air)
			return
		} else {
			points[index_into_point_arrays(index)] = u16(PointType.CrystalTrunk)
			return

		}

	}
	// --- Vertical shafts: punch columns from just below loam down into mid zone ---
	// 2D noise so the shaft is consistent across the full Y column
	if inMidZone {
		SHAFT_SCALE :: 0.018
		shaft := algorithms.fbm_2d(
			f64(worldXYZ.x) * SHAFT_SCALE,
			f64(worldXYZ.z) * SHAFT_SCALE,
			seed + 0x5AFE,
			2,
			2.0,
			0.5,
		)
		// shaft > 0.78 = open air column
		// shaft > 0.72 = shard wall lining the shaft
		if shaft > 0.78 {
			points[index_into_point_arrays(index)] = u16(PointType.Air)
			return
		}
		if shaft > 0.72 {
			points[index_into_point_arrays(index)] = u16(PointType.SharditeMineral)
			return
		}
	}

	// --- Mid zone horizontal corridors ---
	if inMidZone {
		CORRIDOR_SCALE_XZ :: 0.025
		CORRIDOR_SCALE_Y :: 0.008 // very stretched vertically = flat corridors
		corridor := algorithms.fbm_3d(
			f64(worldXYZ.x) * CORRIDOR_SCALE_XZ,
			f64(worldXYZ.y) * CORRIDOR_SCALE_Y,
			f64(worldXYZ.z) * CORRIDOR_SCALE_XZ,
			seed + 0xACAD,
			3,
			2.0,
			0.5,
		)
		if corridor > 0.72 {
			points[index_into_point_arrays(index)] = u16(PointType.Air)
			return
		}
		if corridor > 0.66 {
			points[index_into_point_arrays(index)] = u16(PointType.SharditeMineral)
			return
		}
		points[index_into_point_arrays(index)] = u16(PointType.VeilStone)
		return
	}

	// --- Deep zone horizontal corridors ---
	{
		CORRIDOR_SCALE_XZ :: 0.02
		CORRIDOR_SCALE_Y :: 0.006
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
	}
}

gorglai_point_type :: proc(points: ^[MAX_POINTS]u16, worldXYZ, index: [3]i32, seed: u64) {
	//todo
	points[index_into_point_arrays(index)] = u16(PointType.Water)
}
arakholm_point_type :: proc(points: ^[MAX_POINTS]u16, worldXYZ, index: [3]i32, seed: u64) {
	//todo
	points[index_into_point_arrays(index)] = u16(PointType.Water)
}
merplia_point_type :: proc(points: ^[MAX_POINTS]u16, worldXYZ, index: [3]i32, seed: u64) {
	//todo
	points[index_into_point_arrays(index)] = u16(PointType.Water)
}
wintercrown_point_type :: proc(points: ^[MAX_POINTS]u16, worldXYZ, index: [3]i32, seed: u64) {
	//todo
	points[index_into_point_arrays(index)] = u16(PointType.Water)
}

scholathorn_point_type :: proc(points: ^[MAX_POINTS]u16, worldXYZ, index: [3]i32, seed: u64) {
	//todo
	points[index_into_point_arrays(index)] = u16(PointType.Water)
}
adwaron_point_type :: proc(points: ^[MAX_POINTS]u16, worldXYZ, index: [3]i32, seed: u64) {
	//todo
	points[index_into_point_arrays(index)] = u16(PointType.Water)
}

etherwind_point_type :: proc(points: ^[MAX_POINTS]u16, worldXYZ, index: [3]i32, seed: u64) {
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
