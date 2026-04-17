package main
import "../modules/vma"
import "algorithms"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "gs"
import vk "vendor:vulkan"
import "vkh"
HighlightSphere :: struct {
	pipeline:     vkh.PipelineData,
	vertexBuffer: vkh.VkBufferPoolElem,
	indexBuffer:  vkh.VkBufferPoolElem,
	indexCount:   u32,
}


highlight_sphere_init :: proc() -> (h: HighlightSphere) {
	h.pipeline = highlight_sphere_pipeline_init()

	spherePrimitives := algorithms.generate_icosphere(.25, 1, context.temp_allocator)
	assert(len(spherePrimitives.indices) > 0)
	assert(len(spherePrimitives.vertices) > 0)

	assert(len(spherePrimitives.indices) < int(max(u32)))

	h.indexCount = u32(len(spherePrimitives.indices))
	{


		vkh.chk(
			vma.create_buffer(
				vkh.allocator,
				{
					sType = .BUFFER_CREATE_INFO,
					size = vk.DeviceSize(len(spherePrimitives.vertices) * size_of([3]f32)),
					usage = {.VERTEX_BUFFER},
				},
				{flags = {.Host_Access_Sequential_Write, .Mapped}, usage = .Auto},
				&h.vertexBuffer.buffer,
				&h.vertexBuffer.alloc,
				nil,
			),
		)


		vkh.chk(
			vma.create_buffer(
				vkh.allocator,
				{
					sType = .BUFFER_CREATE_INFO,
					size = vk.DeviceSize(
						len(spherePrimitives.indices) * size_of(INDEX_TYPE_USED_IN_CHUNKS),
					),
					usage = {.INDEX_BUFFER},
				},
				{flags = {.Host_Access_Sequential_Write, .Mapped}, usage = .Auto},
				&h.indexBuffer.buffer,
				&h.indexBuffer.alloc,
				nil,
			),
		)
	}

	{
		vertBufferPtr: rawptr
		vkh.chk(vma.map_memory(vkh.allocator, h.vertexBuffer.alloc, &vertBufferPtr))

		mem.copy(
			vertBufferPtr,
			raw_data(spherePrimitives.vertices),
			len(spherePrimitives.vertices) * size_of(spherePrimitives.vertices[0]),
		)
		vma.unmap_memory(vkh.allocator, h.vertexBuffer.alloc)


		indexBufferPtr: rawptr
		vkh.chk(vma.map_memory(vkh.allocator, h.indexBuffer.alloc, &indexBufferPtr))
		mem.copy(
			indexBufferPtr,
			raw_data(spherePrimitives.indices),
			len(spherePrimitives.indices) * size_of(spherePrimitives.indices[0]),
		)
		vma.unmap_memory(vkh.allocator, h.indexBuffer.alloc)

	}
	return h

}

HighlightSpherePushConstants :: struct {
	center: [3]f32,
	time:   f32,
}

highlight_sphere_pipeline_init :: proc() -> (p: vkh.PipelineData) {
	desc := [?]vk.DescriptorSetLayoutBinding {
		{
			binding = 0,
			descriptorType = .UNIFORM_BUFFER,
			descriptorCount = 1,
			stageFlags = {.VERTEX},
		},
	}

	vkh.chk(
		vk.CreateDescriptorSetLayout(
			vkh.device,
			&{
				sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
				flags = {.PUSH_DESCRIPTOR_KHR},
				bindingCount = len(desc),
				pBindings = raw_data(desc[:]),
			},
			nil,
			&p.descriptorSetLayout,
		),
	)

	HIGHLIGHT_SPHERE_VERT_SPV :: #load("../build/shader-binaries/highlight-sphere.vertex.spv")
	HIGHLIGHT_SPHERE_FRAG_SPV :: #load("../build/shader-binaries/highlight-sphere.fragment.spv")
	vert := vkh.create_shader_module(vkh.device, HIGHLIGHT_SPHERE_VERT_SPV)
	frag := vkh.create_shader_module(vkh.device, HIGHLIGHT_SPHERE_FRAG_SPV)

	defer vk.DestroyShaderModule(vkh.device, vert, nil)
	defer vk.DestroyShaderModule(vkh.device, frag, nil)

	pushRange := vk.PushConstantRange {
		stageFlags = {.VERTEX},
		offset     = 0,
		size       = size_of(HighlightSpherePushConstants),
	}

	vkh.chk(
		vk.CreatePipelineLayout(
			vkh.device,
			&vk.PipelineLayoutCreateInfo {
				sType = .PIPELINE_LAYOUT_CREATE_INFO,
				setLayoutCount = 1,
				pSetLayouts = &p.descriptorSetLayout,
				pushConstantRangeCount = 1,
				pPushConstantRanges = &pushRange,
			},
			nil,
			&p.layout,
		),
	)

	vi := [?]vk.VertexInputBindingDescription {
		{binding = 0, stride = size_of([3]f32), inputRate = .VERTEX},
	}
	va := [?]vk.VertexInputAttributeDescription {
		{location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = 0},
	}

	stages := [?]vk.PipelineShaderStageCreateInfo {
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.VERTEX},
			module = vert,
			pName = "main",
		},
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.FRAGMENT},
			module = frag,
			pName = "main",
		},
	}
	dynamicStates := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}


	vkh.chk(
		vk.CreateGraphicsPipelines(
			vkh.device,
			{},
			1,
			&vk.GraphicsPipelineCreateInfo {
				sType = .GRAPHICS_PIPELINE_CREATE_INFO,
				pNext = &vk.PipelineRenderingCreateInfo {
					sType = .PIPELINE_RENDERING_CREATE_INFO,
					colorAttachmentCount = 1,
					pColorAttachmentFormats = &vkh.swapchainImageFormat,
					depthAttachmentFormat = vkh.depthFormat,
				},
				stageCount = len(stages),
				pStages = raw_data(stages[:]),
				pVertexInputState = &vk.PipelineVertexInputStateCreateInfo {
					sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
					vertexBindingDescriptionCount = len(vi),
					pVertexBindingDescriptions = raw_data(vi[:]),
					vertexAttributeDescriptionCount = len(va),
					pVertexAttributeDescriptions = raw_data(va[:]),
				},
				pInputAssemblyState = &vk.PipelineInputAssemblyStateCreateInfo {
					sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
					topology = .LINE_LIST,
				},
				pViewportState = &vk.PipelineViewportStateCreateInfo {
					sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
					viewportCount = 1,
					scissorCount = 1,
				},
				pRasterizationState = &vk.PipelineRasterizationStateCreateInfo {
					sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
					lineWidth = 1,
					cullMode = {},
					depthBiasEnable = true,
					frontFace = .CLOCKWISE,
				},
				pMultisampleState = &vk.PipelineMultisampleStateCreateInfo {
					sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
					rasterizationSamples = {._1},
				},
				pDepthStencilState = &vk.PipelineDepthStencilStateCreateInfo {
					sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
					depthTestEnable = true,
					depthWriteEnable = true,
					depthCompareOp = .LESS_OR_EQUAL,
				},
				pColorBlendState = &vk.PipelineColorBlendStateCreateInfo {
					sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
					attachmentCount = 1,
					pAttachments = &vk.PipelineColorBlendAttachmentState {
						blendEnable = true,
						srcColorBlendFactor = .SRC_ALPHA,
						dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
						colorBlendOp = .ADD,
						srcAlphaBlendFactor = .ONE,
						dstAlphaBlendFactor = .ZERO,
						alphaBlendOp = .ADD,
						colorWriteMask = {.R, .G, .B, .A},
					},
				},
				layout = p.layout,
				pDynamicState = &vk.PipelineDynamicStateCreateInfo {
					sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
					dynamicStateCount = len(dynamicStates),
					pDynamicStates = raw_data(dynamicStates[:]),
				},
			},
			nil,
			&p.graphicsPipeline,
		),
	)
	return p
}
highlight_sphere_draw :: proc(
	cb: vk.CommandBuffer,
	sphere: ^HighlightSphere,
	CameraUBO: vk.Buffer,
	CameraUBOSize: vk.DeviceSize,
	center: [3]f32,
	time: f32,
) {

	vk.CmdBindPipeline(cb, .GRAPHICS, sphere.pipeline.graphicsPipeline)
	vk.CmdSetViewport(
		cb,
		0,
		1,
		&vk.Viewport {
			width = f32(gs.screenWidth),
			height = -f32(gs.screenHeight),
			minDepth = 0,
			maxDepth = 1,
			y = f32(gs.screenHeight),
			x = 0,
		},
	)
	vk.CmdSetScissor(
		cb,
		0,
		1,
		&vk.Rect2D{extent = {width = gs.screenWidth, height = gs.screenHeight}},
	)
	// viewport := vk.Viewport {
	// 	x        = 0,
	// 	y        = 0,
	// 	width    = f32(gs.screenWidth),
	// 	height   = f32(gs.screenHeight),
	// 	minDepth = 0.0,
	// 	maxDepth = 1.0,
	// }
	// vk.CmdSetViewport(cb, 0, 1, &viewport)

	// scissor := vk.Rect2D {
	// 	offset = {0, 0},
	// 	extent = {width = u32(gs.screenWidth), height = u32(gs.screenHeight)},
	// }
	// vk.CmdSetScissor(cb, 0, 1, &scissor)


	vertexBuffer := sphere.vertexBuffer.buffer
	vertexOffset := vk.DeviceSize(0)

	vk.CmdBindVertexBuffers(cb, 0, 1, &vertexBuffer, &vertexOffset)

	vk.CmdBindIndexBuffer(cb, sphere.indexBuffer.buffer, 0, .UINT32)


	push := HighlightSpherePushConstants {
		center = center,
		time   = time,
	}


	vk.CmdPushConstants(
		cb,
		sphere.pipeline.layout,
		{.VERTEX},
		0,
		size_of(HighlightSpherePushConstants),
		&push,
	)

	cameraInfo := vk.DescriptorBufferInfo {
		buffer = vkh.cameraBuffers[vkh.frameIndex].buffer,
		offset = 0,
		range  = vkh.CameraUBOSize,
	}

	write := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstBinding      = 0,
		descriptorCount = 1,
		descriptorType  = .UNIFORM_BUFFER,
		pBufferInfo     = &cameraInfo,
	}

	vk.CmdPushDescriptorSetKHR(cb, .GRAPHICS, sphere.pipeline.layout, 0, 1, &write)
	vk.CmdDrawIndexed(cb, sphere.indexCount, 1, 0, 0, 0)


}
highlight_sphere_destroy :: proc(sphere: ^HighlightSphere) {
	if sphere.vertexBuffer.alloc != {} {
		vma.destroy_buffer(vkh.allocator, sphere.vertexBuffer.buffer, sphere.vertexBuffer.alloc)
	}
	if sphere.indexBuffer.alloc != {} {
		vma.destroy_buffer(vkh.allocator, sphere.indexBuffer.buffer, sphere.indexBuffer.alloc)
	}

	if sphere.pipeline.graphicsPipeline != {} {
		vk.DestroyPipeline(vkh.device, sphere.pipeline.graphicsPipeline, nil)
	}
	if sphere.pipeline.layout != {} {
		vk.DestroyPipelineLayout(vkh.device, sphere.pipeline.layout, nil)
	}
	if sphere.pipeline.descriptorSetLayout != {} {
		vk.DestroyDescriptorSetLayout(vkh.device, sphere.pipeline.descriptorSetLayout, nil)
	}

	sphere^ = {}
}
