package main
cubeVertices := [8][3]i32 {
	{0.0, 0.0, 0.0}, // 0: front bottom left
	{0.0, 0.0, 1.0}, // 1: front bottom right
	{1.0, 0.0, 0.0}, // 2: front top right
	{1.0, 0.0, 1.0}, // 3: front top left
	{0.0, 1.0, 0.0}, // 4: back bottom left
	{0.0, 1.0, 1.0}, // 5: back bottom right
	{1.0, 1.0, 0.0}, // 6: back top right
	{1.0, 1.0, 1.0}, // 7: back top left
}

pointSimdLeftCoords := #simd[8]i32 {
	index_into_point_arrays_vector_contextless({-1, -1, -1}),
	index_into_point_arrays_vector_contextless({-1, 0, -1}),
	index_into_point_arrays_vector_contextless({-1, 1, -1}),
	index_into_point_arrays_vector_contextless({-1, -1, 0}),
	index_into_point_arrays_vector_contextless({-1, 1, 0}),
	index_into_point_arrays_vector_contextless({-1, -1, 1}),
	index_into_point_arrays_vector_contextless({-1, 0, 1}),
	index_into_point_arrays_vector_contextless({-1, 1, 1}),
}


chunkRightMostCoords := [8]i32 {
	index_into_point_arrays_vector_contextless({VERTS_PER_X_DIR - 1, -1, -1}),
	index_into_point_arrays_vector_contextless({VERTS_PER_X_DIR - 1, 0, -1}),
	index_into_point_arrays_vector_contextless({VERTS_PER_X_DIR - 1, 1, -1}),
	index_into_point_arrays_vector_contextless({VERTS_PER_X_DIR - 1, -1, 0}),
	index_into_point_arrays_vector_contextless({VERTS_PER_X_DIR - 1, 1, 0}),
	index_into_point_arrays_vector_contextless({VERTS_PER_X_DIR - 1, -1, 1}),
	index_into_point_arrays_vector_contextless({VERTS_PER_X_DIR - 1, 0, 1}),
	index_into_point_arrays_vector_contextless({VERTS_PER_X_DIR - 1, 1, 1}),
}
chunkNeighbourRightMostCoord := index_into_point_arrays_vector_contextless(
	{VERTS_PER_X_DIR - 1, 0, 0},
)


chunkLeftMostCoords := [8]i32 {
	index_into_point_arrays_vector_contextless({0, -1, -1}),
	index_into_point_arrays_vector_contextless({0, 0, -1}),
	index_into_point_arrays_vector_contextless({0, 1, -1}),
	index_into_point_arrays_vector_contextless({0, -1, 0}),
	index_into_point_arrays_vector_contextless({0, 1, 0}),
	index_into_point_arrays_vector_contextless({0, -1, 1}),
	index_into_point_arrays_vector_contextless({0, 0, 1}),
	index_into_point_arrays_vector_contextless({0, 1, 1}),
}
chunkNeighbourLeftMostCoord := index_into_point_arrays_vector_contextless({0, 0, 0})


pointSimdCenterCoords := #simd[8]i32 {
	index_into_point_arrays_vector_contextless({0, -1, -1}),
	index_into_point_arrays_vector_contextless({0, 0, -1}),
	index_into_point_arrays_vector_contextless({0, 1, -1}),
	index_into_point_arrays_vector_contextless({0, -1, 0}),
	index_into_point_arrays_vector_contextless({0, 1, 0}),
	index_into_point_arrays_vector_contextless({0, -1, 1}),
	index_into_point_arrays_vector_contextless({0, 0, 1}),
	index_into_point_arrays_vector_contextless({0, 1, 1}),
}

pointSimdRightCoords := #simd[8]i32 {
	index_into_point_arrays_vector_contextless({1, -1, -1}),
	index_into_point_arrays_vector_contextless({1, 0, -1}),
	index_into_point_arrays_vector_contextless({1, 1, -1}),
	index_into_point_arrays_vector_contextless({1, -1, 0}),
	index_into_point_arrays_vector_contextless({1, 1, 0}),
	index_into_point_arrays_vector_contextless({1, -1, 1}),
	index_into_point_arrays_vector_contextless({1, 0, 1}),
	index_into_point_arrays_vector_contextless({1, 1, 1}),
}
pointsNeighbourLeftCoords := index_into_point_arrays_vector_contextless({-1, 0, 0})
pointsNeighbourRightCoords := index_into_point_arrays_vector_contextless({1, 0, 0})

pointsSimdNeighbors := [3]#simd[8]i32 {
	pointSimdLeftCoords,
	pointSimdCenterCoords,
	pointSimdRightCoords,
}

cubeVertexLinearOffsets := #simd[8]i32 {
	index_into_point_arrays_vector_contextless(cubeVertices[0]),
	index_into_point_arrays_vector_contextless(cubeVertices[1]),
	index_into_point_arrays_vector_contextless(cubeVertices[2]),
	index_into_point_arrays_vector_contextless(cubeVertices[3]),
	index_into_point_arrays_vector_contextless(cubeVertices[4]),
	index_into_point_arrays_vector_contextless(cubeVertices[5]),
	index_into_point_arrays_vector_contextless(cubeVertices[6]),
	index_into_point_arrays_vector_contextless(cubeVertices[7]),
}

cubeVerticesX := #simd[8]i64{0, 1, 1, 0, 0, 1, 1, 0}
cubeVerticesY := #simd[8]i64{0, 0, 1, 1, 0, 0, 1, 1}
cubeVerticesZ := #simd[8]i64{1, 1, 1, 1, 0, 0, 0, 0}

cubeIndices := [36]u16 {
	// Front face
	0,
	1,
	2,
	0,
	2,
	3,
	// Back face
	5,
	4,
	7,
	5,
	7,
	6,
	// Right face
	1,
	5,
	6,
	1,
	6,
	2,
	// Left face
	4,
	0,
	3,
	4,
	3,
	7,
	// Top face
	3,
	2,
	6,
	3,
	6,
	7,
	// Bottom face
	4,
	5,
	1,
	4,
	1,
	0,
}
