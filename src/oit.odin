package main
import "gs"
import vk "vendor:vulkan"
import "vkh"

OitPushConstants :: struct {
	nearPlane: f32,
	farPlane:  f32,
}

oit_pipelines_init :: proc() -> (oit, composite: vkh.PipelineData) {
	OIT_VERT_SPV :: #load("../build/shader-binaries/oit.vertex.spv")
	OIT_FRAG_SPV :: #load("../build/shader-binaries/oit.fragment.spv")
	oitVert := vkh.create_shader_module(vkh.device, OIT_VERT_SPV)
	oitFrag := vkh.create_shader_module(vkh.device, OIT_FRAG_SPV)


	COMP_VERT_SPV :: #load("../build/shader-binaries/composite-pass.vertex.spv")
	COMP_FRAG_SPV :: #load("../build/shader-binaries/composite-pass.fragment.spv")


	compVert := vkh.create_shader_module(vkh.device, COMP_VERT_SPV)
	compFrag := vkh.create_shader_module(vkh.device, COMP_FRAG_SPV)

	defer {
		vk.DestroyShaderModule(vkh.device, oitVert, nil)
		vk.DestroyShaderModule(vkh.device, oitFrag, nil)
		vk.DestroyShaderModule(vkh.device, compVert, nil)
		vk.DestroyShaderModule(vkh.device, compFrag, nil)
	}

	oitBindings := [?]vk.DescriptorSetLayoutBinding {
		{
			binding = 0,
			descriptorType = .UNIFORM_BUFFER,
			descriptorCount = 1,
			stageFlags = {.VERTEX, .FRAGMENT},
		},
	}


	vkh.chk(
		vk.CreateDescriptorSetLayout(
			vkh.device,
			&vk.DescriptorSetLayoutCreateInfo {
				sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
				flags = {.PUSH_DESCRIPTOR_KHR},
				bindingCount = len(oitBindings),
				pBindings = raw_data(oitBindings[:]),
			},
			nil,
			&oit.descriptorSetLayout,
		),
	)

	pushRange := vk.PushConstantRange {
		stageFlags = {.VERTEX, .FRAGMENT},
		offset     = 0,
		size       = size_of(OitPushConstants),
	}

	vkh.chk(
		vk.CreatePipelineLayout(
			vkh.device,
			&vk.PipelineLayoutCreateInfo {
				sType = .PIPELINE_LAYOUT_CREATE_INFO,
				setLayoutCount = 1,
				pSetLayouts = &oit.descriptorSetLayout,
				pushConstantRangeCount = 1,
				pPushConstantRanges = &pushRange,
			},
			nil,
			&oit.layout,
		),
	)

	compBindings := [?]vk.DescriptorSetLayoutBinding {
		{
			binding = 0,
			descriptorType = .SAMPLED_IMAGE,
			descriptorCount = 1,
			stageFlags = {.FRAGMENT},
		},
		{
			binding = 1,
			descriptorType = .SAMPLED_IMAGE,
			descriptorCount = 1,
			stageFlags = {.FRAGMENT},
		},
		{binding = 2, descriptorType = .SAMPLER, descriptorCount = 1, stageFlags = {.FRAGMENT}},
	}

	vkh.chk(
		vk.CreateDescriptorSetLayout(
			vkh.device,
			&vk.DescriptorSetLayoutCreateInfo {
				sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
				flags = {.PUSH_DESCRIPTOR_KHR},
				bindingCount = len(compBindings),
				pBindings = raw_data(compBindings[:]),
			},
			nil,
			&composite.descriptorSetLayout,
		),
	)
	vkh.chk(
		vk.CreatePipelineLayout(
			vkh.device,
			&vk.PipelineLayoutCreateInfo {
				sType = .PIPELINE_LAYOUT_CREATE_INFO,
				setLayoutCount = 1,
				pSetLayouts = &composite.descriptorSetLayout,
			},
			nil,
			&composite.layout,
		),
	)
	viBindings := [?]vk.VertexInputBindingDescription {
		{binding = 0, stride = size_of(PointVertexInput), inputRate = .VERTEX},
	}

	// #assert(u32(offset_of(PointVertexInput, normal)) == 12)
	#assert(u32(offset_of(PointVertexInput, pointVal)) == 12)

	vaDescriptors := [?]vk.VertexInputAttributeDescription {
		{
			location = 0,
			binding = 0,
			format = .R32G32B32_SFLOAT,
			offset = u32(offset_of(PointVertexInput, pos)),
		},
		{
			location = 1,
			binding = 0,
			format = .R32_UINT,
			offset = u32(offset_of(PointVertexInput, pointVal)),
		},
	}

	oitStages := [?]vk.PipelineShaderStageCreateInfo {
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.VERTEX},
			module = oitVert,
			pName = "main",
		},
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.FRAGMENT},
			module = oitFrag,
			pName = "main",
		},
	}
	oitColorFormats := [3]vk.Format{vkh.swapchainImageFormat, .R16G16B16A16_SFLOAT, .R16_SFLOAT}


	oitBlendAttachments := [3]vk.PipelineColorBlendAttachmentState {
		{colorWriteMask = {}},
		{
			blendEnable = true,
			srcColorBlendFactor = .ONE,
			dstColorBlendFactor = .ONE,
			colorBlendOp = .ADD,
			srcAlphaBlendFactor = .ONE,
			dstAlphaBlendFactor = .ONE,
			alphaBlendOp = .ADD,
			colorWriteMask = {.R, .G, .B, .A},
		},
		{
			blendEnable = true,
			srcColorBlendFactor = .ZERO,
			dstColorBlendFactor = .ONE_MINUS_SRC_COLOR,
			colorBlendOp = .ADD,
			srcAlphaBlendFactor = .ZERO,
			dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
			alphaBlendOp = .ADD,
			colorWriteMask = {.R},
		},
	}
	oitPipelineInfo := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &vk.PipelineRenderingCreateInfo {
			sType = .PIPELINE_RENDERING_CREATE_INFO,
			colorAttachmentCount = len(oitColorFormats),
			pColorAttachmentFormats = raw_data(oitColorFormats[:]),
			depthAttachmentFormat = vkh.depthFormat,
		},
		stageCount          = len(oitStages),
		pStages             = raw_data(oitStages[:]),
		pVertexInputState   = &vk.PipelineVertexInputStateCreateInfo {
			sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
			vertexBindingDescriptionCount = len(viBindings),
			pVertexBindingDescriptions = raw_data(viBindings[:]),
			vertexAttributeDescriptionCount = len(vaDescriptors),
			pVertexAttributeDescriptions = raw_data(vaDescriptors[:]),
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
			lineWidth = 1.0,
			cullMode = {},
			frontFace = .COUNTER_CLOCKWISE,
		},
		pMultisampleState   = &vk.PipelineMultisampleStateCreateInfo {
			sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
			rasterizationSamples = {._1},
		},
		pDepthStencilState  = &vk.PipelineDepthStencilStateCreateInfo {
			sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
			depthTestEnable = true,
			depthWriteEnable = false,
			depthCompareOp = .LESS,
		},
		pColorBlendState    = &vk.PipelineColorBlendStateCreateInfo {
			sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
			attachmentCount = len(oitBlendAttachments),
			pAttachments = raw_data(oitBlendAttachments[:]),
		},
		pDynamicState       = &vk.PipelineDynamicStateCreateInfo {
			sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
			dynamicStateCount = 2,
			pDynamicStates = raw_data([]vk.DynamicState{.VIEWPORT, .SCISSOR}),
		},
		layout              = oit.layout,
	}


	compStages := [?]vk.PipelineShaderStageCreateInfo {
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.VERTEX},
			module = compVert,
			pName = "main",
		},
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.FRAGMENT},
			module = compFrag,
			pName = "main",
		},
	}

	compositeBlend := vk.PipelineColorBlendAttachmentState {
		blendEnable         = true,
		srcColorBlendFactor = .SRC_ALPHA,
		dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
		colorBlendOp        = .ADD,
		srcAlphaBlendFactor = .ONE,
		dstAlphaBlendFactor = .ZERO,
		alphaBlendOp        = .ADD,
		colorWriteMask      = {.R, .G, .B, .A},
	}
	compositeCreateInfo := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &vk.PipelineRenderingCreateInfo {
			sType = .PIPELINE_RENDERING_CREATE_INFO,
			colorAttachmentCount = 1,
			pColorAttachmentFormats = &vkh.swapchainImageFormat,
			depthAttachmentFormat = vkh.depthFormat,
		},
		stageCount          = len(compStages),
		pStages             = raw_data(compStages[:]),
		pVertexInputState   = &vk.PipelineVertexInputStateCreateInfo {
			sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
			vertexBindingDescriptionCount = 0,
			vertexAttributeDescriptionCount = 0,
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
			lineWidth = 1.0,
			cullMode = {},
			frontFace = .COUNTER_CLOCKWISE,
		},
		pMultisampleState   = &vk.PipelineMultisampleStateCreateInfo {
			sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
			rasterizationSamples = {._1},
		},
		pDepthStencilState  = &vk.PipelineDepthStencilStateCreateInfo {
			sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
			depthTestEnable = false,
			depthWriteEnable = false,
		},
		pColorBlendState    = &vk.PipelineColorBlendStateCreateInfo {
			sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
			attachmentCount = 1,
			pAttachments = &compositeBlend,
		},
		pDynamicState       = &vk.PipelineDynamicStateCreateInfo {
			sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
			dynamicStateCount = 2,
			pDynamicStates = raw_data([]vk.DynamicState{.VIEWPORT, .SCISSOR}),
		},
		layout              = composite.layout,
	}
	infos := [?]vk.GraphicsPipelineCreateInfo{oitPipelineInfo, compositeCreateInfo}
	pipelines: [2]vk.Pipeline
	#assert(len(infos) == len(pipelines))

	vkh.chk(
		vk.CreateGraphicsPipelines(
			vkh.device,
			{},
			len(infos),
			raw_data(infos[:]),
			nil,
			raw_data(pipelines[:]),
		),
	)
	oit.pipeline = pipelines[0]
	composite.pipeline = pipelines[1]
	return oit, composite
}


oit_end :: proc(cb: vk.CommandBuffer) {
	barriers := [?]vk.ImageMemoryBarrier2 {
		{
			sType = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
			dstStageMask = {.FRAGMENT_SHADER},
			oldLayout = .ATTACHMENT_OPTIMAL,
			newLayout = .SHADER_READ_ONLY_OPTIMAL,
			image = vkh.wbAccum.image,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		},
		{
			sType = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
			dstStageMask = {.FRAGMENT_SHADER},
			oldLayout = .ATTACHMENT_OPTIMAL,
			newLayout = .SHADER_READ_ONLY_OPTIMAL,
			image = vkh.wbReveal.image,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		},
	}
	vk.CmdPipelineBarrier2(
		cb,
		&{
			sType = .DEPENDENCY_INFO,
			imageMemoryBarrierCount = len(barriers),
			pImageMemoryBarriers = raw_data(barriers[:]),
		},
	)

}
oit_pipelines_destroy :: proc(oit, composite: vkh.PipelineData) {
	if oit.pipeline != {} do vkh.pipeline_destroy(oit)
	if composite.pipeline != {} do vkh.pipeline_destroy(composite)
}

composite_draw :: proc(cb: vk.CommandBuffer, pipeline: vkh.PipelineData) {
	vk.CmdBindPipeline(cb, .GRAPHICS, pipeline.pipeline)
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
		},
	)
	vk.CmdSetScissor(
		cb,
		0,
		1,
		&vk.Rect2D{extent = {width = gs.screenWidth, height = gs.screenHeight}},
	)
	writes := [3]vk.WriteDescriptorSet {
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstBinding = 0,
			descriptorCount = 1,
			descriptorType = .SAMPLED_IMAGE,
			pImageInfo = &vk.DescriptorImageInfo {
				imageView = vkh.wbAccumView,
				imageLayout = .SHADER_READ_ONLY_OPTIMAL,
			},
		},
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstBinding = 1,
			descriptorCount = 1,
			descriptorType = .SAMPLED_IMAGE,
			pImageInfo = &vk.DescriptorImageInfo {
				imageView = vkh.wbRevealView,
				imageLayout = .SHADER_READ_ONLY_OPTIMAL,
			},
		},
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstBinding = 2,
			descriptorCount = 1,
			descriptorType = .SAMPLER,
			pImageInfo = &vk.DescriptorImageInfo{sampler = vkh.wbSampler},
		},
	}
	vk.CmdPushDescriptorSetKHR(cb, .GRAPHICS, pipeline.layout, 0, len(writes), raw_data(writes[:]))
	vk.CmdDraw(cb, 3, 1, 0, 0)
}
