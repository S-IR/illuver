package camera
import "core:math"
import "core:math/linalg"
Camera_assert :: proc(c: ^Camera) {
	// 1. No NaNs anywhere
	assert(
		!math.is_nan(c.pos.x) && !math.is_nan(c.pos.y) && !math.is_nan(c.pos.z),
		" (position contains NaN)",
	)

	assert(!math.is_nan(c.yaw), " (yaw is NaN)")
	assert(!math.is_nan(c.pitch), " (pitch is NaN)")

	assert(
		!math.is_nan(c.front.x) && !math.is_nan(c.front.y) && !math.is_nan(c.front.z),
		" (front contains NaN)",
	)
	assert(
		!math.is_nan(c.right.x) && !math.is_nan(c.right.y) && !math.is_nan(c.right.z),
		" (right contains NaN)",
	)
	assert(
		!math.is_nan(c.up.x) && !math.is_nan(c.up.y) && !math.is_nan(c.up.z),
		" (up contains NaN)",
	)

	// 2. Reasonable scalar values
	assert(c.pitch >= -89.0 && c.pitch <= 89.0, " (pitch outside safe range [-89, 89])")
	assert(c.fov > 1.0 && c.fov < 179.0, " (FOV outside reasonable range)")
	assert(c.movementSpeed > 0.0, " (movementSpeed <= 0)")
	assert(c.mouseSensitivity > 0.0, " (mouseSensitivity <= 0)")

	// 3. All direction vectors are normalized (within floating-point tolerance)
	EPS :: 0.0001
	assert(math.abs(linalg.length(c.front) - 1.0) < EPS, " (front is not normalized)")
	assert(math.abs(linalg.length(c.right) - 1.0) < EPS, " (right is not normalized)")
	assert(math.abs(linalg.length(c.up) - 1.0) < EPS, " (up is not normalized)")

	// 4. Basis is orthonormal (mutually perpendicular)
	assert(math.abs(linalg.dot(c.front, c.right)) < EPS, " (front and right are not orthogonal)")
	assert(math.abs(linalg.dot(c.front, c.up)) < EPS, " (front and up are not orthogonal)")
	assert(math.abs(linalg.dot(c.right, c.up)) < EPS, " (right and up are not orthogonal)")

	// 5. Right-handed consistency (right should be cross(front, WORLD_UP))
	expected_right := linalg.normalize(linalg.cross(c.front, WORLD_UP))
	assert(
		linalg.length(c.right - expected_right) < EPS,
		" (right vector is inconsistent with front + WORLD_UP)",
	)

	// 6. Up consistency (derived from right × front)
	expected_up := linalg.normalize(linalg.cross(c.right, c.front))
	assert(
		linalg.length(c.up - expected_up) < EPS,
		" (up vector is inconsistent with right × front)",
	)

	// 7. Yaw/Pitch <-> front consistency (the spherical -> cartesian conversion must match)
	expected_front_x :=
		math.cos(c.yaw * linalg.RAD_PER_DEG) * math.cos(c.pitch * linalg.RAD_PER_DEG)
	expected_front_y := math.sin(c.pitch * linalg.RAD_PER_DEG)
	expected_front_z :=
		math.sin(c.yaw * linalg.RAD_PER_DEG) * math.cos(c.pitch * linalg.RAD_PER_DEG)
	expected_front := linalg.normalize(
		[3]f32{expected_front_x, expected_front_y, expected_front_z},
	)
	assert(
		linalg.length(c.front - expected_front) < EPS,
		" (front vector is inconsistent with current yaw/pitch)",
	)

	// Everything passed → camera is in a perfectly healthy state
}
