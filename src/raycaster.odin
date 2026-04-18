package main

import "camera"
import "core:math"
import "core:math/linalg"
import "core:simd"
import "core:sort"


raycast_get_viewed_point :: proc(
	origin: [3]f32,
	rayDir: [3]f32,
	currCamera: camera.Camera,
	isDroppingPoint: bool,
) -> (
	closestPoint: u16,
	closestPointPosition: [3]f32,
	found: bool,
) {
	assert(linalg.length(rayDir) > .99 && linalg.length(rayDir) < 1.01)

	RAYCAST_HIT_RADIUS :: 0.3
	RAYCAST_HIT_RADIUS_SQ :: RAYCAST_HIT_RADIUS * RAYCAST_HIT_RADIUS
	RAYCAST_STEP_SIZE :: 0.5
	RAYCAST_MAX_DISTANCE :: 64.0

	lastAirCoord: [3]f32 = {}
	for t: f32 = RAYCAST_STEP_SIZE; t < RAYCAST_MAX_DISTANCE; t += RAYCAST_STEP_SIZE {
		rayPos := origin + rayDir * t

		if rayPos.y < f32(MIN_Y) do break
		if rayPos.y >= f32(MAX_Y) do break

		gridPos := linalg.round(rayPos)
		point := get_point_at_world_pos(gridPos, currCamera)
		if point == 0 {
			lastAirCoord = point_real_world_position(gridPos)
			continue
		}

		actualPos := point_real_world_position(gridPos)
		toPoint := actualPos - rayPos
		distSq := toPoint.x * toPoint.x + toPoint.y * toPoint.y + toPoint.z * toPoint.z

		if distSq <= RAYCAST_HIT_RADIUS_SQ {
			if isDroppingPoint {
				if lastAirCoord == {} do return {}, {}, {}
				return 0, lastAirCoord, true
			}
			closestPoint = point
			closestPointPosition = actualPos
			found = true
			return
		}

	}
	return
}

compute_mouse_ray :: proc(
	mouseX, mouseY: f32,
	screenWidth, screenHeight: u32,
	view, proj: matrix[4, 4]f32,
) -> [3]f32 {

	ndcX := (2.0 * f32(mouseX) / f32(screenWidth)) - 1.0
	ndcY := 1.0 - (2.0 * f32(mouseY) / f32(screenHeight))

	inv := linalg.inverse(proj * view)

	near := float4{ndcX, ndcY, 0, 1}
	far := float4{ndcX, ndcY, 1, 1}

	nearW := inv * near
	farW := inv * far

	nearW.xyz /= nearW.w
	farW.xyz /= farW.w

	return linalg.normalize(farW.xyz - nearW.xyz)
}
