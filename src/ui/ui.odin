package ui

import "../modules/vma"
import "base:runtime"
import "core:container/small_array"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import la "core:math/linalg"
import "core:mem"
import os "core:os/os2"
import "core:path/filepath"
import "core:strings"
import sdl "vendor:sdl3"
import stbImage "vendor:stb/image"
import vk "vendor:vulkan"

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
	texture:  GPUTexture,
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
	pngFinalPath := filepath.join({dir, pngPath}, context.temp_allocator)
	pngFinalPathCString := strings.clone_to_cstring(pngFinalPath, context.temp_allocator)
	assert(os.exists(pngFinalPath))
	inputs: ImageLoaderInputs
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
	font.texture = load_gltf_image(inputs, cb)
	font.glyphMap = make(map[rune]Glyph, len(font.chars), alloc)
	for &g in font.chars {
		font.glyphMap[rune(g.id)] = g
	}
	return font
}
bmfont_destroy :: proc(f: BMFont) {
	delete(f.glyphMap)
	view := f.texture.descriptor.imageView
	if view != {} do vk.DestroyImageView(vkDevice, view, nil)
	sampler := f.texture.descriptor.sampler
	if sampler != {} do vk.DestroySampler(vkDevice, sampler, nil)
	image := f.texture.image
	if image != {} do vma.destroy_image(vkAllocator, image, f.texture.allocation)
}
TextVertex :: struct {
	pos: [2]f32,
	uv:  [2]f32,
}
UIBatchMode :: enum (u32) {
	Solid,
	Text,
}
UIPushConstants :: struct #align (16) {
	ortho:   matrix[4, 4]f32,
	color:   [4]f32,
	pxRange: f32,
	mode:    UIBatchMode, // 0 = solid, 1 = text
}
MAX_UI_BATCHES :: 64
MAX_UI_VERTS :: 4096 * 6
UIBatch :: struct {
	descriptor:  vk.DescriptorImageInfo,
	textureID:   u32,
	color:       [4]f32,
	mode:        UIBatchMode,
	vertices:    small_array.Small_Array(MAX_UI_VERTS, TextVertex),
	firstVertex: u32,
	vertexCount: u32,
}
MAX_TEXT_FONTS :: 5
VK_UI_DUMMY_TEXTURE_ID: u32 : 0
vkUiBatches: small_array.Small_Array(MAX_UI_BATCHES, UIBatch)
vkDummyTexture: GPUTexture
ui_create_dummy_texture :: proc(cb: vk.CommandBuffer) {
	// 1x1 white RGBA
	data := [4]u8{255, 255, 255, 255}
	inputs: ImageLoaderInputs
	inputs.data = raw_data(data[:])
	inputs.width = 1
	inputs.height = 1
	inputs.channels = 4
	inputs.magFilter = .NEAREST
	inputs.minFilter = .NEAREST
	vkDummyTexture = load_gltf_image(inputs, cb, false)
	vkDummyTexture.id = VK_UI_DUMMY_TEXTURE_ID
}
// vkTextFonts: small_array.Small_Array(MAX_TEXT_FONTS, UIBatch)
vkUIVertexBuffers: [MAX_FRAMES_IN_FLIGHT]gs.VkBufferPoolElem
vk_ui_init :: proc(cb: vk.CommandBuffer) -> (p: PipelineData) {
	ui_create_dummy_texture(cb)

	for &bufferElem in vkUIVertexBuffers {
		gs.vk_chk(
			vma.create_buffer(
				vkAllocator,
				{
					sType = .BUFFER_CREATE_INFO,
					size = vk.DeviceSize(MAX_UI_BATCHES * MAX_UI_VERTS * size_of(TextVertex)),
					usage = {.VERTEX_BUFFER},
				},
				{flags = {.Host_Access_Sequential_Write, .Mapped}, usage = .Auto},
				&bufferElem.buffer,
				&bufferElem.alloc,
				nil,
			),
		)

	}

	layoutBindings := [?]vk.DescriptorSetLayoutBinding {
		{
			binding = 0,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 1,
			stageFlags = {.FRAGMENT},
		},
	}
	gs.vk_chk(
		vk.CreateDescriptorSetLayout(
			vkDevice,
			&{
				sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
				bindingCount = len(layoutBindings),
				pBindings = raw_data(layoutBindings[:]),
				flags = {.PUSH_DESCRIPTOR_KHR},
			},
			nil,
			&p.descriptorSetLayout,
		),
	)
	assert(p.descriptorSetLayout != {})
	pushRange := [?]vk.PushConstantRange {
		{stageFlags = {.VERTEX, .FRAGMENT}, offset = 0, size = size_of(UIPushConstants)},
	}
	gs.vk_chk(
		vk.CreatePipelineLayout(
			vkDevice,
			&{
				sType = .PIPELINE_LAYOUT_CREATE_INFO,
				setLayoutCount = 1,
				pSetLayouts = &p.descriptorSetLayout,
				pushConstantRangeCount = len(pushRange),
				pPushConstantRanges = raw_data(pushRange[:]),
			},
			nil,
			&p.layout,
		),
	)
	assert(p.layout != {})
	vertexInputBindings := [?]vk.VertexInputBindingDescription {
		{binding = 0, stride = size_of(TextVertex), inputRate = .VERTEX},
	}
	vertexAttributes := [?]vk.VertexInputAttributeDescription {
		{location = 0, binding = 0, format = .R32G32_SFLOAT, offset = 0},
		{
			location = 1,
			binding = 0,
			format = .R32G32_SFLOAT,
			offset = u32(offset_of(TextVertex, uv)),
		},
	}
	dynamicStates := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
	VERT_SPV :: #load("../build/shader-binaries/ui.vertex.spv")
	FRAG_SPV :: #load("../build/shader-binaries/ui.fragment.spv")
	vertModule := create_shader_module(vkDevice, VERT_SPV)
	fragModule := create_shader_module(vkDevice, FRAG_SPV)
	defer vk.DestroyShaderModule(vkDevice, vertModule, nil)
	defer vk.DestroyShaderModule(vkDevice, fragModule, nil)
	shaderStages := [?]vk.PipelineShaderStageCreateInfo {
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.VERTEX},
			module = vertModule,
			pName = "main",
		},
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.FRAGMENT},
			module = fragModule,
			pName = "main",
		},
	}
	pipelineCi := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount          = len(shaderStages),
		pNext               = &vk.PipelineRenderingCreateInfo {
			sType = .PIPELINE_RENDERING_CREATE_INFO,
			colorAttachmentCount = 1,
			pColorAttachmentFormats = &swapchainImageFormat,
			depthAttachmentFormat = depthFormat,
		},
		pStages             = raw_data(shaderStages[:]),
		pVertexInputState   = &vk.PipelineVertexInputStateCreateInfo {
			sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
			vertexBindingDescriptionCount = len(vertexInputBindings),
			pVertexBindingDescriptions = raw_data(vertexInputBindings[:]),
			vertexAttributeDescriptionCount = len(vertexAttributes),
			pVertexAttributeDescriptions = raw_data(vertexAttributes[:]),
		},
		pInputAssemblyState = &vk.PipelineInputAssemblyStateCreateInfo {
			sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
			topology = .TRIANGLE_LIST,
		},
		pViewportState      = &vk.PipelineViewportStateCreateInfo {
			sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
			viewportCount = 1,
			scissorCount = 1,
		},
		pRasterizationState = &vk.PipelineRasterizationStateCreateInfo {
			sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
			polygonMode = .FILL,
			cullMode = {},
			frontFace = .COUNTER_CLOCKWISE,
			lineWidth = 1.0,
		},
		pMultisampleState   = &vk.PipelineMultisampleStateCreateInfo {
			sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
			rasterizationSamples = {._1},
		},
		pDepthStencilState  = &vk.PipelineDepthStencilStateCreateInfo {
			sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
			depthTestEnable = false,
			depthWriteEnable = false,
			depthCompareOp = .LESS_OR_EQUAL,
		},
		pColorBlendState    = &vk.PipelineColorBlendStateCreateInfo {
			sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
			logicOpEnable = false,
			attachmentCount = 1,
			pAttachments = &vk.PipelineColorBlendAttachmentState {
				blendEnable = true,
				srcColorBlendFactor = .SRC_ALPHA,
				dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
				colorBlendOp = .ADD,
				srcAlphaBlendFactor = .ONE,
				dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
				alphaBlendOp = .ADD,
				colorWriteMask = {.R, .G, .B, .A},
			},
		},
		pDynamicState       = &{
			sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
			dynamicStateCount = len(dynamicStates),
			pDynamicStates = raw_data(dynamicStates[:]),
		},
		layout              = p.layout,
		subpass             = 0,
	}
	gs.vk_chk(vk.CreateGraphicsPipelines(vkDevice, 0, 1, &pipelineCi, nil, &p.graphicsPipeline))
	return p
}
ui_frame_reset :: proc() {
	small_array.clear(&vkUiBatches)
}
ui_add_text :: proc(str: string, font: BMFont, fontSize: f32, posX, posY: f32, color: [4]f32) {
	assert(len(str) != 0)
	assert(font.info.size != 0)
	assert(font.glyphMap != nil)
	assert(fontSize != 0)
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
}
ui_render_ui :: proc(cb: vk.CommandBuffer, uiP: PipelineData) {
	if small_array.len(vkUiBatches) == 0 do return
	vk.CmdSetViewport(
		cb,
		0,
		1,
		&vk.Viewport {
			x = 0,
			y = 0,
			width = f32(gs.screenWidth),
			height = f32(gs.screenHeight),
			minDepth = 0,
			maxDepth = 1,
		},
	)
	vk.CmdSetScissor(
		cb,
		0,
		1,
		&vk.Rect2D{offset = {0, 0}, extent = {gs.screenWidth, gs.screenHeight}},
	)
	vk.CmdBindPipeline(cb, .GRAPHICS, uiP.graphicsPipeline)
	offset := vk.DeviceSize(0)
	vkUIVertexBuffer := vkUIVertexBuffers[frameIndex].buffer
	vkUIVertexAlloc := vkUIVertexBuffers[frameIndex].alloc

	vk.CmdBindVertexBuffers(cb, 0, 1, &vkUIVertexBuffer, &offset)
	// Map once
	ptr: rawptr
	gs.vk_chk(vma.map_memory(vkAllocator, vkUIVertexAlloc, &ptr))
	basePtr := (^TextVertex)(ptr)
	runningOffset: u32 = 0
	for &batch in small_array.slice(&vkUiBatches) {
		verts := small_array.slice(&batch.vertices)
		count := u32(len(verts))
		assert(count > 0)
		if count == 0 do continue
		batch.firstVertex = runningOffset
		batch.vertexCount = count
		mem.copy(basePtr, raw_data(verts), int(count) * size_of(TextVertex))
		basePtr = mem.ptr_offset(basePtr, int(count) * size_of(TextVertex))
		runningOffset += count
	}
	vma.unmap_memory(vkAllocator, vkUIVertexAlloc)
	for &batch in small_array.slice(&vkUiBatches) {
		assert(batch.vertexCount > 0)
		if batch.vertexCount == 0 do continue
		vk.CmdPushDescriptorSetKHR(
			cb,
			.GRAPHICS,
			uiP.layout,
			0,
			1,
			&vk.WriteDescriptorSet {
				sType = .WRITE_DESCRIPTOR_SET,
				dstBinding = 0,
				descriptorCount = 1,
				descriptorType = .COMBINED_IMAGE_SAMPLER,
				pImageInfo = &batch.descriptor,
			},
		)
		ortho := matrix[4, 4]f32{
			2.0 / f32(gs.screenWidth), 0, 0, -1.0,
			0, 2.0 / f32(gs.screenHeight), 0, -1.0,
			0, 0, -1.0, 0,
			0, 0, 0, 1,
		}

		push := UIPushConstants {
			ortho   = ortho,
			color   = batch.color,
			pxRange = 2.0,
			mode    = batch.mode,
		}
		vk.CmdPushConstants(
			cb,
			uiP.layout,
			{.VERTEX, .FRAGMENT},
			0,
			size_of(UIPushConstants),
			&push,
		)
		assert(batch.vertexCount > 0)
		vk.CmdDraw(cb, batch.vertexCount, 1, batch.firstVertex, 0)
	}
}
vk_ui_destroy :: proc(textP: PipelineData) {
	for vkUIVertexBuffer in vkUIVertexBuffers {
		if vkUIVertexBuffer.buffer != {} {
			vma.destroy_buffer(vkAllocator, vkUIVertexBuffer.buffer, vkUIVertexBuffer.alloc)
		}
	}

	if textP.graphicsPipeline != {} {
		vk.DestroyPipeline(vkDevice, textP.graphicsPipeline, nil)
	}
	if textP.layout != {} {
		vk.DestroyPipelineLayout(vkDevice, textP.layout, nil)
	}
	if textP.descriptorSetLayout != {} {
		vk.DestroyDescriptorSetLayout(vkDevice, textP.descriptorSetLayout, nil)
	}
	if vkDummyTexture.descriptor.imageView != {} do vk.DestroyImageView(vkDevice, vkDummyTexture.descriptor.imageView, nil)
	if vkDummyTexture.descriptor.sampler != {} do vk.DestroySampler(vkDevice, vkDummyTexture.descriptor.sampler, nil)
	if vkDummyTexture.image != {} do vma.destroy_image(vkAllocator, vkDummyTexture.image, vkDummyTexture.allocation)
}
