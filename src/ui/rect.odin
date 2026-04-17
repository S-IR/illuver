package ui
import "../gs"
import "core:container/small_array"
add_rect :: proc(x, y, w, h: f32, color: [4]f32) {
	assert(w > 0)
	assert(h > 0)
	for c in color do assert(c <= 1 && c >= 0)

	batchIdx := -1

	for &b, i in small_array.slice(&vkUiBatches) {
		if b.mode == .Solid && b.textureID == VK_UI_DUMMY_TEXTURE_ID && b.color == color {
			batchIdx = i
			break
		}
	}
	b: ^UIBatch

	if batchIdx == -1 {
		idx := small_array.len(vkUiBatches)
		small_array.append_elem(&vkUiBatches, UIBatch{})
		b = small_array.get_ptr(&vkUiBatches, idx)
		b.descriptor = vkDummyTexture.descriptor
		b.textureID = VK_UI_DUMMY_TEXTURE_ID
		b.color = color
		b.mode = .Solid
		batchIdx = idx
	} else {
		b = small_array.get_ptr(&vkUiBatches, batchIdx)
	}
	assert(batchIdx != -1)

	left := x
	right := x + w
	top := y
	bottom := y + h

	wnd := f32(gs.screenWidth)
	hnd := f32(gs.screenHeight)


	small_array.append(
		&b.vertices,
		TextVertex{{left, bottom}, {}},
		TextVertex{{right, bottom}, {}},
		TextVertex{{right, top}, {}},
		TextVertex{{left, bottom}, {}},
		TextVertex{{right, top}, {}},
		TextVertex{{left, top}, {}},
	)
	assert(small_array.len(b.vertices) > 0)

}
