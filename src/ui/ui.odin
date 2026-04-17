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

UIBatchMode :: enum (u32) {
	Solid,
	Text,
	Image,
}

//u32 for glsl
#assert(size_of(UIBatchMode) == size_of(u32))

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
vkDummyTexture: vkh.GPUTexture
ui_create_dummy_texture :: proc(cb: vk.CommandBuffer) {
	// 1x1 white RGBA
	data := [4]u8{255, 255, 255, 255}
	inputs: vkh.ImageLoaderInputs
	inputs.data = raw_data(data[:])
	inputs.width = 1
	inputs.height = 1
	inputs.channels = 4
	inputs.magFilter = .NEAREST
	inputs.minFilter = .NEAREST
	vkDummyTexture = vkh.load_image(inputs, cb, false)
	vkDummyTexture.id = VK_UI_DUMMY_TEXTURE_ID
}
// vkTextFonts: small_array.Small_Array(MAX_TEXT_FONTS, UIBatch)
vkUIVertexBuffers: [vkh.MAX_FRAMES_IN_FLIGHT]vkh.VkBufferPoolElem
init :: proc(cb: vk.CommandBuffer) -> (p: vkh.PipelineData) {
	ui_create_dummy_texture(cb)

	for &bufferElem in vkUIVertexBuffers {
		vkh.chk(
			vma.create_buffer(
				vkh.allocator,
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
	vkh.chk(
		vk.CreateDescriptorSetLayout(
			vkh.device,
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
	vkh.chk(
		vk.CreatePipelineLayout(
			vkh.device,
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

	VERT_SPV :: #load("../../build/shader-binaries/ui.vertex.spv")
	FRAG_SPV :: #load("../../build/shader-binaries/ui.fragment.spv")

	vertModule := vkh.create_shader_module(vkh.device, VERT_SPV)
	fragModule := vkh.create_shader_module(vkh.device, FRAG_SPV)
	defer vk.DestroyShaderModule(vkh.device, vertModule, nil)
	defer vk.DestroyShaderModule(vkh.device, fragModule, nil)
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
			pColorAttachmentFormats = &vkh.swapchainImageFormat,
			depthAttachmentFormat = vkh.depthFormat,
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
	vkh.chk(vk.CreateGraphicsPipelines(vkh.device, 0, 1, &pipelineCi, nil, &p.graphicsPipeline))
	return p
}
frame_reset :: proc() {
	small_array.clear(&vkUiBatches)
}

render :: proc(cb: vk.CommandBuffer, uiP: vkh.PipelineData) {
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
	vkUIVertexBuffer := vkUIVertexBuffers[vkh.frameIndex].buffer
	vkUIVertexAlloc := vkUIVertexBuffers[vkh.frameIndex].alloc

	vk.CmdBindVertexBuffers(cb, 0, 1, &vkUIVertexBuffer, &offset)
	// Map once
	ptr: rawptr
	vkh.chk(vma.map_memory(vkh.allocator, vkUIVertexAlloc, &ptr))
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
		basePtr = mem.ptr_offset(basePtr, int(count))
		runningOffset += count
	}
	vma.unmap_memory(vkh.allocator, vkUIVertexAlloc)
	for &batch, idx in small_array.slice(&vkUiBatches) {
		assert(batch.vertexCount > 0)
		// if batch.vertexCount == 0 do continue
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
			pxRange = 1,
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
destroy :: proc(textP: vkh.PipelineData) {
	for vkUIVertexBuffer in vkUIVertexBuffers {
		if vkUIVertexBuffer.buffer != {} {
			vma.destroy_buffer(vkh.allocator, vkUIVertexBuffer.buffer, vkUIVertexBuffer.alloc)
		}
	}

	if textP.graphicsPipeline != {} {
		vk.DestroyPipeline(vkh.device, textP.graphicsPipeline, nil)
	}
	if textP.layout != {} {
		vk.DestroyPipelineLayout(vkh.device, textP.layout, nil)
	}
	if textP.descriptorSetLayout != {} {
		vk.DestroyDescriptorSetLayout(vkh.device, textP.descriptorSetLayout, nil)
	}
	vkh.gpu_texture_destroy(vkDummyTexture)
}
