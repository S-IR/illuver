package ui
import "../vkh"
import "core:container/small_array"
add_image :: proc(x, y, w, h: f32, texture: vkh.GPUTexture, tint := [4]f32{1, 1, 1, 1}) {
	assert(w > 0 && h > 0)
	assert(texture.id != VK_UI_DUMMY_TEXTURE_ID)

	batchIdx := -1
	for &b, i in small_array.slice(&vkUiBatches) {
		if b.mode == .Image && b.textureID == texture.id && b.color == tint {
			batchIdx = i
			break
		}
	}
	b: ^UIBatch

	if batchIdx == -1 {
		idx := small_array.len(vkUiBatches)
		small_array.append_elem(&vkUiBatches, UIBatch{})
		b = small_array.get_ptr(&vkUiBatches, idx)

		b.descriptor = texture.descriptor
		b.textureID = texture.id
		b.color = tint
		b.mode = .Image
		batchIdx = idx

	} else {
		b = small_array.get_ptr(&vkUiBatches, batchIdx)
	}

	left := x
	right := x + w
	top := y
	bottom := y + h


	uvLeft: f32 = 0.0
	uvRight: f32 = 1.0
	uvTop: f32 = 0.0
	uvBottom: f32 = 1.0

	small_array.append(
		&b.vertices,
		TextVertex{{left, bottom}, {uvLeft, uvBottom}},
		TextVertex{{right, bottom}, {uvRight, uvBottom}},
		TextVertex{{right, top}, {uvRight, uvTop}},
		TextVertex{{left, bottom}, {uvLeft, uvBottom}},
		TextVertex{{right, top}, {uvRight, uvTop}},
		TextVertex{{left, top}, {uvLeft, uvTop}},
	)

}
