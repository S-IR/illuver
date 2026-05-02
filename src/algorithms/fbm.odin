package algorithms
import "core:fmt"
import "core:math"
import "core:math/noise"
import "core:simd"
fbm_max_amplitude :: proc(octaves: int, gain: f64) -> f64 {
	if gain >= 1.0 {
		return f64(octaves) // shouldn't happen with sane gain
	}
	return (1.0 - math.pow(gain, f64(octaves))) / (1.0 - gain)
}

fbm_2d :: proc(x, y: f64, seed: u64, octaves: int, lacunarity, gain: f64) -> (res: f64) {
	sum: f64 = 0.0
	amplitude: f64 = 1.0
	frequency: f64 = 1.0
	maxValPossible: f64 = 0.0

	for i in 0 ..< octaves {
		maxValPossible += amplitude
		sum += amplitude * f64(noise.noise_2d(transmute(i64)seed, {x * frequency, y * frequency}))
		frequency *= lacunarity
		amplitude *= gain
	}

	sum /= maxValPossible
	res = (sum + 1.0) * 0.5
	assert(res >= 0 && res <= 1)
	return res
}

fbm_3d :: proc(x, y, z: f64, seed: u64, octaves: int, lacunarity, gain: f64) -> (res: f64) {
	sum: f64 = 0.0
	amplitude: f64 = 1.0
	frequency: f64 = 1.0
	maxValPossible: f64 = 0.0

	for i in 0 ..< octaves {
		maxValPossible += amplitude
		sum +=
			amplitude *
			f64(
				noise.noise_3d_improve_xz(
					transmute(i64)seed,
					{x * frequency, y * frequency, z * frequency},
				),
			)
		frequency *= lacunarity
		amplitude *= gain
	}

	sum /= maxValPossible
	res = (sum + 1.0) * 0.5
	assert(res >= 0 && res <= 1)
	return res
}
ridged_fbm_2d :: proc(x, y: f64, seed: u64, octaves: int, lacunarity, gain: f64) -> (res: f64) {
	OFFSET :: 1.0
	sum: f64 = 0.0
	amplitude: f64 = 1.0
	frequency: f64 = 1.0
	maxValPossible: f64 = 0.0

	for i in 0 ..< octaves {
		maxValPossible += 2.0 * amplitude
		n := f64(noise.noise_2d(transmute(i64)seed, {x * frequency, y * frequency}))
		signal := OFFSET - math.abs(n)
		sum += signal * amplitude
		frequency *= lacunarity
		amplitude *= gain
	}

	res = sum / maxValPossible
	assert(res >= 0 && res <= 1)
	return res
}


// ridged_fbm_3d :: proc(x, y, z: f64, seed: u64, octaves: int, lacunarity, gain: f64) -> (res: f64) {
// 	OFFSET :: 1.0
// 	RIDGE_GAIN :: 2.0

// 	sum: f64 = 0.0
// 	amplitude: f64 = 1.0
// 	frequency: f64 = 1.0
// 	weight: f64 = 1.0

// 	for i in 0 ..< octaves {
// 		n := f64(
// 			noise.noise_3d_improve_xz(
// 				transmute(i64)seed,
// 				{x * frequency, y * frequency, z * frequency},
// 			),
// 		)

// 		signal := OFFSET - math.abs(n)
// 		weight = math.clamp(signal * RIDGE_GAIN, 0.0, 1.0)
// 		signal *= signal
// 		signal *= weight

// 		sum += signal * amplitude

// 		frequency *= lacunarity
// 		amplitude *= gain
// 	}

// 	max_ampl := fbm_max_amplitude(octaves, gain)
// 	res = math.clamp(sum / max_ampl, 0.0, 1.0)
// 	assert(res >= 0 && res <= 1)
// 	return res
// }
// warped_fbm_2d :: proc(x, y: f64, seed: u64, octaves: int, lacunarity, gain: f64) -> (res: f64) {
// 	// Lower warp strength → much more predictable range

// 	qx := fbm_2d(x, y, seed, octaves, lacunarity, gain)
// 	qy := fbm_2d(x + 5.2, y + 1.3, seed, octaves, lacunarity, gain)

// 	rx := fbm_2d(x * qx + 1.7, y * qy + 9.2, seed, octaves, lacunarity, gain)
// 	ry := fbm_2d(x * qx + 8.3, y * qy + 2.8, seed, octaves, lacunarity, gain)


// 	res = fbm_2d(x * rx, y * ry, seed, octaves, lacunarity, gain)

// 	assert(res >= 0 && res <= 1)
// 	return res
// }

// warped_fbm_3d :: proc(x, y, z: f64, seed: u64, octaves: int, lacunarity, gain: f64) -> (res: f64) {
// 	WARP_SCALE :: 1.8

// 	qx := fbm_3d(x, y, z, seed, octaves, lacunarity, gain)
// 	qy := fbm_3d(x + 5.2, y + 1.3, z + 3.1, seed, octaves, lacunarity, gain)

// 	rx := fbm_3d(x * qx + 1.7, y * qy + 9.2, z + 0.9, seed, octaves, lacunarity, gain)
// 	ry := fbm_3d(x * qx + 8.3, y * qy + 2.8, z + 1.1, seed, octaves, lacunarity, gain)


// 	res = fbm_3d(x * rx, y * ry, z + 1.6, seed, octaves, lacunarity, gain)
// 	assert(res >= 0 && res <= 1)
// 	return res
// }
lerp_scalar :: proc(a, b, t: f32) -> f32 {
	return a + (b - a) * t
}
lerp_simd :: proc(a, b, t: #simd[8]f32) -> #simd[8]f32 {
	return a + (b - a) * t
}
lerp :: proc {
	lerp_scalar,
	lerp_simd,
}
lerp_i32 :: proc(a, b: i32, t: f32) -> i32 {
	return i32(f32(a) + (f32(b) - f32(a)) * t)
}
