package camera

import "core:math"
import "core:testing"

// camera at origin looking +Z — the default orientation

@(test)
test_view_forward :: proc(t: ^testing.T) {
	view := camera_view({0, 0, 0}, {0, 0, 1})
	p := view * [4]f32{0, 0, 1, 1}
	testing.expect(t, eq(p.x, 0), "forward: x=0")
	testing.expect(t, eq(p.y, 0), "forward: y=0")
	testing.expect(t, eq(p.z, 1), "forward: z=1")
	testing.expect(t, eq(p.w, 1), "forward: w=1")
}

@(test)
test_view_right :: proc(t: ^testing.T) {
	// world +X should land at view +X
	view := camera_view({0, 0, 0}, {0, 0, 1})
	p := view * [4]f32{1, 0, 0, 1}
	testing.expect(t, eq(p.x, 1), "right: x=1")
	testing.expect(t, eq(p.y, 0), "right: y=0")
	testing.expect(t, eq(p.z, 0), "right: z=0")
}

@(test)
test_view_up :: proc(t: ^testing.T) {
	// world +Y should land at view +Y
	view := camera_view({0, 0, 0}, {0, 0, 1})
	p := view * [4]f32{0, 1, 0, 1}
	testing.expect(t, eq(p.x, 0), "up: x=0")
	testing.expect(t, eq(p.y, 1), "up: y=1")
	testing.expect(t, eq(p.z, 0), "up: z=0")
}

@(test)
test_view_translation :: proc(t: ^testing.T) {
	// camera at {3,2,1} looking +Z: world {3,2,6} → view {0,0,5}
	view := camera_view({3, 2, 1}, {0, 0, 1})
	p := view * [4]f32{3, 2, 6, 1}
	testing.expect(t, eq(p.x, 0), "translated: x=0")
	testing.expect(t, eq(p.y, 0), "translated: y=0")
	testing.expect(t, eq(p.z, 5), "translated: z=5")
}

@(test)
test_view_basis_orthonormal :: proc(t: ^testing.T) {
	// The 3x3 rotation part must be orthonormal: M*M^T = I
	view := camera_view({5, 3, -2}, {0.6, 0.0, 0.8})
	// dot of each row with itself = 1, with others = 0
	rx := [3]f32{view[0][0], view[1][0], view[2][0]}
	ry := [3]f32{view[0][1], view[1][1], view[2][1]}
	rz := [3]f32{view[0][2], view[1][2], view[2][2]}
	testing.expect(t, eq(dot3(rx, rx), 1), "row0 length=1")
	testing.expect(t, eq(dot3(ry, ry), 1), "row1 length=1")
	testing.expect(t, eq(dot3(rz, rz), 1), "row2 length=1")
	testing.expect(t, eq(dot3(rx, ry), 0), "row0.row1=0")
	testing.expect(t, eq(dot3(rx, rz), 0), "row0.row2=0")
	testing.expect(t, eq(dot3(ry, rz), 0), "row1.row2=0")
}

@(test)
test_proj_near_depth :: proc(t: ^testing.T) {
	near: f32 = 0.1
	far:  f32 = 1000.0
	proj := camera_proj(45, 16.0 / 9.0, near, far)
	clip := proj * [4]f32{0, 0, near, 1}
	testing.expect(t, eq(clip.z / clip.w, 0, 0.001), "near plane → ndc.z=0")
}

@(test)
test_proj_far_depth :: proc(t: ^testing.T) {
	near: f32 = 0.1
	far:  f32 = 1000.0
	proj := camera_proj(45, 16.0 / 9.0, near, far)
	clip := proj * [4]f32{0, 0, far, 1}
	testing.expect(t, eq(clip.z / clip.w, 1, 0.001), "far plane → ndc.z=1")
}

@(test)
test_proj_center_xy :: proc(t: ^testing.T) {
	proj := camera_proj(45, 16.0 / 9.0, 0.1, 1000.0)
	clip := proj * [4]f32{0, 0, 10, 1}
	testing.expect(t, eq(clip.x / clip.w, 0), "center: ndc.x=0")
	testing.expect(t, eq(clip.y / clip.w, 0), "center: ndc.y=0")
}

@(test)
test_proj_right_maps_positive_x :: proc(t: ^testing.T) {
	// a point to the right (+X) at z=1 → ndc.x > 0
	proj := camera_proj(45, 1.0, 0.1, 1000.0)
	clip := proj * [4]f32{0.5, 0, 1, 1}
	testing.expect(t, clip.x / clip.w > 0, "+X view → ndc.x > 0")
}

@(test)
test_proj_up_maps_positive_y :: proc(t: ^testing.T) {
	// a point above (+Y) at z=1 → ndc.y > 0 (before viewport flip)
	proj := camera_proj(45, 1.0, 0.1, 1000.0)
	clip := proj * [4]f32{0, 0.5, 1, 1}
	testing.expect(t, clip.y / clip.w > 0, "+Y view → ndc.y > 0")
}

@(private)
eq :: proc(a, b: f32, eps: f32 = 0.0001) -> bool {
	return math.abs(a - b) < eps
}

@(private)
dot3 :: proc(a, b: [3]f32) -> f32 {
	return a.x * b.x + a.y * b.y + a.z * b.z
}
