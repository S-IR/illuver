package camera
import "core:math"
import "core:math/linalg"
Camera_assert :: proc(c: ^Camera) {
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

	assert(c.pitch >= -89.0 && c.pitch <= 89.0, " (pitch outside safe range [-89, 89])")
	assert(c.fov > 1.0 && c.fov < 179.0, " (FOV outside reasonable range)")
	assert(c.movementSpeed > 0.0, " (movementSpeed <= 0)")
	assert(c.mouseSensitivity > 0.0, " (mouseSensitivity <= 0)")

	EPS :: 0.0001
	assert(math.abs(linalg.length(c.front) - 1.0) < EPS, " (front is not normalized)")

	right := linalg.normalize(linalg.cross(WORLD_UP, c.front))
	up := linalg.normalize(linalg.cross(c.front, right))

	assert(math.abs(linalg.dot(c.front, right)) < EPS, " (front and right are not orthogonal)")
	assert(math.abs(linalg.dot(c.front, up)) < EPS, " (front and up are not orthogonal)")
	assert(math.abs(linalg.dot(right, up)) < EPS, " (right and up are not orthogonal)")

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
}
