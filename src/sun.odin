
package main
import "../modules/vma"
import "camera"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "gs"
import vk "vendor:vulkan"
import "vkh"
SunUBO :: struct {
	dir:           [4]f32,
	color:         [4]f32,
	ambientColor:  [4]f32,
	lightViewProj: matrix[4, 4]f32,
}
sun_ubo_update :: proc(ubo: ^SunUBO, time: f64) {
	angle := time

	sunX := f32(math.cos(angle))
	sunZ := f32(math.sin(angle))
	sunY: f32 = .6

	dir := linalg.normalize([3]f32{sunX, sunY, sunZ})
	ubo.dir = {dir.x, dir.y, dir.z, 0}

	dayness := math.clamp(dir.x * 1.5 + .5, 0, 1)
	duskFactor := 1.0 - abs(dir.x)

	ubo.color = {
		1.0,
		0.85 + 0.15 * dayness - 0.2 * duskFactor,
		0.60 + 0.40 * dayness - 0.3 * duskFactor,
		1.2 * dayness,
	}
	ubo.ambientColor = {0.03 + 0.18 * dayness, 0.05 + 0.20 * dayness, 0.12 + 0.15 * dayness, 1}

	sunPos := ubo.dir.xyz * 500.0
	target := camera.curr.pos

	up := camera.WORLD_UP
	if abs(ubo.dir.y) > 0.999 {up = {1, 0, 0}}
	lightView := linalg.matrix4_look_at_f32(sunPos, target, up)

	halfSize :: 5000.0
	lightProj := linalg.matrix_ortho3d_f32(-halfSize, halfSize, -halfSize, halfSize, 0.1, 10000.0)
	ubo.lightViewProj = lightProj * lightView
}

sun_ubo_buffer_init :: proc() -> (bas: [vkh.MAX_FRAMES_IN_FLIGHT]vkh.BufferAlloc) {
	for &ba in bas {
		vkh.chk(
			vma.create_buffer(
				vkh.allocator,
				vk.BufferCreateInfo {
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
	}

	return bas
}
sun_ubo_buffer_destroy :: proc(bas: [vkh.MAX_FRAMES_IN_FLIGHT]vkh.BufferAlloc) {
	for ba in bas do vma.destroy_buffer(vkh.allocator, ba.buffer, ba.alloc)
}
SunVertex :: struct {
	pos: [3]f32,
}

sun_mesh_generate :: proc(
) -> (
	vertices: [SUN_VERT_COUNT]SunVertex,
	indices: [SUN_INDEX_COUNT]u32,
) {
	RINGS :: 12
	SECTORS :: 12

	vi := 0
	for r in 0 ..= RINGS {
		phi := f32(math.PI) * f32(r) / f32(RINGS)
		for s in 0 ..= SECTORS {
			theta := f32(2 * math.PI) * f32(s) / f32(SECTORS)
			vertices[vi] = SunVertex {
				pos = {
					math.sin(phi) * math.cos(theta),
					math.cos(phi),
					math.sin(phi) * math.sin(theta),
				},
			}
			vi += 1
		}
	}

	ii := 0
	for r in 0 ..< RINGS {
		for s in 0 ..< SECTORS {
			a := u32(r * (SECTORS + 1) + s)
			b := a + u32(SECTORS) + 1
			indices[ii] = a
			indices[ii + 1] = b
			indices[ii + 2] = a + 1
			indices[ii + 3] = a + 1
			indices[ii + 4] = b
			indices[ii + 5] = b + 1
			ii += 6
		}
	}

	return
}

SUN_RINGS :: 12
SUN_SECTORS :: 12
SUN_VERT_COUNT :: (SUN_RINGS + 1) * (SUN_SECTORS + 1)
SUN_INDEX_COUNT :: SUN_RINGS * SUN_SECTORS * 6
SUN_DISTANCE :: f32(20)


SunPushConstants :: struct {
	sunWorldPos: [3]f32,
	_pad:        f32,
}

SunRenderData :: struct {
	p:                 vkh.PipelineData,
	vertexIndexBuffer: vkh.BufferAlloc,
	shadow:            SunShadowResources,
}
SHADOW_MAP_SIZE :: 2048

SunShadowResources :: struct {
	image:          vk.Image,
	alloc:          vma.Allocation,
	imageView:      vk.ImageView,
	sampler:        vk.Sampler,
	pipeline:       vk.Pipeline,
	pipelineLayout: vk.PipelineLayout,
}


sun_render_data_init :: proc() -> (data: SunRenderData) {
	pushRange := vk.PushConstantRange {
		stageFlags = {.VERTEX, .FRAGMENT},
		offset     = 0,
		size       = size_of(SunPushConstants),
	}

	descLayoutBindings := [?]vk.DescriptorSetLayoutBinding {
		{ 	// camera
			binding         = 0,
			descriptorType  = .UNIFORM_BUFFER,
			descriptorCount = 1,
			stageFlags      = {.VERTEX},
		},
		{ 	// sun
			binding         = 1,
			descriptorType  = .UNIFORM_BUFFER,
			descriptorCount = 1,
			stageFlags      = {.FRAGMENT},
		},
	}

	vkh.chk(
		vk.CreateDescriptorSetLayout(
			vkh.device,
			&vk.DescriptorSetLayoutCreateInfo {
				sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
				flags = {.PUSH_DESCRIPTOR_KHR},
				bindingCount = len(descLayoutBindings),
				pBindings = raw_data(descLayoutBindings[:]),
			},
			nil,
			&data.p.descriptorSetLayout,
		),
	)

	vkh.chk(
		vk.CreatePipelineLayout(
			vkh.device,
			&vk.PipelineLayoutCreateInfo {
				sType = .PIPELINE_LAYOUT_CREATE_INFO,
				setLayoutCount = 1,
				pSetLayouts = &data.p.descriptorSetLayout,
				pushConstantRangeCount = 1,
				pPushConstantRanges = &pushRange,
			},
			nil,
			&data.p.layout,
		),
	)

	VERT_SPV :: #load("../build/shader-binaries/sun.vertex.spv")
	FRAG_SPV :: #load("../build/shader-binaries/sun.fragment.spv")
	vertModule := vkh.create_shader_module(vkh.device, VERT_SPV)
	fragModule := vkh.create_shader_module(vkh.device, FRAG_SPV)
	defer vk.DestroyShaderModule(vkh.device, vertModule, nil)
	defer vk.DestroyShaderModule(vkh.device, fragModule, nil)

	viBindings := [?]vk.VertexInputBindingDescription {
		{binding = 0, stride = 32, inputRate = .VERTEX},
	}
	vaDescriptors := [?]vk.VertexInputAttributeDescription {
		{location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = 0},
	}

	dynamicStates := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}

	pipelineStages := [?]vk.PipelineShaderStageCreateInfo {
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

	createInfo := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &vk.PipelineRenderingCreateInfo {
			sType = .PIPELINE_RENDERING_CREATE_INFO,
			colorAttachmentCount = 1,
			pColorAttachmentFormats = &vkh.swapchainImageFormat,
			depthAttachmentFormat = vkh.depthFormat,
		},
		stageCount          = len(pipelineStages),
		pStages             = raw_data(pipelineStages[:]),
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
			cullMode = {.FRONT},
			frontFace = .COUNTER_CLOCKWISE,
		},
		pMultisampleState   = &vk.PipelineMultisampleStateCreateInfo {
			sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
			rasterizationSamples = {._1},
		},
		pDepthStencilState  = &vk.PipelineDepthStencilStateCreateInfo {
			sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
			depthTestEnable  = true,
			depthWriteEnable = false, // don't write depth — sun is background
			depthCompareOp   = .LESS,
		},
		pColorBlendState    = &vk.PipelineColorBlendStateCreateInfo {
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
		pDynamicState       = &vk.PipelineDynamicStateCreateInfo {
			sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
			dynamicStateCount = len(dynamicStates),
			pDynamicStates = raw_data(dynamicStates[:]),
		},
		layout              = data.p.layout,
	}

	vkh.chk(vk.CreateGraphicsPipelines(vkh.device, {}, 1, &createInfo, nil, &data.p.pipeline))

	// upload mesh into one GPU buffer: vertices first, then indices
	vertices, indices := sun_mesh_generate()

	vertSize := vk.DeviceSize(size_of(vertices))
	indexSize := vk.DeviceSize(size_of(indices))

	vkh.chk(
		vma.create_buffer(
			vkh.allocator,
			vk.BufferCreateInfo {
				sType = .BUFFER_CREATE_INFO,
				size = vertSize + indexSize,
				usage = {.VERTEX_BUFFER, .INDEX_BUFFER},
			},
			{flags = {.Host_Access_Sequential_Write, .Mapped}, usage = .Auto},
			&data.vertexIndexBuffer.buffer,
			&data.vertexIndexBuffer.alloc,
			nil,
		),
	)

	ptr: rawptr
	vma.map_memory(vkh.allocator, data.vertexIndexBuffer.alloc, &ptr)
	mem.copy(ptr, &vertices, int(vertSize))
	mem.copy(mem.ptr_offset((^byte)(ptr), int(vertSize)), &indices, int(indexSize))
	vma.unmap_memory(vkh.allocator, data.vertexIndexBuffer.alloc)
	data.shadow = sun_shadow_image_create()
	return data
}

sun_shadow_image_create :: proc() -> (r: SunShadowResources) {
	vkh.chk(
		vma.create_image(
			vkh.allocator,
			{
				sType = .IMAGE_CREATE_INFO,
				imageType = .D2,
				format = .D32_SFLOAT,
				extent = {SHADOW_MAP_SIZE, SHADOW_MAP_SIZE, 1},
				mipLevels = 1,
				arrayLayers = 1,
				samples = {._1},
				tiling = .OPTIMAL,
				usage = {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
				initialLayout = .UNDEFINED,
			},
			{},
			&r.image,
			&r.alloc,
			nil,
		),
	)
	vkh.chk(
		vk.CreateImageView(
			vkh.device,
			&{
				sType = .IMAGE_VIEW_CREATE_INFO,
				image = r.image,
				viewType = .D2,
				format = .D32_SFLOAT,
				subresourceRange = {
					aspectMask = {.DEPTH},
					baseMipLevel = 0,
					levelCount = 1,
					baseArrayLayer = 0,
					layerCount = 1,
				},
			},
			nil,
			&r.imageView,
		),
	)

	vkh.chk(
		vk.CreateSampler(
			vkh.device,
			&{
				sType = .SAMPLER_CREATE_INFO,
				magFilter = .LINEAR,
				minFilter = .LINEAR,
				addressModeU = .CLAMP_TO_EDGE,
				addressModeV = .CLAMP_TO_EDGE,
				addressModeW = .CLAMP_TO_EDGE,
				compareEnable = true,
				compareOp = .LESS_OR_EQUAL,
				borderColor = .FLOAT_OPAQUE_WHITE,
			},
			nil,
			&r.sampler,
		),
	)

	pushRange := vk.PushConstantRange {
		stageFlags = {.VERTEX},
		offset     = 0,
		size       = size_of(matrix[4, 4]f32),
	}
	layoutInfo := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &pushRange,
	}
	vkh.chk(vk.CreatePipelineLayout(vkh.device, &layoutInfo, nil, &r.pipelineLayout))

	SHADOW_VERT_SPV :: #load("../build/shader-binaries/shadow.vertex.spv")
	vertModule := vkh.create_shader_module(vkh.device, SHADOW_VERT_SPV)
	defer vk.DestroyShaderModule(vkh.device, vertModule, nil)

	viBindings := [?]vk.VertexInputBindingDescription {
		{binding = 0, stride = 32, inputRate = .VERTEX},
	}
	vaDescriptors := [?]vk.VertexInputAttributeDescription {
		{location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = 0},
	}
	dynamicStates := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}


	renderingInfo := vk.PipelineRenderingCreateInfo {
		sType                 = .PIPELINE_RENDERING_CREATE_INFO,
		depthAttachmentFormat = .D32_SFLOAT,
	}


	pipelineInfo := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &renderingInfo,
		stageCount          = 1,
		pStages             = &vk.PipelineShaderStageCreateInfo {
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.VERTEX},
			module = vertModule,
			pName = "main",
		},
		pMultisampleState   = &vk.PipelineMultisampleStateCreateInfo {
			sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
			rasterizationSamples = {._1},
			sampleShadingEnable = false,
			minSampleShading = 1.0,
			pSampleMask = nil,
			alphaToCoverageEnable = false,
			alphaToOneEnable = false,
		},
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
			frontFace = .COUNTER_CLOCKWISE,
		},
		pDepthStencilState  = &vk.PipelineDepthStencilStateCreateInfo {
			sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
			depthTestEnable = true,
			depthWriteEnable = true,
			depthCompareOp = .LESS,
		},
		pDynamicState       = &vk.PipelineDynamicStateCreateInfo {
			sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
			dynamicStateCount = len(dynamicStates),
			pDynamicStates = raw_data(dynamicStates[:]),
		},
		layout              = r.pipelineLayout,
	}
	vkh.chk(vk.CreateGraphicsPipelines(vkh.device, {}, 1, &pipelineInfo, nil, &r.pipeline))
	return r
}
sun_draw :: proc(
	cb: vk.CommandBuffer,
	renderData: ^SunRenderData,
	camPos: [3]f32,
	sunUBO: ^SunUBO,
	sunUBOBuffer: vk.Buffer,
	cameraBuffer: vk.Buffer,
) {
	vk.CmdBindPipeline(cb, .GRAPHICS, renderData.p.pipeline)

	vertSize := vk.DeviceSize(size_of([SUN_VERT_COUNT]SunVertex))

	vertexBuffer := renderData.vertexIndexBuffer.buffer
	vertexOffset := vk.DeviceSize(0)
	vk.CmdBindVertexBuffers(cb, 0, 1, &vertexBuffer, &vertexOffset)
	vk.CmdBindIndexBuffer(cb, renderData.vertexIndexBuffer.buffer, vertSize, .UINT32)

	cameraInfo := vk.DescriptorBufferInfo {
		buffer = cameraBuffer,
		offset = 0,
		range  = vkh.CameraUBOSize,
	}
	sunInfo := vk.DescriptorBufferInfo {
		buffer = sunUBOBuffer,
		offset = 0,
		range  = vk.DeviceSize(size_of(SunUBO)),
	}

	writes := [?]vk.WriteDescriptorSet {
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstBinding = 0,
			descriptorCount = 1,
			descriptorType = .UNIFORM_BUFFER,
			pBufferInfo = &cameraInfo,
		},
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstBinding = 1,
			descriptorCount = 1,
			descriptorType = .UNIFORM_BUFFER,
			pBufferInfo = &sunInfo,
		},
	}
	vk.CmdPushDescriptorSetKHR(
		cb,
		.GRAPHICS,
		renderData.p.layout,
		0,
		len(writes),
		raw_data(writes[:]),
	)

	SUN_WORLD_DISTANCE :: gs.farPlane - 500
	pc := SunPushConstants {
		sunWorldPos = sunUBO.dir.xyz * SUN_WORLD_DISTANCE,
	}
	vk.CmdPushConstants(
		cb,
		renderData.p.layout,
		{.VERTEX, .FRAGMENT},
		0,
		size_of(SunPushConstants),
		&pc,
	)

	vk.CmdDrawIndexed(cb, SUN_INDEX_COUNT, 1, 0, 0, 0)
}

sun_render_data_destroy :: proc(data: ^SunRenderData) {
	vma.destroy_buffer(vkh.allocator, data.vertexIndexBuffer.buffer, data.vertexIndexBuffer.alloc)
	vkh.pipeline_destroy(data.p)
	sun_shadow_destroy(&data.shadow)
}
sun_shadow_destroy :: proc(res: ^SunShadowResources) {
	vk.DestroyPipeline(vkh.device, res.pipeline, nil)
	vk.DestroyPipelineLayout(vkh.device, res.pipelineLayout, nil)
	vk.DestroySampler(vkh.device, res.sampler, nil)
	vk.DestroyImageView(vkh.device, res.imageView, nil)
	vma.destroy_image(vkh.allocator, res.image, res.alloc)
}
