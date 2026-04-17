package ui


import "../../modules/vma"
import "../gs"
import "../vkh"
import "base:runtime"
import "core:container/small_array"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import la "core:math/linalg"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import sdl "vendor:sdl3"
import stbImage "vendor:stb/image"
import vk "vendor:vulkan"


TextVertex :: struct {
	pos: [2]f32,
	uv:  [2]f32,
}


Glyph :: struct {
	id:               i32,
	x, y:             i32,
	width, height:    i32,
	xoffset, yoffset: i32,
	xadvance:         i32,
}
Kerning :: struct {
	first, second: i32,
	amount:        i32,
}
BMFont_Info :: struct {
	face: string,
	size: i32,
	// ... other fields if needed
}
BMFont_Common :: struct {
	lineHeight:     i32,
	base:           i32,
	scaleW, scaleH: i32,
	// pages, etc.
}
BMFont :: struct {
	info:     BMFont_Info,
	common:   BMFont_Common,
	pages:    []string,
	chars:    []Glyph,
	kernings: []Kerning,
	glyphMap: map[rune]Glyph,
	texture:  vkh.GPUTexture,
}
bmfont_json_load :: proc(
	path: string,
	cb: vk.CommandBuffer,
	alloc := context.allocator,
) -> (
	font: BMFont,
) {
	assert(os.exists(path))
	fileBytes, osErr := os.read_entire_file_from_path(path, context.temp_allocator)
	if osErr != nil do log.fatalf("[UI] error opening BMFONT JSON file: %s", os.error_string(osErr))
	when ODIN_DEBUG {
		parsed, jsonErr := json.parse(fileBytes, allocator = context.temp_allocator)
		if jsonErr != nil do log.fatalf("[UI] error parsing BMFONT json: %s", fmt.enum_value_to_string(jsonErr))
	}
	unmarshallErr := json.unmarshal(fileBytes, &font, allocator = context.temp_allocator)
	if unmarshallErr != nil do log.fatalf("[UI] error unmarshalling BMFONT json: %s", fmt.enum_value_to_string(unmarshallErr))
	assert(len(font.pages) > 0)
	pngPath := font.pages[0]
	dir := filepath.dir(path, context.temp_allocator)
	pngFinalPath, err := filepath.join({dir, pngPath}, context.temp_allocator)
	ensure(err == nil)
	pngFinalPathCString := strings.clone_to_cstring(pngFinalPath, context.temp_allocator)
	assert(os.exists(pngFinalPath))
	inputs: vkh.ImageLoaderInputs
	DESIRED_CHANNELS :: 4
	inputs.data = stbImage.load(
		pngFinalPathCString,
		&inputs.width,
		&inputs.height,
		nil,
		DESIRED_CHANNELS,
	)
	assert(inputs.data != nil)
	defer stbImage.image_free(inputs.data)
	inputs.magFilter = .LINEAR
	inputs.minFilter = .LINEAR
	inputs.channels = DESIRED_CHANNELS
	font.texture = vkh.load_image(inputs, cb)
	font.glyphMap = make(map[rune]Glyph, len(font.chars), alloc)
	for &g in font.chars {
		font.glyphMap[rune(g.id)] = g
	}
	return font
}
bmfont_destroy :: proc(f: BMFont) {
	delete(f.glyphMap)
	view := f.texture.descriptor.imageView
	if view != {} do vk.DestroyImageView(vkh.device, view, nil)
	sampler := f.texture.descriptor.sampler
	if sampler != {} do vk.DestroySampler(vkh.device, sampler, nil)
	image := f.texture.image
	if image != {} do vma.destroy_image(vkh.allocator, image, f.texture.allocation)
}

add_text :: proc(str: string, font: BMFont, fontSize: f32, posX, posY: f32, color: [4]f32) {
	assert(len(str) != 0)
	assert(font.info.size != 0)
	assert(font.glyphMap != nil)
	assert(fontSize != 0)
	assert(font.texture.id != VK_UI_DUMMY_TEXTURE_ID)
	for c in color do assert(c <= 1 && c >= 0)
	scale := fontSize / f32(font.info.size)
	penX := posX
	penY := posY
	prevId: i32 = -1
	batchIdx := -1
	batch: ^UIBatch
	for &b, i in small_array.slice(&vkUiBatches) {
		if b.mode == .Text && font.texture.id == b.textureID && b.color == color {
			batchIdx = i
			break
		}
	}
	if batchIdx == -1 {
		idx := small_array.len(vkUiBatches)
		small_array.append_elem(&vkUiBatches, UIBatch{})
		batch = small_array.get_ptr(&vkUiBatches, idx)
		batch.descriptor = font.texture.descriptor
		batch.color = color
		batch.mode = .Text
		batch.textureID = font.texture.id
		batchIdx = idx
	} else {
		batch = small_array.get_ptr(&vkUiBatches, batchIdx)
	}
	assert(batch != nil)
	when ODIN_DEBUG {
		_, found := font.glyphMap['?']
		assert(found)
	}
	batch.color = color
	batch.descriptor = font.texture.descriptor
	for r in str {
		if r == '\n' {
			penX = posX
			penY += f32(font.common.lineHeight) * scale
			continue
		}
		if r == ' ' || r == '\t' {
			penX += f32(font.common.base) * scale
			continue
		}
		glyph, glyphFound := font.glyphMap[rune(r)]
		if !glyphFound do glyph = font.glyphMap['?'] or_continue

		left := penX + f32(glyph.xoffset) * scale
		right := left + f32(glyph.width) * scale
		top := penY + f32(glyph.yoffset) * scale
		bottom := top + f32(glyph.height) * scale
		assert(font.common.scaleW != 0)
		assert(font.common.scaleH != 0)
		uvLeft := f32(glyph.x) / f32(font.common.scaleW)
		uvTop := f32(glyph.y + glyph.height) / f32(font.common.scaleH)
		uvBottom := f32(glyph.y) / f32(font.common.scaleH)
		uvRight := f32(glyph.x + glyph.width) / f32(font.common.scaleW)

		assert(left < right)
		assert(top < bottom)
		small_array.append(
			&batch.vertices,
			TextVertex{{left, bottom}, {uvLeft, uvTop}},
			TextVertex{{right, bottom}, {uvRight, uvTop}},
			TextVertex{{right, top}, {uvRight, uvBottom}},
			TextVertex{{left, bottom}, {uvLeft, uvTop}},
			TextVertex{{right, top}, {uvRight, uvBottom}},
			TextVertex{{left, top}, {uvLeft, uvBottom}},
		)
		penX += f32(glyph.xadvance) * scale
		if prevId >= 0 {
			keringAmount: i32 = 0
			for kering in font.kernings {
				if kering.first == prevId && kering.second == glyph.id {
					keringAmount = kering.amount
				}
			}
			penX += f32(keringAmount) * scale
		}
		prevId = glyph.id
	}
	assert(small_array.len(batch.vertices) > 0)

}

measure_text :: proc(str: string, font: BMFont, fontSize: f32) -> (width, height: f32) {
	assert(font.info.size != 0)
	assert(font.glyphMap != nil)
	assert(fontSize != 0)

	scale := fontSize / f32(font.info.size)
	lineHeight := f32(font.common.lineHeight) * scale


	penX: f32 = 0
	maxWidth: f32 = 0
	lineCount: int = 1
	prevId: i32 = -1


	for r in str {
		if r == '\n' {
			maxWidth = max(maxWidth, penX)
			penX = 0
			lineCount += 1
			prevId = -1
			continue
		}
		if r == ' ' || r == '\t' {
			penX += f32(font.common.base) * scale
			prevId = -1
			continue

		}
		glyph, glyphFound := font.glyphMap[r]
		if !glyphFound {
			glyph = font.glyphMap['?'] or_continue
		}

		if prevId >= 0 {
			for kerning in font.kernings {
				if kerning.first == prevId && kerning.second == glyph.id {
					penX += f32(kerning.amount) * scale
					break
				}
			}
		}
		penX += f32(glyph.xadvance) * scale
		prevId = glyph.id
	}

	maxWidth = max(maxWidth, penX)
	height = f32(lineCount) * lineHeight
	return maxWidth, height

}
