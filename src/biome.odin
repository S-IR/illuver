ipackage main
import "algorithms"
import "core:fmt"
import "core:math"
import "core:math/noise"
import "core:simd"
import "core:slice"

MIN_BIOME_WEIGHT_TO_NOT_IGNORE :: 3

Biome :: enum {
	Crystalbloom, // crystalsong forest
	Gorglai, // gorground + kun lai summits
	Arakholm, //deepholm + spirals of arak, giant craters
	Merplia, //made up by me, wavy hill region with perfectm math zones
	Wintercrown, // winterspring + icecrown
	Scholathorn, //stranglethon valley + scholazar basin
	Adwaron, //dread wastes
	Etherwind, //netherstorm
}
BiomeWeights :: [Biome]u8
BiomeSpacesPerValues :: [Biome][3]f64 {
	.Crystalbloom = {0.1, 0.1, 0.1},
	.Gorglai      = {0.9, 0.1, 0.1},
	.Arakholm     = {0.1, 0.9, 0.1},
	.Merplia      = {0.9, 0.9, 0.1},
	.Wintercrown  = {0.1, 0.1, 0.9},
	.Scholathorn  = {0.9, 0.1, 0.9},
	.Adwaron      = {0.1, 0.9, 0.9},
	.Etherwind    = {0.9, 0.9, 0.9},
}

procedural_point_type_noise_result :: proc(x, y, z: i32, seed: u64, biome: Biome) -> f32 {


	FBM_SCALE :: .05
	fbm1 := algorithms.fbm_3d(
		f64(x) * FBM_SCALE,
		f64(y) * FBM_SCALE,
		f64(z) * FBM_SCALE,
		seed,
		2,
		.75,
		.5,
	)

	fbm2 := algorithms.fbm_3d(
		(f64(x) + 5.2) * FBM_SCALE,
		(f64(y) + 1.3) * FBM_SCALE,
		(f64(z << 2) + 2.6) * FBM_SCALE,
		seed,
		2,
		.5,
		.3,
	)

	return noise.noise_2d(transmute(i64)seed, {fbm1, fbm2})
	// noise += 1

	// assert(noise >= 0 && noise <= 2)
	// return noise
}
get_biome_selector :: proc(x, y, z: i32, seed: u64) -> f32 {
	return f32(
		algorithms.fbm_3d(
			f64(x) * 0.25,
			f64(y) * 0.25,
			f64(z) * 0.25,
			seed + 0x9E3779B9,
			2,
			0.55,
			0.65,
		),
	)
}
inv255 :: 1.0 / 255.0
when !VISUAL_REPRESENTATION_OF_NOISE_FN_RUN {
	procedural_point_type :: proc(
		points: ^[MAX_POINTS]u16,
		weights: BiomeWeights,
		worldXYZ: [3]i32,
		index: [3]i32,
		topY: i32,
		seed: u64,
	) {
		if points[index_into_point_arrays(index)] != 0 do return

		selector := get_biome_selector(index.x, index.y, index.z, seed)
		cumulator: f32 = 0
		for weight, biome in weights {
			if weight < MIN_BIOME_WEIGHT_TO_NOT_IGNORE do continue
			prob := f32(weight) * inv255
			cumulator += prob
			if selector < cumulator {
				biome_point(points, biome, worldXYZ, index, topY, seed)
				return
			}
		}
	}
}

get_major_biome :: proc(x, z: i32, seed: u64) -> Biome {
	res := get_biome_weights(x, z, seed)
	max: u8 = 0
	biome := Biome.Crystalbloom
	for score, b in res {
		if score > max {
			max = score
			biome = b
		}
	}
	return biome
}
get_biome_weights :: proc(x, z: i32, seed: u64) -> (biomeWeights: BiomeWeights) {
	HEIGHT_MAP_SCALE :: .0009

	ruggedness := algorithms.fbm_2d(
		f64(x) * HEIGHT_MAP_SCALE,
		f64(z) * HEIGHT_MAP_SCALE,
		seed,
		3,
		.5,
		.5,
	)

	curvature := algorithms.worley_2d(
		(f64(x) + 100.0) * HEIGHT_MAP_SCALE,
		(f64(z) + 100.0) * HEIGHT_MAP_SCALE,
		seed + 1,
	)

	verticality := algorithms.fbm_2d(
		(f64(x) + 200.0) * HEIGHT_MAP_SCALE,
		(f64(z) + 200.0) * HEIGHT_MAP_SCALE,
		seed + 2,
		3,
		.5,
		.5,
	)

	assert(ruggedness >= 0 && ruggedness <= 1)
	assert(curvature >= 0 && curvature <= 1)
	assert(verticality >= 0 && verticality <= 1)

	rgv := [3]f64{ruggedness, curvature, verticality}

	total: f32 = 0
	weightsF32 := [Biome]f32{}
	for biomeSpaceValue, biome in BiomeSpacesPerValues {
		diff := biomeSpaceValue - rgv
		diff *= diff
		dist2 := diff[0] + diff[1] + diff[2]

		inv: f32 = 1.0 / (f32(dist2) + 0.0001)
		w: f32 = inv * inv
		w *= w
		w *= w
		weightsF32[biome] = w
		total += w
	}

	assert(total > 0)
	floors := [Biome]int{}
	fracs := [Biome]f32{}
	accum := 0

	for biome in Biome {
		normalized := weightsF32[biome] / total
		scaled := normalized * 255.0
		floorVal := int(scaled)
		floors[biome] = floorVal
		fracs[biome] = scaled - f32(floorVal)
		biomeWeights[biome] = u8(floorVal)
		accum += floorVal
	}

	remainder := 255 - accum
	if remainder > 0 {
		Entry :: struct {
			biome: Biome,
			frac:  f32,
		}
		entries := [len(Biome)]Entry{}
		for biome, i in Biome {
			entries[i] = Entry{biome, fracs[biome]}
		}
		slice.sort_by(entries[:], proc(a, b: Entry) -> bool {
			return a.frac > b.frac
		})
		for i := 0; i < remainder && i < len(entries); i += 1 {
			biomeWeights[entries[i].biome] += 1
		}
	}
	return biomeWeights
}

randomColorIndex := 0

RANDOM_CYAN_OPTIONS := [?]float4 {
	{0, 1, 1, 1},
	{0.1, 0.9, 0.9, 1},
	{0.2, 0.8, 0.9, 1},
	{0.1, 0.7, 0.8, 1},
	{0.3, 1, 0.9, 1},
	{0.2, 0.85, 0.95, 1},
}

RANDOM_GREEN_OPTIONS := [?]float4 {
	{0, 1, 0, 1},
	{0.1, 0.9, 0.1, 1},
	{0.2, 0.8, 0.2, 1},
	{0.1, 0.7, 0.15, 1},
	{0.3, 1, 0.3, 1},
	{0.15, 0.85, 0.2, 1},
}
// color_for_point_type :: proc(p: PointType) -> [4]f32 {
// 	switch p {
// 	case .Air:
// 		unreachable()
// 	case .YellowDirt:
// 		return {.5, .5, .5, .5}
// 	}
// 	return {1, 1, 1, 1}
// }
