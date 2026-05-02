package main
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
	.Crystalbloom = {0.35, 0.35, 0.35},
	.Gorglai      = {0.65, 0.35, 0.35},
	.Arakholm     = {0.35, 0.65, 0.35},
	.Merplia      = {0.65, 0.65, 0.35},
	.Wintercrown  = {0.35, 0.35, 0.65},
	.Scholathorn  = {0.65, 0.35, 0.65},
	.Adwaron      = {0.35, 0.65, 0.65},
	.Etherwind    = {0.65, 0.65, 0.65},
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
	ruggedness1 := algorithms.fbm_2d(
		f64(x) * HEIGHT_MAP_SCALE,
		f64(z) * HEIGHT_MAP_SCALE,
		seed,
		3,
		.5,
		.5,
	)
	ruggedness2 := algorithms.fbm_2d(
		(f64(x) + 2.3) * HEIGHT_MAP_SCALE,
		(f64(z) + 4.1) * HEIGHT_MAP_SCALE,
		seed,
		3,
		.75,
		.3,
	)

	assert(ruggedness1 >= 0 && ruggedness1 <= 1)
	assert(ruggedness2 >= 0 && ruggedness2 <= 1)

	ruggedness := algorithms.fbm_2d(ruggedness1, ruggedness2, seed, 1, .5, .3)
	assert(ruggedness >= 0 && ruggedness <= 1)


	curvature1 := algorithms.worley_2d(
		(f64(x) + 10.2) * HEIGHT_MAP_SCALE,
		(f64(z) + 0.5) * HEIGHT_MAP_SCALE,
		seed,
	)
	curvature2 := algorithms.worley_2d(
		(f64(x) + 2.3) * HEIGHT_MAP_SCALE,
		(f64(z) + 4.1) * HEIGHT_MAP_SCALE,
		seed,
	)

	assert(curvature1 >= 0 && curvature1 <= 1)
	assert(curvature2 >= 0 && curvature2 <= 1)


	curvature := algorithms.fbm_2d(ruggedness1, curvature2, seed, 1, .3, .5)

	assert(curvature >= 0 && curvature <= 1)

	verticality1 := algorithms.fbm_2d(
		f64(f64(x) + 2.4) * HEIGHT_MAP_SCALE,
		f64(f64(z) + 3.1) * HEIGHT_MAP_SCALE,
		seed,
		3,
		.5,
		.5,
	)
	verticality2 := curvature2

	assert(verticality1 >= 0 && verticality1 <= 1)
	assert(verticality2 >= 0 && verticality2 <= 1)

	verticality := algorithms.worley_2d(verticality1, verticality2, seed)
	assert(verticality >= 0 && verticality <= 1)


	rgv := [3]f64{ruggedness, curvature, verticality}
	SHARPNESS :: 4.0

	// totalWeight := 0
	total: f32 = 0
	weightsF32 := [Biome]f32{}
	for biomeSpaceValue, biome in BiomeSpacesPerValues {
		diff := biomeSpaceValue - rgv
		diff *= diff
		dist2 := diff[0] + diff[1] + diff[2]

		inv: f32 = 1.0 / (f32(dist2) + 0.0001)
		w: f32 = inv * inv // SHARPNESS = 2
		w *= w // SHARPNESS = 4
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
		// Build list of (biome, fractional part) for sorting
		Entry :: struct {
			biome: Biome,
			frac:  f32,
		}
		entries := [len(Biome)]Entry{}
		// defer delete(entries)

		for biome, i in Biome {
			entries[i] = Entry{biome, fracs[biome]}
		}

		// Sort descending by fractional part (highest remainder first)
		slice.sort_by(entries[:], proc(a, b: Entry) -> bool {
			return a.frac > b.frac
		})

		// Give the +1 to the top `remainder` biomes
		for i := 0; i < remainder && i < len(entries); i += 1 {
			biomeWeights[entries[i].biome] += 1
		}
	}
	return biomeWeights
	// v = (v + 1.0) * 0.5

	// forest := clamp(1.0 - abs(v - 0.2) * 4.0, 0.0, 1.0)
	// crystal := clamp(1.0 - abs(v - 0.5) * 4.0, 0.0, 1.0)
	// mountain := clamp(1.0 - abs(v - 0.8) * 4.0, 0.0, 1.0)

	// sum := forest + crystal + mountain
	// if sum == 0 {
	// 	return Biome{255, 0, 0}
	// }

	// forest /= sum
	// crystal /= sum
	// mountain /= sum

	// wf := u8(forest * 255.0)
	// wc := u8(crystal * 255.0)
	// wm := 255 - wf - wc

	// return Biome{wf, wc, wm}
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
