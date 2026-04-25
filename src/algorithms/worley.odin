package algorithms
import "core:math"
import "core:math/noise"
import "core:simd"
hash2d :: proc(x, y: i64, seed: u64) -> u64 {
	h := u64(x) * 0x9E3779B185EBCA87 ~ u64(y) * 0xC2B2AE3D27D4EB4F ~ seed * 0x165667B19E3779F9
	h ~= h >> 30
	h *= 0xBF58476D1CE4E5B9
	h ~= h >> 27
	h *= 0x94D049BB133111EB
	h ~= h >> 31
	return h
}
hash3d :: proc(x, y, z: i64, seed: u64) -> u64 {
	h :=
		u64(x) * 0x9E3779B185EBCA87 ~
		u64(y) * 0xC2B2AE3D27D4EB4F ~
		u64(z) * 0xD2A98B26625EEE7B ~
		seed * 0x165667B19E3779F9
	h ~= h >> 30
	h *= 0xBF58476D1CE4E5B9
	h ~= h >> 27
	h *= 0x94D049BB133111EB
	h ~= h >> 31
	return h
}

rand3_from_u64 :: proc(h: u64) -> (rx, ry, rz: f64) {
	rx = rand_from_u64(h)
	ry = rand_from_u64(h >> 32)
	rz = rand_from_u64((h >> 16) ~ (h << 48))
	return
}
rand_from_u64 :: proc(h: u64) -> f64 {
	return f64(h & 0xFFFFFFFF) / f64(0xFFFFFFFF)
}

worley_2d_simd :: proc(x, y: #simd[8]f64, seed: u64) -> #simd[8]f64 {
	floorX := simd.floor(x)
	floorY := simd.floor(y)

	// Convert floored lanes to i64 cell coords via array
	cxBase := simd.to_array_ptr(&floorX)
	cyBase := simd.to_array_ptr(&floorY)

	minDist := #simd[8]f64{1e9, 1e9, 1e9, 1e9, 1e9, 1e9, 1e9, 1e9}

	for oy: i64 = -1; oy <= 1; oy += 1 {
		for ox: i64 = -1; ox <= 1; ox += 1 {
			fx: #simd[8]f64
			fy: #simd[8]f64
			for i in 0 ..< 8 {
				cx := i64(cxBase[i]) + ox
				cy := i64(cyBase[i]) + oy
				h := hash2d(cx, cy, seed)
				fx = simd.replace(fx, i, f64(cx) + rand_from_u64(h))
				fy = simd.replace(fy, i, f64(cy) + rand_from_u64(h >> 32))
			}

			dx := fx - x
			dy := fy - y
			dist := simd.sqrt(dx * dx + dy * dy)

			mask := simd.lanes_lt(dist, minDist)
			minDist = simd.min(dist, minDist)
		}
	}

	inv_diag := #simd[8]f64 {
		1.0 / 1.41421356237,
		1.0 / 1.41421356237,
		1.0 / 1.41421356237,
		1.0 / 1.41421356237,
		1.0 / 1.41421356237,
		1.0 / 1.41421356237,
		1.0 / 1.41421356237,
		1.0 / 1.41421356237,
	}
	return simd.clamp(
		minDist * inv_diag,
		#simd[8]f64{},
		#simd[8]f64{1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0},
	)
}

worley_2d :: proc(x, y: f64, seed: u64) -> f64 {
	cellX := i64(math.floor(x))
	cellY := i64(math.floor(y))
	minDist := f64(1e9)

	for oy: i64 = -1; oy <= 1; oy += 1 {
		for ox: i64 = -1; ox <= 1; ox += 1 {
			cx := cellX + ox
			cy := cellY + oy


			h := hash2d(cx, cy, seed)

			fx := f64(cx) + rand_from_u64(h)
			fy := f64(cy) + rand_from_u64(h >> 32)

			dx := fx - x
			dy := fy - y
			dist := math.sqrt(dx * dx + dy * dy)

			if dist < minDist {
				minDist = dist
			}

		}
	}
	return math.clamp(minDist / 1.41421356237, 0.0, 1.0)
}
worley_3d :: proc(x, y, z: f64, seed: u64) -> f64 {
	cellX := i64(math.floor(x))
	cellY := i64(math.floor(y))
	cellZ := i64(math.floor(z))
	minDist := f64(1e9)

	for oz: i64 = -1; oz <= 1; oz += 1 {
		for oy: i64 = -1; oy <= 1; oy += 1 {
			for ox: i64 = -1; ox <= 1; ox += 1 {
				cx := cellX + ox
				cy := cellY + oy
				cz := cellZ + oz
				h := hash3d(cx, cy, cz, seed)
				rx, ry, rz := rand3_from_u64(h)
				fx := f64(cx) + rx
				fy := f64(cy) + ry
				fz := f64(cz) + rz
				dx := fx - x
				dy := fy - y
				dz := fz - z
				dist := math.sqrt(dx * dx + dy * dy + dz * dz)
				if dist < minDist {
					minDist = dist
				}
			}
		}
	}

	return math.clamp(minDist / 1.73205080757, 0.0, 1.0)
}
