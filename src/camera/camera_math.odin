package camera

import "core:math"
import "core:math/linalg"

// World: +X right, +Y up, +Z forward (left-handed).
// Vulkan Y-flip is handled by negative viewport height in chunks-visuals.odin.

camera_view :: proc(pos, front: [3]f32) -> matrix[4, 4]f32 {
	right := linalg.normalize(linalg.cross(WORLD_UP, front))
	up    := linalg.normalize(linalg.cross(front, right))
	return matrix[4, 4]f32{
		right.x, right.y, right.z, -linalg.dot(right, pos),
		up.x,    up.y,    up.z,    -linalg.dot(up, pos),
		front.x, front.y, front.z, -linalg.dot(front, pos),
		0,       0,       0,        1,
	}
}

// fov_deg: vertical FOV in degrees. Depth range [0, 1] (Vulkan).
camera_proj :: proc(fov_deg, aspect, near, far: f32) -> matrix[4, 4]f32 {
	f := 1.0 / math.tan(fov_deg * linalg.RAD_PER_DEG * 0.5)
	return matrix[4, 4]f32{
		f / aspect, 0, 0,                      0,
		0,          f, 0,                      0,
		0,          0, far / (far - near),     -(near * far) / (far - near),
		0,          0, 1,                      0,
	}
}
