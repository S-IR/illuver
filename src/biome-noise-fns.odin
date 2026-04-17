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
	biome: Biome,
	x, y, z: i32,
	topY: i32,
	seed: u64,
) -> PointType {
	switch biome {
	case .Crystalbloom:
		return crystalbloom_point_type(x, y, z, topY, seed)

	case .Gorglai:
		return gorglai_point_type(x, y, z, seed)


	case .Arakholm:
		return arakholm_point_type(x, y, z, seed)


	case .Merplia:
		return merplia_point_type(x, y, z, seed)


	case .Wintercrown:
		return wintercrown_point_type(x, y, z, seed)


	case .Scholathorn:
		return scholathorn_point_type(x, y, z, seed)


	case .Adwaron:
		return adwaron_point_type(x, y, z, seed)


	case .Etherwind:
		return etherwind_point_type(x, y, z, seed)

	}
	unreachable()
}
CRYSTALBLOOM_TOP_COVER_LAYER_SIZE :: 6
crystalbloom_point_type :: proc(x, y, z: i32, topY: i32, seed: u64) -> PointType {
	// tunnel := algorithms.fbm_3d(f64(x) * .02, f64(y) * .005, f64(z) * .02, seed, 2, .5, .5)
	diffY := topY - y

	// if diffY < CRYSTALBLOOM_TOP_COVER_LAYER_SIZE {
	// return .LightPurpleGround
	SCALE :: 0.002
	noise := algorithms.ridged_fbm_2d(f64(x) * SCALE, f64(z) * SCALE, seed, 3, 4, 1.1)
	if noise < 0.1 do return .LightPurpleGround
	if noise < 0.3 do return .PurpleGround
	if noise < 0.35 do return .BlackCliff
	// return .YellowDirt
	// }
	return .YellowDirt
}

gorglai_point_type :: proc(x, y, z: i32, seed: u64) -> PointType {
	//todo
	return .Water
}
arakholm_point_type :: proc(x, y, z: i32, seed: u64) -> PointType {
	//todo
	return .Water
}
merplia_point_type :: proc(x, y, z: i32, seed: u64) -> PointType {
	//todo
	return .Water
}
wintercrown_point_type :: proc(x, y, z: i32, seed: u64) -> PointType {
	//todo
	return .Water
}

scholathorn_point_type :: proc(x, y, z: i32, seed: u64) -> PointType {
	//todo
	return .Water
}
adwaron_point_type :: proc(x, y, z: i32, seed: u64) -> PointType {
	//todo
	return .Water
}

etherwind_point_type :: proc(x, y, z: i32, seed: u64) -> PointType {
	//todo
	return .Water
}


energy_from_noise :: #force_inline proc(
	x, y, z: i32,
	seed: u64,
	biome: Biome,
) -> (
	light, life, wisdom: u16,
) {

	n := procedural_point_type_noise_result(x, y, z, seed, biome)

	light = u16(math.clamp(int(n * 4.0), 0, 3))
	life = u16(math.clamp(int((1.0 - n) * 4.0), 0, 3))
	wisdom = u16(math.clamp(int(math.abs(n - 0.5) * 8.0), 0, 3))

	return light, life, wisdom
}
biome_point :: #force_inline proc(biome: Biome, x, y, z: i32, topY: i32, seed: u64) -> u16 {

	pt := biome_point_type(biome, x, y, z, topY, seed)

	if pt == .Air do return 0

	light, life, wisdom := energy_from_noise(x, y, z, seed, biome)

	return make_point(pt, light, life, wisdom)
}
