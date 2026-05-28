package main
import "../modules/vma"
import "core:flags"
import "core:fmt"
import "core:math"
import "core:mem"
import "gs"
import vk "vendor:vulkan"
import "vkh"

CSM_CASCADE_COUNT :: 4
SunUBO :: struct {
	lightVP:                        [CSM_CASCADE_COUNT]matrix[4, 4]f32,
	worldPos, color, cascadeSplits: [4]f32,
}

SHADOW_MAP_SIZE :: 4098
SunRenderData :: struct {
	p:                 vkh.PipelineData,
	vertexIndexBuffer: vkh.BufferAlloc,
	uboBuffers:        [vkh.MAX_FRAMES_IN_FLIGHT]vkh.BufferAlloc,
	ubo:               SunUBO,
	shadow:            struct {
		image:      vkh.ImageAlloc,
		layerViews: [CSM_CASCADE_COUNT]vk.ImageView,
		arrayView:  vk.ImageView,
		sampler:    vk.Sampler,
		pipeline:   vkh.PipelineData,
	},
}
SunPC :: struct {
	worldPos: [3]f32,
}
SunVertex :: struct {
	pos: [3]f32,
}
sun_init :: proc() -> (d: SunRenderData) {

	{
		camBinding := vk.DescriptorSetLayoutBinding {
			binding         = 0,
			descriptorType  = .UNIFORM_BUFFER,
			descriptorCount = 1,
			stageFlags      = {.VERTEX},
		}
		vkh.chk(
			vk.CreateDescriptorSetLayout(
				vkh.device,
				&{
					flags = {.PUSH_DESCRIPTOR_KHR},
					sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
					bindingCount = 1,
					pBindings = &camBinding,
				},
				nil,
				&d.p.descriptorSetLayout,
			),
		)

		pushRange := vk.PushConstantRange {
			stageFlags = {.VERTEX},
			size       = size_of(SunPC),
		}

		vkh.chk(
			vk.CreatePipelineLayout(
				vkh.device,
				&{
					sType = .PIPELINE_LAYOUT_CREATE_INFO,
					setLayoutCount = 1,
					pSetLayouts = &d.p.descriptorSetLayout,
					pushConstantRangeCount = 1,
					pPushConstantRanges = &pushRange,
				},
				nil,
				&d.p.layout,
			),
		)
		VERT_SPV :: #load("../build/shader-binaries/sun.vertex.spv")
		FRAG_SPV :: #load("../build/shader-binaries/sun.fragment.spv")
		vertMod := vkh.create_shader_module(vkh.device, VERT_SPV)
		fragMod := vkh.create_shader_module(vkh.device, FRAG_SPV)
		defer vk.DestroyShaderModule(vkh.device, vertMod, nil)
		defer vk.DestroyShaderModule(vkh.device, fragMod, nil)

		viBindings := [?]vk.VertexInputBindingDescription {
			{binding = 0, stride = size_of(SunVertex), inputRate = .VERTEX},
		}
		vaDescriptors := [?]vk.VertexInputAttributeDescription {
			{location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = 0},
		}
		dynamicStates := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
		stages := [?]vk.PipelineShaderStageCreateInfo {
			{
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = {.VERTEX},
				module = vertMod,
				pName = "main",
			},
			{
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = {.FRAGMENT},
				module = fragMod,
				pName = "main",
			},
		}
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
					pVertexInputState = &{
						sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
						vertexBindingDescriptionCount = len(viBindings),
						pVertexBindingDescriptions = raw_data(viBindings[:]),
						vertexAttributeDescriptionCount = len(vaDescriptors),
						pVertexAttributeDescriptions = raw_data(vaDescriptors[:]),
					},
					pInputAssemblyState = &{
						sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
						topology = .TRIANGLE_LIST,
					},
					pViewportState = &{
						sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
						viewportCount = 1,
						scissorCount = 1,
					},
					pRasterizationState = &{
						sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
						lineWidth = 1.0,
						cullMode = {.BACK},
						frontFace = .COUNTER_CLOCKWISE,
					},
					pMultisampleState = &{
						sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
						rasterizationSamples = {._1},
					},
					pDepthStencilState = &{
						sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
						depthTestEnable = true,
						depthWriteEnable = false,
						depthCompareOp = .LESS,
					},
					pColorBlendState = &{
						sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
						attachmentCount = 1,
						pAttachments = &vk.PipelineColorBlendAttachmentState {
							colorWriteMask = {.R, .G, .B, .A},
						},
					},
					pDynamicState = &{
						sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
						dynamicStateCount = len(dynamicStates),
						pDynamicStates = raw_data(dynamicStates[:]),
					},
					layout = d.p.layout,
				},
				nil,
				&d.p.pipeline,
			),
		)
		verts, idxs := sun_mesh_generate()
		vertSize := vk.DeviceSize(size_of(SunVertex) * len(verts))
		indexSize := vk.DeviceSize(size_of(idxs[0]) * len(idxs))

		vkh.chk(
			vma.create_buffer(
				vkh.allocator,
				{
					sType = .BUFFER_CREATE_INFO,
					size = vertSize + indexSize,
					usage = {.VERTEX_BUFFER, .INDEX_BUFFER},
				},
				{flags = {.Host_Access_Sequential_Write, .Mapped}, usage = .Auto},
				&d.vertexIndexBuffer.buffer,
				&d.vertexIndexBuffer.alloc,
				nil,
			),
		)
		vma.set_allocation_name(
			vkh.allocator,
			d.vertexIndexBuffer.alloc,
			"sun vertex index buffer",
		)

		ptr: rawptr
		vma.map_memory(vkh.allocator, d.vertexIndexBuffer.alloc, &ptr)
		mem.copy(ptr, &verts, int(vertSize))
		mem.copy(mem.ptr_offset((^byte)(ptr), int(vertSize)), &idxs, int(indexSize))
		vma.unmap_memory(vkh.allocator, d.vertexIndexBuffer.alloc)
	}
	assert(d.p != {})
	assert(d.vertexIndexBuffer != {})

	{
		for &ba, i in d.uboBuffers {
			vkh.chk(
				vma.create_buffer(
					vkh.allocator,
					{
						sType = .BUFFER_CREATE_INFO,
						size = vk.DeviceSize(size_of(SunUBO)),
						usage = {.UNIFORM_BUFFER},
					},
					{flags = {.Host_Access_Sequential_Write, .Mapped}, usage = .Auto},
					&ba.buffer,
					&ba.alloc,
					nil,
				),
			)
			vma.set_allocation_name(vkh.allocator, ba.alloc, fmt.ctprintf("sun ubo buffer %d", i))
		}
	}

	{
		vma.create_image(
			vkh.allocator,
			vk.ImageCreateInfo {
				sType = .IMAGE_CREATE_INFO,
				imageType = .D2,
				format = .D32_SFLOAT,
				extent = {width = SHADOW_MAP_SIZE, height = SHADOW_MAP_SIZE, depth = 1},
				mipLevels = 1,
				arrayLayers = CSM_CASCADE_COUNT,
				samples = {._1},
				tiling = .OPTIMAL,
				usage = {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
			},
			{usage = .Auto_Prefer_Device},
			&d.shadow.image.image,
			&d.shadow.image.alloc,
			nil,
		)
		vma.set_allocation_name(vkh.allocator, d.shadow.image.alloc, "sun shadow image")

		vk.CreateImageView(
			vkh.device,
			&{
				sType = .IMAGE_VIEW_CREATE_INFO,
				image = d.shadow.image.image,
				viewType = .D2_ARRAY,
				format = .D32_SFLOAT,
				subresourceRange = {
					aspectMask = {.DEPTH},
					levelCount = 1,
					layerCount = CSM_CASCADE_COUNT,
				},
			},
			nil,
			&d.shadow.arrayView,
		)
		for i in 0 ..< CSM_CASCADE_COUNT {
			vk.CreateImageView(
				vkh.device,
				&{
					sType = .IMAGE_VIEW_CREATE_INFO,
					image = d.shadow.image.image,
					viewType = .D2,
					format = .D32_SFLOAT,
					subresourceRange = {
						aspectMask = {.DEPTH},
						levelCount = 1,
						baseArrayLayer = u32(i),
						layerCount = 1,
					},
				},
				nil,
				&d.shadow.layerViews[i],
			)
		}


		vk.CreateSampler(
			vkh.device,
			&{
				sType = .SAMPLER_CREATE_INFO,
				magFilter = .LINEAR,
				minFilter = .LINEAR,
				addressModeU = .CLAMP_TO_BORDER,
				addressModeV = .CLAMP_TO_BORDER,
				addressModeW = .CLAMP_TO_BORDER,
				borderColor = .FLOAT_OPAQUE_BLACK,
				compareEnable = true,
				compareOp = .LESS_OR_EQUAL,
			},
			nil,
			&d.shadow.sampler,
		)

		camBinding := vk.DescriptorSetLayoutBinding {
			binding         = 0,
			descriptorType  = .UNIFORM_BUFFER,
			descriptorCount = 1,
			stageFlags      = {.VERTEX},
		}
		vkh.chk(
			vk.CreateDescriptorSetLayout(
				vkh.device,
				&{
					flags = {.PUSH_DESCRIPTOR_KHR},
					sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
					bindingCount = 1,
					pBindings = &camBinding,
				},
				nil,
				&d.shadow.pipeline.descriptorSetLayout,
			),
		)
		pushRange := vk.PushConstantRange {
			stageFlags = {.VERTEX},
			size       = size_of(u32),
		}
		vkh.chk(
			vk.CreatePipelineLayout(
				vkh.device,
				&{
					sType = .PIPELINE_LAYOUT_CREATE_INFO,
					setLayoutCount = 1,
					pSetLayouts = &d.shadow.pipeline.descriptorSetLayout,
					pushConstantRangeCount = 1,
					pPushConstantRanges = &pushRange,
				},
				nil,
				&d.shadow.pipeline.layout,
			),
		)
		SHADOW_VERT_SPV :: #load("../build/shader-binaries/shadow.vertex.spv")
		shadowVertex := vkh.create_shader_module(vkh.device, SHADOW_VERT_SPV)
		defer vk.DestroyShaderModule(vkh.device, shadowVertex, nil)

		viBindings := [?]vk.VertexInputBindingDescription {
			{binding = 0, stride = size_of(PointVertexInput), inputRate = .VERTEX},
		}
		vaDescriptors := [?]vk.VertexInputAttributeDescription {
			{location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = 0},
		}
		dynamicStates := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
		stages := [?]vk.PipelineShaderStageCreateInfo {
			{
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = {.VERTEX},
				module = shadowVertex,
				pName = "main",
			},
		}
		vkh.chk(
			vk.CreateGraphicsPipelines(
				vkh.device,
				{},
				1,
				&vk.GraphicsPipelineCreateInfo {
					sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
					pNext               = &vk.PipelineRenderingCreateInfo {
						sType                 = .PIPELINE_RENDERING_CREATE_INFO,
						depthAttachmentFormat = .D32_SFLOAT,
						colorAttachmentCount  = 0, // no color
					},
					stageCount          = len(stages),
					pStages             = raw_data(stages[:]),
					pVertexInputState   = &{
						sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
						vertexBindingDescriptionCount = len(viBindings),
						pVertexBindingDescriptions = raw_data(viBindings[:]),
						vertexAttributeDescriptionCount = len(vaDescriptors),
						pVertexAttributeDescriptions = raw_data(vaDescriptors[:]),
					},
					pInputAssemblyState = &{
						sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
						topology = .TRIANGLE_LIST,
					},
					pViewportState      = &{
						sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
						viewportCount = 1,
						scissorCount = 1,
					},
					pRasterizationState = &{
						sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
						cullMode = {},
						frontFace = .COUNTER_CLOCKWISE,
						depthBiasConstantFactor = 2.0,
						depthBiasSlopeFactor = 1.5,
						depthBiasEnable = true,
						lineWidth = 1.0,
					},
					pMultisampleState   = &{
						sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
						rasterizationSamples = {._1},
					},
					pDepthStencilState  = &{
						sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
						depthTestEnable = true,
						depthWriteEnable = true,
						depthCompareOp = .LESS,
					},
					pDynamicState       = &{
						sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
						dynamicStateCount = len(dynamicStates),
						pDynamicStates = raw_data(dynamicStates[:]),
					},
					layout              = d.shadow.pipeline.layout,
				},
				nil,
				&d.shadow.pipeline.pipeline,
			),
		)

	}
	assert(d.shadow != {})

	return d
}

sun_draw :: proc(cb: vk.CommandBuffer, data: ^SunRenderData) {
	cameraBuffer := vkh.cameraBuffers[vkh.frameIndex].buffer

	vk.CmdBindPipeline(cb, .GRAPHICS, data.p.pipeline)

	camInfo := vk.DescriptorBufferInfo {
		buffer = cameraBuffer,
		offset = 0,
		range  = vkh.CameraUBOSize,
	}

	write := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstBinding      = 0,
		descriptorCount = 1,
		descriptorType  = .UNIFORM_BUFFER,
		pBufferInfo     = &camInfo,
	}
	vk.CmdPushDescriptorSetKHR(cb, .GRAPHICS, data.p.layout, 0, 1, &write)
	pc := SunPC {
		worldPos = data.ubo.worldPos.xyz,
	}
	vk.CmdPushConstants(cb, data.p.layout, {.VERTEX}, 0, size_of(SunPC), &pc)

	vbuf := data.vertexIndexBuffer.buffer
	voff := vk.DeviceSize(0)
	vk.CmdBindVertexBuffers(cb, 0, 1, &vbuf, &voff)
	vk.CmdBindIndexBuffer(
		cb,
		data.vertexIndexBuffer.buffer,
		vk.DeviceSize(SUN_VERT_COUNT * size_of(SunVertex)),
		.UINT32,
	)
	vk.CmdDrawIndexed(cb, SUN_INDEX_COUNT, 1, 0, 0, 0)
}
sun_render_data_destroy :: proc(d: ^SunRenderData) {
	vma.destroy_buffer(vkh.allocator, d.vertexIndexBuffer.buffer, d.vertexIndexBuffer.alloc)
	for ba in d.uboBuffers do vma.destroy_buffer(vkh.allocator, ba.buffer, ba.alloc)
	vkh.pipeline_destroy(d.p)

	vk.DestroySampler(vkh.device, d.shadow.sampler, nil)
	vk.DestroyImageView(vkh.device, d.shadow.arrayView, nil)
	for view in d.shadow.layerViews do vk.DestroyImageView(vkh.device, view, nil)

	vma.destroy_image(vkh.allocator, d.shadow.image.image, d.shadow.image.alloc)
	vkh.pipeline_destroy(d.shadow.pipeline)

}
sun_ubo_update :: proc(ubo: ^SunUBO, time: f64, cameraPos: [3]f32) {
	assert(time >= 0.0)
	for c in ubo.color.xyz do assert(c >= 0 && c <= 1)

	angle := f32(time) * 0.25
	radius :: f32(500)

	height := math.sin_f32(angle * 0.6) * 200 + 280
	ubo.worldPos = {
		cameraPos.x + math.cos_f32(angle) * radius,
		math.sin_f32(angle) * radius,
		cameraPos.z + 100,
		0,
	}

	ubo.lightVP = compute_cascade_light_vps(ubo.worldPos.xyz, cameraPos)
	ubo.cascadeSplits = CSM_SPLIT_DISTANCES

	sunHeight := math.sin_f32(angle)
	dayT := math.clamp(sunHeight, 0, 1)
	horizonT := 1.0 - math.abs(sunHeight)

	night :: [3]f32{0.01, 0.02, 0.02}
	day :: [3]f32{0.20, 0.45, 0.72}
	horizon :: [3]f32{0.55, 0.22, 0.08}

	sky := night + (day - night) * dayT
	sky = sky + (horizon - sky) * horizonT * horizonT
	gs.clearColor = {sky.x, sky.y, sky.z, 1}


	nightLight :: [3]f32{0.05, 0.07, 0.15}
	dayLight :: [3]f32{1.00, 0.92, 0.75}
	horizonLight :: [3]f32{1.00, 0.50, 0.20}

	lightColor := nightLight + (dayLight - nightLight) * dayT
	lightColor = lightColor + (horizonLight - lightColor) * horizonT * horizonT

	lightIntensity := 0.1 + 1.4 * dayT + 0.7 * horizonT * horizonT
	ubo.color = {lightColor.x, lightColor.y, lightColor.z, lightIntensity}


}
SUN_RINGS :: 12
SUN_SECTORS :: 12
SUN_VERT_COUNT :: (SUN_RINGS + 1) * (SUN_SECTORS + 1)
SUN_INDEX_COUNT :: SUN_RINGS * SUN_SECTORS * 6
sun_mesh_generate :: proc() -> (verts: [SUN_VERT_COUNT]SunVertex, idxs: [SUN_INDEX_COUNT]u32) {
	vi := 0
	for r in 0 ..= SUN_RINGS {
		phi := math.PI * f32(r) / f32(SUN_RINGS)
		for s in 0 ..= SUN_SECTORS {
			theta := 2 * math.PI * f32(s) / f32(SUN_SECTORS)
			verts[vi].pos = {
				math.sin_f32(phi) * math.cos_f32(theta),
				math.cos_f32(phi),
				math.sin_f32(phi) * math.sin_f32(theta),
			}
			vi += 1
		}
	}
	ii := 0
	for r in 0 ..< SUN_RINGS {
		for s in 0 ..< SUN_SECTORS {
			a := u32(r * (SUN_SECTORS + 1) + s)
			b := a + u32(SUN_SECTORS) + 1
			idxs[ii + 0] = a; idxs[ii + 1] = b; idxs[ii + 2] = a + 1
			idxs[ii + 3] = a + 1; idxs[ii + 4] = b; idxs[ii + 5] = b + 1
			ii += 6
		}
	}
	return
}
