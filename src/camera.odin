package main
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

DEFAULT_SPEED :: 50
DEFAULT_FOV :: 45.0
DEFAULT_SENSITIVITY: f32 = 0.2


WORLD_UP: float3 : {0, 1, 0}

Camera :: struct {
	pos:              float3,
	front:            float3,
	up:               float3,
	right:            float3,
	yaw:              f32,
	pitch:            f32,
	movementSpeed:    f32,
	mouseSensitivity: f32,
	fov:              f32,
}

Camera_new :: proc(
	pos: float3 = {0.0, 0.0, 0},
	front: float3 = {0, 0, 1},
	up: float3 = {0.0, 1.0, 0.0},
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

	movementVector: float3 = {}
	normalizedFront := linalg.normalize(float3{c.front.x, 0, c.front.z})
	normalizedRight := linalg.normalize(float3{c.right.x, 0, c.right.z})

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

	delta := linalg.normalize(movementVector) * c.movementSpeed * f32(dt)
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
		f32(screenWidth) / f32(screenHeight),
		f32(near_plane),
		f32(far_plane),
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
//     aspect := f32(screenWidth) / f32(screenHeight)
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
aabb_vs_plane :: proc(min, max: float3, plane: float4) -> bool {
	n := plane.xyz
	d := plane.w

	p := float3{n.x >= 0 ? max.x : min.x, n.y >= 0 ? max.y : min.y, n.z >= 0 ? max.z : min.z}

	return linalg.dot(n, p) + d >= 0
}


is_chunk_in_camera_frustrum :: proc(pos: [2]i32, c: ^Camera) -> bool {
	min := float3{f32(pos[0]), f32(MIN_Y), f32(pos[1])}
	max := float3{f32((pos[0] + CHUNK_SIZE)), f32(MAX_Y), f32((pos[1] + CHUNK_SIZE))}

	view, proj := Camera_view_proj(c)
	vp := proj * view

	vp = linalg.transpose(vp)
	planes := [6]float4 {
		vp[3] + vp[0], // left
		vp[3] - vp[0], // right
		vp[3] + vp[1], // bottom
		vp[3] - vp[1], // top
		vp[3] + vp[2], // near
		vp[3] - vp[2], // far
	}
	for i in 0 ..< 6 {
		n := planes[i].xyz
		len := linalg.length(n)
		planes[i] /= len
	}
	for plane in planes {
		if !aabb_vs_plane(min, max, plane) {
			return false
		}
	}

	return true
}
