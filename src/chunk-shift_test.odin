package main

import "camera"
import "core:testing"

// ---- helpers ----------------------------------------------------------------

// Builds a chunks slice. Each chunk.pos = (grid - half) * stride so that
// xyzPrev == {0,0,0} when the camera is at cam_at({0,0,0}).
@(private = "file")
make_grid :: proc() -> (chunks: []^Chunk, store: []Chunk) {
	n := int(CHUNKS_PER_XZ_DIRECTION * CHUNKS_PER_Y_DIRECTION * CHUNKS_PER_XZ_DIRECTION)
	store = make([]Chunk, n)
	chunks = make([]^Chunk, n)
	half := [3]i32{CHUNKS_PER_XZ_DIRECTION / 2, CHUNKS_PER_Y_DIRECTION / 2, CHUNKS_PER_XZ_DIRECTION / 2}
	stride := [3]i32{CHUNK_STRIDE_XZ, CHUNK_STRIDE_Y, CHUNK_STRIDE_XZ}
	for x in i32(0) ..< CHUNKS_PER_XZ_DIRECTION {
		for y in i32(0) ..< CHUNKS_PER_Y_DIRECTION {
			for z in i32(0) ..< CHUNKS_PER_XZ_DIRECTION {
				i := rc_idx(x, y, z)
				store[i].pos = ([3]i32{x, y, z} - half) * stride
				chunks[i] = &store[i]
			}
		}
	}
	return
}

// Camera whose xyzCurr == given chunk coord.
@(private = "file")
cam_at :: proc(xyzChunk: [3]i32) -> camera.Camera {
	c: camera.Camera
	c.pos = {
		f32(xyzChunk.x) * f32(CHUNK_STRIDE_XZ) + 0.5,
		f32(xyzChunk.y) * f32(CHUNK_STRIDE_Y) + 0.5,
		f32(xyzChunk.z) * f32(CHUNK_STRIDE_XZ) + 0.5,
	}
	c.front = {0, 0, 1}
	c.fov = 45
	c.movementSpeed = 20
	c.mouseSensitivity = 0.2
	return c
}

// Counts how many chunks were passed to on_init; also sets chunk.pos so the
// final assert inside chunks_shift_per_player_movement passes.
@(private = "file")
_init_count: int

@(private = "file")
record_init :: proc(chunk: ^Chunk, pos: [3]i32) {
	_init_count += 1
	chunk.pos = pos
}

// Expected world pos for a chunk at grid slot (nx, ny, nz) after the camera
// moved to xyzCurr.
@(private = "file")
world_pos :: proc(xyzCurr: [3]i32, nx, ny, nz: i32) -> [3]i32 {
	half := [3]i32{CHUNKS_PER_XZ_DIRECTION / 2, CHUNKS_PER_Y_DIRECTION / 2, CHUNKS_PER_XZ_DIRECTION / 2}
	coord := xyzCurr + [3]i32{nx, ny, nz} - half
	return coord * [3]i32{CHUNK_STRIDE_XZ, CHUNK_STRIDE_Y, CHUNK_STRIDE_XZ}
}

// ---- tests ------------------------------------------------------------------

@(test)
test_shift_no_movement :: proc(t: ^testing.T) {
	chunks, store := make_grid()
	defer {delete(chunks); delete(store)}
	c := cam_at({0, 0, 0})
	_init_count = 0

	chunks_shift_per_player_movement(&c, chunks, record_init)

	testing.expect(t, _init_count == 0, "no init calls when stationary")
	// spot-check center pointer is unchanged
	testing.expect(
		t,
		chunks[rc_idx(CHUNKS_PER_XZ_DIRECTION / 2, CHUNKS_PER_Y_DIRECTION / 2, CHUNKS_PER_XZ_DIRECTION / 2)].pos == [3]i32{0, 0, 0},
		"center pos unchanged",
	)
}

@(test)
test_shift_x_positive :: proc(t: ^testing.T) {
	chunks, store := make_grid()
	defer {delete(chunks); delete(store)}
	c := cam_at({1, 0, 0})
	_init_count = 0

	chunks_shift_per_player_movement(&c, chunks, record_init)

	n := int(CHUNKS_PER_Y_DIRECTION * CHUNKS_PER_XZ_DIRECTION)
	testing.expectf(t, _init_count == n, "x+ init count: got %d want %d", _init_count, n)

	// old rc(1,y,z) is now at rc(0,y,z); its original pos.x was (1-2)*stride = -stride
	for y in i32(0) ..< CHUNKS_PER_Y_DIRECTION {
		for z in i32(0) ..< CHUNKS_PER_XZ_DIRECTION {
			testing.expectf(
				t,
				chunks[rc_idx(0, y, z)].pos.x == -CHUNK_STRIDE_XZ,
				"rc(0,%d,%d).pos.x: got %d want %d",
				y, z, chunks[rc_idx(0, y, z)].pos.x, -CHUNK_STRIDE_XZ,
			)
		}
	}
	// recycled column at x=4 gets new world pos from record_init
	for y in i32(0) ..< CHUNKS_PER_Y_DIRECTION {
		for z in i32(0) ..< CHUNKS_PER_XZ_DIRECTION {
			want := world_pos({1, 0, 0}, 4, y, z)
			testing.expectf(
				t,
				chunks[rc_idx(4, y, z)].pos == want,
				"rc(4,%d,%d).pos: got %v want %v", y, z, chunks[rc_idx(4, y, z)].pos, want,
			)
		}
	}
}

@(test)
test_shift_x_negative :: proc(t: ^testing.T) {
	chunks, store := make_grid()
	defer {delete(chunks); delete(store)}
	c := cam_at({-1, 0, 0})
	_init_count = 0

	chunks_shift_per_player_movement(&c, chunks, record_init)

	n := int(CHUNKS_PER_Y_DIRECTION * CHUNKS_PER_XZ_DIRECTION)
	testing.expectf(t, _init_count == n, "x- init count: got %d want %d", _init_count, n)

	// old rc(3,y,z) is now at rc(4,y,z); its original pos.x was (3-2)*stride = stride
	for y in i32(0) ..< CHUNKS_PER_Y_DIRECTION {
		for z in i32(0) ..< CHUNKS_PER_XZ_DIRECTION {
			testing.expectf(
				t,
				chunks[rc_idx(4, y, z)].pos.x == CHUNK_STRIDE_XZ,
				"rc(4,%d,%d).pos.x: got %d want %d",
				y, z, chunks[rc_idx(4, y, z)].pos.x, CHUNK_STRIDE_XZ,
			)
		}
	}
	// recycled column at x=0 gets new world pos
	for y in i32(0) ..< CHUNKS_PER_Y_DIRECTION {
		for z in i32(0) ..< CHUNKS_PER_XZ_DIRECTION {
			want := world_pos({-1, 0, 0}, 0, y, z)
			testing.expectf(
				t,
				chunks[rc_idx(0, y, z)].pos == want,
				"rc(0,%d,%d).pos: got %v want %v", y, z, chunks[rc_idx(0, y, z)].pos, want,
			)
		}
	}
}

@(test)
test_shift_y_positive :: proc(t: ^testing.T) {
	chunks, store := make_grid()
	defer {delete(chunks); delete(store)}
	c := cam_at({0, 1, 0})
	_init_count = 0

	chunks_shift_per_player_movement(&c, chunks, record_init)

	n := int(CHUNKS_PER_XZ_DIRECTION * CHUNKS_PER_XZ_DIRECTION)
	testing.expectf(t, _init_count == n, "y+ init count: got %d want %d", _init_count, n)

	// old rc(x,1,z) is now at rc(x,0,z); its original pos.y was 0
	for x in i32(0) ..< CHUNKS_PER_XZ_DIRECTION {
		for z in i32(0) ..< CHUNKS_PER_XZ_DIRECTION {
			testing.expectf(
				t,
				chunks[rc_idx(x, 0, z)].pos.y == 0,
				"rc(%d,0,%d).pos.y: got %d want 0", x, z, chunks[rc_idx(x, 0, z)].pos.y,
			)
		}
	}
	// recycled top slice at y=2 gets new world pos
	ny := CHUNKS_PER_Y_DIRECTION - 1
	for x in i32(0) ..< CHUNKS_PER_XZ_DIRECTION {
		for z in i32(0) ..< CHUNKS_PER_XZ_DIRECTION {
			want := world_pos({0, 1, 0}, x, ny, z)
			testing.expectf(
				t,
				chunks[rc_idx(x, ny, z)].pos == want,
				"rc(%d,%d,%d).pos: got %v want %v", x, ny, z, chunks[rc_idx(x, ny, z)].pos, want,
			)
		}
	}
}

@(test)
test_shift_y_negative :: proc(t: ^testing.T) {
	chunks, store := make_grid()
	defer {delete(chunks); delete(store)}
	c := cam_at({0, -1, 0})
	_init_count = 0

	chunks_shift_per_player_movement(&c, chunks, record_init)

	n := int(CHUNKS_PER_XZ_DIRECTION * CHUNKS_PER_XZ_DIRECTION)
	testing.expectf(t, _init_count == n, "y- init count: got %d want %d", _init_count, n)

	// old rc(x,1,z) is now at rc(x,2,z); its original pos.y was 0
	for x in i32(0) ..< CHUNKS_PER_XZ_DIRECTION {
		for z in i32(0) ..< CHUNKS_PER_XZ_DIRECTION {
			testing.expectf(
				t,
				chunks[rc_idx(x, 2, z)].pos.y == 0,
				"rc(%d,2,%d).pos.y: got %d want 0", x, z, chunks[rc_idx(x, 2, z)].pos.y,
			)
		}
	}
	// recycled bottom slice at y=0 gets new world pos
	for x in i32(0) ..< CHUNKS_PER_XZ_DIRECTION {
		for z in i32(0) ..< CHUNKS_PER_XZ_DIRECTION {
			want := world_pos({0, -1, 0}, x, 0, z)
			testing.expectf(
				t,
				chunks[rc_idx(x, 0, z)].pos == want,
				"rc(%d,0,%d).pos: got %v want %v", x, 0, z, chunks[rc_idx(x, 0, z)].pos, want,
			)
		}
	}
}

@(test)
test_shift_z_positive :: proc(t: ^testing.T) {
	chunks, store := make_grid()
	defer {delete(chunks); delete(store)}
	c := cam_at({0, 0, 1})
	_init_count = 0

	chunks_shift_per_player_movement(&c, chunks, record_init)

	n := int(CHUNKS_PER_XZ_DIRECTION * CHUNKS_PER_Y_DIRECTION)
	testing.expectf(t, _init_count == n, "z+ init count: got %d want %d", _init_count, n)

	// old rc(x,y,1) is now at rc(x,y,0); its original pos.z was (1-2)*stride = -stride
	for x in i32(0) ..< CHUNKS_PER_XZ_DIRECTION {
		for y in i32(0) ..< CHUNKS_PER_Y_DIRECTION {
			testing.expectf(
				t,
				chunks[rc_idx(x, y, 0)].pos.z == -CHUNK_STRIDE_XZ,
				"rc(%d,%d,0).pos.z: got %d want %d", x, y, chunks[rc_idx(x, y, 0)].pos.z, -CHUNK_STRIDE_XZ,
			)
		}
	}
	// recycled far slice at z=4 gets new world pos
	nz := CHUNKS_PER_XZ_DIRECTION - 1
	for x in i32(0) ..< CHUNKS_PER_XZ_DIRECTION {
		for y in i32(0) ..< CHUNKS_PER_Y_DIRECTION {
			want := world_pos({0, 0, 1}, x, y, nz)
			testing.expectf(
				t,
				chunks[rc_idx(x, y, nz)].pos == want,
				"rc(%d,%d,%d).pos: got %v want %v", x, y, nz, chunks[rc_idx(x, y, nz)].pos, want,
			)
		}
	}
}

@(test)
test_shift_z_negative :: proc(t: ^testing.T) {
	chunks, store := make_grid()
	defer {delete(chunks); delete(store)}
	c := cam_at({0, 0, -1})
	_init_count = 0

	chunks_shift_per_player_movement(&c, chunks, record_init)

	n := int(CHUNKS_PER_XZ_DIRECTION * CHUNKS_PER_Y_DIRECTION)
	testing.expectf(t, _init_count == n, "z- init count: got %d want %d", _init_count, n)

	// old rc(x,y,3) is now at rc(x,y,4); its original pos.z was (3-2)*stride = stride
	for x in i32(0) ..< CHUNKS_PER_XZ_DIRECTION {
		for y in i32(0) ..< CHUNKS_PER_Y_DIRECTION {
			testing.expectf(
				t,
				chunks[rc_idx(x, y, 4)].pos.z == CHUNK_STRIDE_XZ,
				"rc(%d,%d,4).pos.z: got %d want %d", x, y, chunks[rc_idx(x, y, 4)].pos.z, CHUNK_STRIDE_XZ,
			)
		}
	}
	// recycled near slice at z=0 gets new world pos
	for x in i32(0) ..< CHUNKS_PER_XZ_DIRECTION {
		for y in i32(0) ..< CHUNKS_PER_Y_DIRECTION {
			want := world_pos({0, 0, -1}, x, y, 0)
			testing.expectf(
				t,
				chunks[rc_idx(x, y, 0)].pos == want,
				"rc(%d,%d,0).pos: got %v want %v", x, y, 0, chunks[rc_idx(x, y, 0)].pos, want,
			)
		}
	}
}

@(test)
test_shift_xz_diagonal :: proc(t: ^testing.T) {
	chunks, store := make_grid()
	defer {delete(chunks); delete(store)}
	c := cam_at({1, 0, 1})
	_init_count = 0

	chunks_shift_per_player_movement(&c, chunks, record_init)

	// X column + Z slice, no double-counting
	want_count := int(CHUNKS_PER_Y_DIRECTION * CHUNKS_PER_XZ_DIRECTION + CHUNKS_PER_XZ_DIRECTION * CHUNKS_PER_Y_DIRECTION)
	testing.expectf(t, _init_count == want_count, "xz diagonal init count: got %d want %d", _init_count, want_count)
}

@(test)
test_shift_x_idempotent :: proc(t: ^testing.T) {
	// Shift +1 in X then -1: every pointer should be back in its original slot.
	chunks, store := make_grid()
	defer {delete(chunks); delete(store)}

	origPtrs := make([]^Chunk, len(chunks))
	copy(origPtrs, chunks)
	defer delete(origPtrs)

	c1 := cam_at({1, 0, 0})
	_init_count = 0
	chunks_shift_per_player_movement(&c1, chunks, record_init)

	// After the +1 shift, center chunk is now old rc(3,half.y,half.z).
	// Its pos was updated by record_init for the recycled column (rc(4,...)),
	// but the center rc(2,...) = old rc(3,...) still has its original pos.
	// Set center chunk pos so xyzPrev reads correctly for the reverse shift.
	half := [3]i32{CHUNKS_PER_XZ_DIRECTION / 2, CHUNKS_PER_Y_DIRECTION / 2, CHUNKS_PER_XZ_DIRECTION / 2}
	chunks[rc_idx(half.x, half.y, half.z)].pos = world_pos({1, 0, 0}, half.x, half.y, half.z)

	c2 := cam_at({0, 0, 0})
	_init_count = 0
	chunks_shift_per_player_movement(&c2, chunks, record_init)

	for i in 0 ..< len(chunks) {
		testing.expectf(t, chunks[i] == origPtrs[i], "pointer[%d] not restored after round-trip", i)
	}
}

@(test)
test_shift_x_positive_2 :: proc(t: ^testing.T) {
	chunks, store := make_grid()
	defer {delete(chunks); delete(store)}
	c := cam_at({2, 0, 0})
	_init_count = 0

	chunks_shift_per_player_movement(&c, chunks, record_init)

	n := int(2 * CHUNKS_PER_Y_DIRECTION * CHUNKS_PER_XZ_DIRECTION)
	testing.expectf(t, _init_count == n, "x+2 init count: got %d want %d", _init_count, n)

	// shifted: rc(0,y,z) = old rc(2,y,z), pos.x was 0
	for y in i32(0) ..< CHUNKS_PER_Y_DIRECTION {
		for z in i32(0) ..< CHUNKS_PER_XZ_DIRECTION {
			testing.expectf(t, chunks[rc_idx(0, y, z)].pos.x == 0,
				"rc(0,%d,%d).pos.x: got %d want 0", y, z, chunks[rc_idx(0, y, z)].pos.x)
		}
	}
	// recycled columns at x=3 and x=4 get new world pos
	for nx in i32(3) ..< CHUNKS_PER_XZ_DIRECTION {
		for y in i32(0) ..< CHUNKS_PER_Y_DIRECTION {
			for z in i32(0) ..< CHUNKS_PER_XZ_DIRECTION {
				want := world_pos({2, 0, 0}, nx, y, z)
				testing.expectf(t, chunks[rc_idx(nx, y, z)].pos == want,
					"rc(%d,%d,%d).pos: got %v want %v", nx, y, z, chunks[rc_idx(nx, y, z)].pos, want)
			}
		}
	}
}

@(test)
test_shift_x_negative_2 :: proc(t: ^testing.T) {
	chunks, store := make_grid()
	defer {delete(chunks); delete(store)}
	c := cam_at({-2, 0, 0})
	_init_count = 0

	chunks_shift_per_player_movement(&c, chunks, record_init)

	n := int(2 * CHUNKS_PER_Y_DIRECTION * CHUNKS_PER_XZ_DIRECTION)
	testing.expectf(t, _init_count == n, "x-2 init count: got %d want %d", _init_count, n)

	// shifted: rc(4,y,z) = old rc(2,y,z), pos.x was 0
	for y in i32(0) ..< CHUNKS_PER_Y_DIRECTION {
		for z in i32(0) ..< CHUNKS_PER_XZ_DIRECTION {
			testing.expectf(t, chunks[rc_idx(4, y, z)].pos.x == 0,
				"rc(4,%d,%d).pos.x: got %d want 0", y, z, chunks[rc_idx(4, y, z)].pos.x)
		}
	}
	// recycled columns at x=0 and x=1
	for nx in i32(0) ..< 2 {
		for y in i32(0) ..< CHUNKS_PER_Y_DIRECTION {
			for z in i32(0) ..< CHUNKS_PER_XZ_DIRECTION {
				want := world_pos({-2, 0, 0}, nx, y, z)
				testing.expectf(t, chunks[rc_idx(nx, y, z)].pos == want,
					"rc(%d,%d,%d).pos: got %v want %v", nx, y, z, chunks[rc_idx(nx, y, z)].pos, want)
			}
		}
	}
}

@(test)
test_shift_z_positive_2 :: proc(t: ^testing.T) {
	chunks, store := make_grid()
	defer {delete(chunks); delete(store)}
	c := cam_at({0, 0, 2})
	_init_count = 0

	chunks_shift_per_player_movement(&c, chunks, record_init)

	n := int(2 * CHUNKS_PER_XZ_DIRECTION * CHUNKS_PER_Y_DIRECTION)
	testing.expectf(t, _init_count == n, "z+2 init count: got %d want %d", _init_count, n)

	// shifted: rc(x,y,0) = old rc(x,y,2), pos.z was 0
	for x in i32(0) ..< CHUNKS_PER_XZ_DIRECTION {
		for y in i32(0) ..< CHUNKS_PER_Y_DIRECTION {
			testing.expectf(t, chunks[rc_idx(x, y, 0)].pos.z == 0,
				"rc(%d,%d,0).pos.z: got %d want 0", x, y, chunks[rc_idx(x, y, 0)].pos.z)
		}
	}
	// recycled far slices at z=3 and z=4
	for nz in i32(3) ..< CHUNKS_PER_XZ_DIRECTION {
		for x in i32(0) ..< CHUNKS_PER_XZ_DIRECTION {
			for y in i32(0) ..< CHUNKS_PER_Y_DIRECTION {
				want := world_pos({0, 0, 2}, x, y, nz)
				testing.expectf(t, chunks[rc_idx(x, y, nz)].pos == want,
					"rc(%d,%d,%d).pos: got %v want %v", x, y, nz, chunks[rc_idx(x, y, nz)].pos, want)
			}
		}
	}
}

@(test)
test_shift_z_negative_2 :: proc(t: ^testing.T) {
	chunks, store := make_grid()
	defer {delete(chunks); delete(store)}
	c := cam_at({0, 0, -2})
	_init_count = 0

	chunks_shift_per_player_movement(&c, chunks, record_init)

	n := int(2 * CHUNKS_PER_XZ_DIRECTION * CHUNKS_PER_Y_DIRECTION)
	testing.expectf(t, _init_count == n, "z-2 init count: got %d want %d", _init_count, n)

	// shifted: rc(x,y,4) = old rc(x,y,2), pos.z was 0
	for x in i32(0) ..< CHUNKS_PER_XZ_DIRECTION {
		for y in i32(0) ..< CHUNKS_PER_Y_DIRECTION {
			testing.expectf(t, chunks[rc_idx(x, y, 4)].pos.z == 0,
				"rc(%d,%d,4).pos.z: got %d want 0", x, y, chunks[rc_idx(x, y, 4)].pos.z)
		}
	}
	// recycled near slices at z=0 and z=1
	for nz in i32(0) ..< 2 {
		for x in i32(0) ..< CHUNKS_PER_XZ_DIRECTION {
			for y in i32(0) ..< CHUNKS_PER_Y_DIRECTION {
				want := world_pos({0, 0, -2}, x, y, nz)
				testing.expectf(t, chunks[rc_idx(x, y, nz)].pos == want,
					"rc(%d,%d,%d).pos: got %v want %v", x, y, nz, chunks[rc_idx(x, y, nz)].pos, want)
			}
		}
	}
}

@(test)
test_shift_y_positive_2 :: proc(t: ^testing.T) {
	chunks, store := make_grid()
	defer {delete(chunks); delete(store)}
	c := cam_at({0, 2, 0})
	_init_count = 0

	chunks_shift_per_player_movement(&c, chunks, record_init)

	n := int(2 * CHUNKS_PER_XZ_DIRECTION * CHUNKS_PER_XZ_DIRECTION)
	testing.expectf(t, _init_count == n, "y+2 init count: got %d want %d", _init_count, n)

	// shifted: rc(x,0,z) = old rc(x,2,z), pos.y was CHUNK_STRIDE_Y
	for x in i32(0) ..< CHUNKS_PER_XZ_DIRECTION {
		for z in i32(0) ..< CHUNKS_PER_XZ_DIRECTION {
			testing.expectf(t, chunks[rc_idx(x, 0, z)].pos.y == CHUNK_STRIDE_Y,
				"rc(%d,0,%d).pos.y: got %d want %d", x, z, chunks[rc_idx(x, 0, z)].pos.y, CHUNK_STRIDE_Y)
		}
	}
	// recycled top slices at y=1 and y=2
	for ny in i32(1) ..< CHUNKS_PER_Y_DIRECTION {
		for x in i32(0) ..< CHUNKS_PER_XZ_DIRECTION {
			for z in i32(0) ..< CHUNKS_PER_XZ_DIRECTION {
				want := world_pos({0, 2, 0}, x, ny, z)
				testing.expectf(t, chunks[rc_idx(x, ny, z)].pos == want,
					"rc(%d,%d,%d).pos: got %v want %v", x, ny, z, chunks[rc_idx(x, ny, z)].pos, want)
			}
		}
	}
}
