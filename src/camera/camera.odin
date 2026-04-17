package camera
import "../gs"
import "core:math"
import "core:math/linalg"
import sdl "vendor:sdl3"
CAMERA_MOVEMENT :: enum {
	FORWARD,
	BACKWARD,
	LEFT,
	RIGHT,
}

DEFAULT_YAW :: -90.0
DEFAULT_PITCH :: 0

DEFAULT_SPEED :: 20
DEFAULT_FOV :: 45.0
DEFAULT_SENSITIVITY: f32 = 0.2


WORLD_UP :: [3]f32{0, 1, 0}

Camera :: struct {
	pos:              [3]f32,
	front:            [3]f32,
	up:               [3]f32,
	right:            [3]f32,
	yaw:              f32,
	pitch:            f32,
	movementSpeed:    f32,
	mouseSensitivity: f32,
	fov:              f32,
}

Camera_new :: proc(
	pos: [3]f32 = {0.0, 0.0, 0},
	front: [3]f32 = {0, 0, 1},
	up: [3]f32 = {0.0, 1.0, 0.0},
	fov: f32 = DEFAULT_FOV,
) -> Camera {
	f := linalg.normalize(front)

	c := Camera {
		pos              = pos,
		front            = f,
		yaw              = math.atan2(f.z, f.x) / linalg.RAD_PER_DEG,
		pitch            = math.asin(f.y) / linalg.RAD_PER_DEG,
		movementSpeed    = DEFAULT_SPEED,
		mouseSensitivity = DEFAULT_SENSITIVITY,
		fov              = fov,
	}

	Camera_rotate(&c)
	return c
}
camera_process_keyboard_movement :: proc(c: ^Camera) {
	keys := sdl.GetKeyboardState(nil)

	movementVector: [3]f32 = {}
	normalizedFront := linalg.normalize([3]f32{c.front.x, 0, c.front.z})
	normalizedRight := linalg.normalize([3]f32{c.right.x, 0, c.right.z})

	if keys[sdl.Scancode.W] != false {
		movementVector += normalizedFront
	}
	if keys[sdl.Scancode.S] != false {
		movementVector -= normalizedFront
	}
	if keys[sdl.Scancode.A] != false {
		movementVector -= normalizedRight
	}
	if keys[sdl.Scancode.D] != false {
		movementVector += normalizedRight
	}

	if keys[sdl.Scancode.SPACE] != false {
		movementVector += WORLD_UP
	}
	if keys[sdl.Scancode.LALT] != false || keys[sdl.Scancode.RALT] != false {
		movementVector -= WORLD_UP
	}

	if linalg.length(movementVector) <= 0 do return

	delta := linalg.normalize(movementVector) * c.movementSpeed * f32(gs.dt)
	// fmt.println("movementVector", movementVector)
	c.pos += delta
}
Camera_process_mouse_movement :: proc(c: ^Camera, received_xOffset, received_yOffset: f32) {
	xOffset := received_xOffset * c.mouseSensitivity
	yOffset := -received_yOffset * c.mouseSensitivity

	c.yaw += xOffset
	c.pitch += yOffset

	c.pitch = math.clamp(c.pitch, -89.0, 89.0)
	Camera_rotate(c)
}

Camera_view_proj :: proc(c: ^Camera) -> (view, proj: matrix[4, 4]f32) {
	// fmt.println("c.front", c.front)
	// fmt.println("c.up", c.up)
	// fmt.println("c.right", c.right)
	// fmt.println("c.pos", c.pos)

	view = linalg.matrix4_look_at_f32(c.pos, c.pos + c.front, c.up, true)

	proj = linalg.matrix4_perspective_f32(
		c.fov,
		f32(gs.screenWidth) / f32(gs.screenHeight),
		f32(gs.nearPlane),
		f32(gs.farPlane),
		true,
	)
	// proj[1][1] *= -1

	return view, proj

}

@(private)
Camera_rotate :: proc(c: ^Camera) {
	assert(!(math.is_nan(c.yaw) || math.is_nan(c.pitch)), "Invalid camera rotation")
	for coord in c.front {
		assert(!math.is_nan(coord))
	}
	for coord in c.right {
		assert(!math.is_nan(coord))
	}

	assert(!(math.is_nan(c.front.x) || math.is_nan(c.pitch)), "Invalid camera rotation")

	c.front.x = math.cos(c.yaw * linalg.RAD_PER_DEG) * math.cos(c.pitch * linalg.RAD_PER_DEG)
	c.front.y = math.sin(c.pitch * linalg.RAD_PER_DEG)
	c.front.z = math.sin(c.yaw * linalg.RAD_PER_DEG) * math.cos(c.pitch * linalg.RAD_PER_DEG)
	c.front = linalg.normalize(c.front)
	c.right = linalg.normalize(linalg.cross(c.front, WORLD_UP))
	c.up = linalg.normalize(linalg.cross(c.right, c.front))
}

// frustum_from_camera :: proc(c: ^Camera) -> [6]Plane {
//     aspect := f32(gs.screenWidth) / f32(gs.screenHeight)
//     half_v_side := far_plane * math.tan_f32(c.fov * linalg.RAD_PER_DEG * 0.5)
//     half_h_side := half_v_side * aspect
//     front_mult_far := c.front * far_plane

//     near_center := c.pos + c.front * near_plane

//     return [6]Plane {
//         {near_center,      c.front},
//         {c.pos + front_mult_far, -c.front},
//         {c.pos,             linalg.normalize(linalg.cross(front_mult_far - c.right * half_h_side, c.up))},
//         {c.pos,             linalg.normalize(linalg.cross(c.up, front_mult_far + c.right * half_h_side))},
//         {c.pos,             linalg.normalize(linalg.cross(c.right, front_mult_far - c.up * half_v_side))},
//         {c.pos,             linalg.normalize(linalg.cross(front_mult_far + c.up * half_v_side, c.right))},
//     }
// }
aabb_vs_plane :: proc(min, max: [3]f32, plane: [4]f32) -> bool {
	n := plane.xyz
	d := plane.w

	p := [3]f32{n.x >= 0 ? max.x : min.x, n.y >= 0 ? max.y : min.y, n.z >= 0 ? max.z : min.z}

	return linalg.dot(n, p) + d >= 0
}
