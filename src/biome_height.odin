package main
import "algorithms"
import "core:math"
biome_height :: proc(biome: Biome, x, z: i32, seed: u64) -> f32 {
	switch biome {
	case .Crystalbloom:
		return crystalbloom_height(x, z, seed)

	case .Gorglai:
		return gorglai_height(x, z, seed)


	case .Arakholm:
		return arakholm_height(x, z, seed)


	case .Merplia:
		return merplia_height(x, z, seed)


	case .Wintercrown:
		return wintercrown_height(x, z, seed)


	case .Scholathorn:
		return scholathorn_height(x, z, seed)


	case .Adwaron:
		return adwaron_height(x, z, seed)


	case .Etherwind:
		return etherwind_height(x, z, seed)

	}
	unreachable()
}

SamplePoints :: [16]f32
SamplePointsPerBiome := [Biome]SamplePoints {
	.Crystalbloom = {-3, -1, 2, -1, 5, 7, 5, 3, 1, -1, -5, -6, -4, -3, -2, 0},
	.Gorglai      = {0, -2, -3, -48, -4, -3, -2, 0, 5, 6, 5, 4, 75, 95, 0, -30},
	.Arakholm     = {-4, -8, -14, -8, -3, -5, -90, -5, -20, -5, -20, -60, 16, 0, -4, -10},
	.Merplia      = {0, 4, 1, 5, 0, 4, 1, 5, -6, -2, -6, -2, -4, 0, -4, 0},
	.Wintercrown  = {5, 15, -13, 0, 6, 75, 21, -10, -15, -7, 10, 14, 52, 0, -16, -8},
	.Scholathorn  = {-4, 7, -3, 8, -6, 4, -2, 12, -8, 13, -2, 4, -4, 0, -3, 8},
	.Adwaron      = [16]f32{5, -7, 7, -9, 9, -6, 7, -8, 9, -4, 10, -8, 3, -12, 11, -4},
	.Etherwind    = {
		MIN_Y,
		5,
		7,
		12,
		MIN_Y,
		MIN_Y,
		MIN_Y,
		4,
		10,
		12,
		8,
		MIN_Y,
		MIN_Y,
		MIN_Y,
		6,
		3,
	},
}
crystalbloom_height :: proc(x, z: i32, seed: u64) -> f32 {
	noise := algorithms.fbm_2d(f64(x) * .01, f64(z) * .01, seed, 4, .5, .5)
	indexFloat := noise * (len(SamplePoints) - 2)
	indexFloor := math.floor(indexFloat)
	percentOfFirstIndex := indexFloat - indexFloor
	percentOfSecondIndex := f32(1 - percentOfFirstIndex)
	firstValue := SamplePointsPerBiome[.Crystalbloom][int(indexFloor)]
	secondValue := SamplePointsPerBiome[.Crystalbloom][int(indexFloor) + 1]
	return f32(algorithms.lerp(firstValue, secondValue, f32(percentOfFirstIndex)))

}


gorglai_height :: proc(x, z: i32, seed: u64) -> f32 {
	noise := algorithms.fbm_2d(f64(x) * .005, f64(z) * .005, seed, 4, .5, .5)
	indexFloat := noise * (len(SamplePoints) - 2)
	indexFloor := math.floor(indexFloat)
	percentOfFirstIndex := indexFloat - indexFloor
	percentOfSecondIndex := f32(1 - percentOfFirstIndex)
	firstValue := SamplePointsPerBiome[.Gorglai][int(indexFloor)]
	secondValue := SamplePointsPerBiome[.Gorglai][int(indexFloor) + 1]
	return f32(algorithms.lerp(firstValue, secondValue, f32(percentOfFirstIndex)))
}

arakholm_height :: proc(x, z: i32, seed: u64) -> f32 {
	noise := algorithms.fbm_2d(f64(x) * .005, f64(z) * .005, seed, 4, .5, .5)
	indexFloat := noise * (len(SamplePoints) - 2)
	indexFloor := math.floor(indexFloat)
	percentOfFirstIndex := indexFloat - indexFloor
	percentOfSecondIndex := f32(1 - percentOfFirstIndex)
	firstValue := SamplePointsPerBiome[.Arakholm][int(indexFloor)]
	secondValue := SamplePointsPerBiome[.Arakholm][int(indexFloor) + 1]
	return f32(algorithms.lerp(firstValue, secondValue, f32(percentOfFirstIndex)))
}


merplia_height :: proc(x, z: i32, seed: u64) -> f32 {
	noise := algorithms.fbm_2d(f64(x) * .005, f64(z) * .005, seed, 4, .5, .5)
	indexFloat := noise * (len(SamplePoints) - 2)
	indexFloor := math.floor(indexFloat)
	percentOfFirstIndex := indexFloat - indexFloor
	percentOfSecondIndex := f32(1 - percentOfFirstIndex)
	firstValue := SamplePointsPerBiome[.Merplia][int(indexFloor)]
	secondValue := SamplePointsPerBiome[.Merplia][int(indexFloor) + 1]
	return f32(algorithms.lerp(firstValue, secondValue, f32(percentOfFirstIndex)))
}


wintercrown_height :: proc(x, z: i32, seed: u64) -> f32 {
	noise := algorithms.fbm_2d(f64(x) * .005, f64(z) * .005, seed, 4, .5, .5)
	indexFloat := noise * (len(SamplePoints) - 2)
	indexFloor := math.floor(indexFloat)
	percentOfFirstIndex := indexFloat - indexFloor
	percentOfSecondIndex := f32(1 - percentOfFirstIndex)
	firstValue := SamplePointsPerBiome[.Wintercrown][int(indexFloor)]
	secondValue := SamplePointsPerBiome[.Wintercrown][int(indexFloor) + 1]
	return f32(algorithms.lerp(firstValue, secondValue, f32(percentOfFirstIndex)))
}

scholathorn_height :: proc(x, z: i32, seed: u64) -> f32 {
	noise := algorithms.fbm_2d(f64(x) * .005, f64(z) * .005, seed, 4, .5, .5)
	indexFloat := noise * (len(SamplePoints) - 2)
	indexFloor := math.floor(indexFloat)
	percentOfFirstIndex := indexFloat - indexFloor
	percentOfSecondIndex := f32(1 - percentOfFirstIndex)
	firstValue := SamplePointsPerBiome[.Scholathorn][int(indexFloor)]
	secondValue := SamplePointsPerBiome[.Scholathorn][int(indexFloor) + 1]
	return f32(algorithms.lerp(firstValue, secondValue, f32(percentOfFirstIndex)))
}


adwaron_height :: proc(x, z: i32, seed: u64) -> f32 {
	noise := algorithms.fbm_2d(f64(x) * .005, f64(z) * .005, seed, 4, .5, .5)
	indexFloat := noise * (len(SamplePoints) - 2)
	indexFloor := math.floor(indexFloat)
	percentOfFirstIndex := indexFloat - indexFloor
	percentOfSecondIndex := f32(1 - percentOfFirstIndex)
	firstValue := SamplePointsPerBiome[.Adwaron][int(indexFloor)]
	secondValue := SamplePointsPerBiome[.Adwaron][int(indexFloor) + 1]
	return f32(algorithms.lerp(firstValue, secondValue, f32(percentOfFirstIndex)))
}

etherwind_height :: proc(x, z: i32, seed: u64) -> f32 {
	noise := algorithms.fbm_2d(f64(x) * .005, f64(z) * .005, seed, 4, .5, .5)
	indexFloat := noise * (len(SamplePoints) - 2)
	indexFloor := math.floor(indexFloat)
	percentOfFirstIndex := indexFloat - indexFloor
	percentOfSecondIndex := f32(1 - percentOfFirstIndex)
	firstValue := SamplePointsPerBiome[.Etherwind][int(indexFloor)]
	secondValue := SamplePointsPerBiome[.Etherwind][int(indexFloor) + 1]
	return f32(algorithms.lerp(firstValue, secondValue, f32(percentOfFirstIndex)))
}
