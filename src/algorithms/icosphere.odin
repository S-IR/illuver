package algorithms

import "base:runtime"
import "core:math"
import "core:math/linalg"

IcospherePrimitives :: struct {
	vertices: [dynamic][3]f32,
	indices:  [dynamic]u32,
}


generate_icosphere :: proc(
	radius: f32,
	depth: int,
	allocator := context.allocator,
) -> (
	ip: IcospherePrimitives,
) {
	assert(radius > 0)
	assert(depth > 0)


	phi := (1.0 * math.SQRT_FIVE) / 2.0
	a := 1.0 / math.sqrt(1.0 + phi * phi)
	c := a * phi
	cF32 := f32(c)
	aF32 := f32(a)
	baseVertices := [?][3]f32 {
		{-cF32, aF32, 0}, // 0
		{cF32, aF32, 0}, // 1
		{-cF32, -aF32, 0}, // 2
		{cF32, -aF32, 0}, // 3
		{0, -cF32, aF32}, // 4
		{0, cF32, aF32}, // 5
		{0, -cF32, -aF32}, // 6
		{0, cF32, -aF32}, // 7
		{aF32, 0, -cF32}, // 8
		{aF32, 0, cF32}, // 9
		{-aF32, 0, -cF32}, // 10
		{-aF32, 0, cF32}, // 11
	}

	baseIndices := [?]u32 {
		0,
		11,
		5,
		0,
		5,
		1,
		0,
		1,
		7,
		0,
		7,
		10,
		0,
		10,
		11,
		1,
		5,
		9,
		5,
		11,
		4,
		11,
		10,
		2,
		10,
		7,
		6,
		7,
		1,
		8,
		3,
		9,
		4,
		3,
		4,
		2,
		3,
		2,
		6,
		3,
		6,
		8,
		3,
		8,
		9,
		4,
		9,
		5,
		2,
		4,
		11,
		6,
		2,
		10,
		8,
		6,
		7,
		9,
		8,
		1,
	}

	ip.vertices = make([dynamic][3]f32, allocator)
	for v in baseVertices do append(&ip.vertices, v)

	ip.indices = make([dynamic]u32, allocator)
	for i in baseIndices do append(&ip.indices, i)

	for _ in 0 ..< depth {
		subdivide(&ip.vertices, &ip.indices, allocator)
	}

	if radius != 1.0 {
		for &v in ip.vertices do v *= radius
	}
	assert(len(ip.vertices) > 0)
	assert(len(ip.indices) > 0)

	return ip


	// append(&currentVertices, ..baseVertices[:])

}

@(private)
subdivide :: proc(
	vertices: ^[dynamic][3]f32,
	indices: ^[dynamic]u32,
	allocator: runtime.Allocator,
) {
	midCache := make(map[[3]f32]u32, len(indices), context.temp_allocator)

	newIndices := make([dynamic]u32, context.temp_allocator)

	for i := 0; i < len(indices); i += 3 {
		v1 := vertices[indices[i + 0]]
		v2 := vertices[indices[i + 1]]
		v3 := vertices[indices[i + 2]]


		m12 := linalg.vector_slerp(v1, v2, .5)
		m23 := linalg.vector_slerp(v2, v3, .5)
		m31 := linalg.vector_slerp(v3, v1, .5)


		i12 := get_or_add_mid(&midCache, vertices, m12)
		i23 := get_or_add_mid(&midCache, vertices, m23)
		i31 := get_or_add_mid(&midCache, vertices, m31)


		append(&newIndices, indices[i + 0], i12, i31)
		append(&newIndices, i12, indices[i + 1], i23)
		append(&newIndices, i31, i23, indices[i + 2])
		append(&newIndices, i12, i23, i31)

	}
	clear(indices)
	for idx in newIndices do append(indices, idx)

}

@(private)
get_or_add_mid :: proc(cache: ^map[[3]f32]u32, vertices: ^[dynamic][3]f32, p: [3]f32) -> u32 {

	dir := linalg.normalize(p)

	if idx, ok := cache[dir]; ok {
		return idx
	}
	newIdx := u32(len(vertices))

	append(vertices, dir)
	cache[dir] = newIdx
	return newIdx
}
