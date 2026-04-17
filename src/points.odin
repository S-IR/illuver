package main
import "core:time"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"
import "vkh"

Point_r: struct {
	pipeline: ^sdl.GPUGraphicsPipeline,
} = {}

is_valid_point_u16 :: #force_inline proc "contextless" (p: u16) -> bool {
	typeBits := p & TYPE_MASK

	if typeBits >= u16(len(PointType)) {
		return false
	} else {
		return true
	}


}
// BottomFacedVertices := [4]float3 {
//     {-0.5, -0.5, 0.5},
//     {-0.5, -0.5, -0.5},
//     {0.5, -0.5, -0.5},
//     {0.5, -0.5, 0.5},
// }
//
//
TYPE_MASK :: u16(1023)

ENERGY_MASK :: u16(0b11)

u16_to_point_type :: #force_inline proc "contextless" (v: u16) -> PointType {
	return PointType(v & TYPE_MASK)
}

LIGHT_SHIFT :: 10
LIFE_SHIFT :: 12
WISDOM_SHIFT :: 14
LIFE_MASK :: u16(0x3)
LIGHT_MASK :: u16(0x3)
WISDOM_MASK :: u16(0x3)


get_light :: #force_inline proc "contextless" (p: u16) -> u16 {return(
		(p >> LIGHT_SHIFT) &
		ENERGY_MASK \
	)}
get_life :: #force_inline proc "contextless" (p: u16) -> u16 {return(
		(p >> LIFE_SHIFT) &
		ENERGY_MASK \
	)}
get_wisdom :: #force_inline proc "contextless" (p: u16) -> u16 {return(
		(p >> WISDOM_SHIFT) &
		ENERGY_MASK \
	)}

set_light :: #force_inline proc(p: u16, v: u16) -> u16 {return(
		(p & ~(ENERGY_MASK << LIGHT_SHIFT)) |
		((v & ENERGY_MASK) << LIGHT_SHIFT) \
	)}
set_life :: #force_inline proc(p: u16, v: u16) -> u16 {return(
		(p & ~(ENERGY_MASK << LIFE_SHIFT)) |
		((v & ENERGY_MASK) << LIFE_SHIFT) \
	)}
set_wisdom :: #force_inline proc(p: u16, v: u16) -> u16 {return(
		(p & ~(ENERGY_MASK << WISDOM_SHIFT)) |
		((v & ENERGY_MASK) << WISDOM_SHIFT) \
	)}

EnergyType :: enum {
	Light,
	Life,
	Wisdom,
}

PointType :: enum u16 {
	Air,
	YellowDirt,
	PurpleGround,
	LightPurpleGround,
	BlueDiamond,
	BlackCliff,
	PinkTrunk,
	WhiteTreeLeaf,
	Water,
}
#assert(len(PointType) < 1024)

Random_Colors_Per_Point_Type := [PointType][4]f32 {
	.Air               = {},
	.YellowDirt        = {159.0 / 255.0, 112.0 / 255.0, 75.0 / 255.0, 1},
	.PurpleGround      = {36.0 / 255.0, 19.0 / 255.0, 97.0 / 255.0, 1},
	// .LightPurpleGround = {
	// 	{0, 0, 0, 1},
	// 	{0, 1, 0, 1},
	// 	{1, 0, 0, 1},
	// 	{1, 1, 0, 1},
	// 	{1, 1, 1, 1},
	// },
	.LightPurpleGround = {141.0 / 255.0, 97.0 / 255.0, 237.0 / 255.0, 1},
	.BlueDiamond       = {0.0 / 255.0, 236.0 / 255.0, 231.0 / 255.0, 1},
	.BlackCliff        = {31.0 / 255.0, 22.0 / 255.0, 25.0 / 255.0, 1},
	.PinkTrunk         = {229.0 / 255.0, 108.0 / 255.0, 125.0 / 255.0, 1},
	.WhiteTreeLeaf     = {218.0 / 255.0, 189.0 / 255.0, 252.0 / 255.0, 1},
	.Water             = {68.0 / 255.0, 131.0 / 255.0, 129.0 / 255.0, 1},
}
BottomFacedIndices := [?]u16{0, 1, 2, 0, 2, 3}


point_pipeline_init :: proc() -> (p: vkh.PipelineData) {

	// --- Descriptor layout (matches SDL shader usage) ---
	descLayoutBindings := [?]vk.DescriptorSetLayoutBinding {
		// binding 0 → vertex uniform buffer
		{
			binding = 0,
			descriptorType = .UNIFORM_BUFFER,
			descriptorCount = 1,
			stageFlags = {.VERTEX},
		},
		// binding 1 → fragment storage buffer
		{
			binding = 1,
			descriptorType = .STORAGE_BUFFER,
			descriptorCount = 1,
			stageFlags = {.FRAGMENT},
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
			&p.descriptorSetLayout,
		),
	)

	// --- Load shaders ---
	VERT_SPV :: #load("../build/shader-binaries/point.vertex.spv")
	FRAG_SPV :: #load("../build/shader-binaries/point.fragment.spv")

	vertModule := vkh.create_shader_module(vkh.device, VERT_SPV)
	fragModule := vkh.create_shader_module(vkh.device, FRAG_SPV)

	defer vk.DestroyShaderModule(vkh.device, vertModule, nil)
	defer vk.DestroyShaderModule(vkh.device, fragModule, nil)
	// --- Pipeline layout ---
	vkh.chk(
		vk.CreatePipelineLayout(
			vkh.device,
			&vk.PipelineLayoutCreateInfo {
				sType = .PIPELINE_LAYOUT_CREATE_INFO,
				setLayoutCount = 1,
				pSetLayouts = &p.descriptorSetLayout,
			},
			nil,
			&p.layout,
		),
	)

	viBindings := [?]vk.VertexInputBindingDescription {
		{binding = 0, stride = size_of([3]f32), inputRate = .VERTEX},
		{binding = 1, stride = size_of([2]f32), inputRate = .VERTEX},
	}
	vaDescriptors := [?]vk.VertexInputAttributeDescription {
		{location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = 0},
		{location = 1, binding = 1, format = .R32G32_SFLOAT, offset = 0},
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

	// --- Graphics pipeline ---
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
				stageCount = len(pipelineStages),
				pStages = raw_data(pipelineStages[:]),
				pVertexInputState = &vk.PipelineVertexInputStateCreateInfo {
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
				pViewportState = &vk.PipelineViewportStateCreateInfo {
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
				pMultisampleState = &vk.PipelineMultisampleStateCreateInfo {
					sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
					rasterizationSamples = {._1},
				},
				pDepthStencilState = &vk.PipelineDepthStencilStateCreateInfo {
					sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
					depthTestEnable = true,
					depthWriteEnable = true,
					depthCompareOp = .LESS,
				},
				pColorBlendState = &vk.PipelineColorBlendStateCreateInfo {
					sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
					attachmentCount = 1,
					pAttachments = &vk.PipelineColorBlendAttachmentState {
						colorWriteMask = {.R, .G, .B, .A},
					},
				},
				pDynamicState = &vk.PipelineDynamicStateCreateInfo {
					sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
					dynamicStateCount = len(dynamicStates),
					pDynamicStates = raw_data(dynamicStates[:]),
				},
				layout = p.layout,
			},
			nil,
			&p.graphicsPipeline,
		),
	)


	return p
}


pipeline_data_delete :: proc(p: vkh.PipelineData) {
	if p.descriptorSetLayout != {} do vk.DestroyDescriptorSetLayout(vkh.device, p.descriptorSetLayout, nil)

	if p.layout != {} do vk.DestroyPipelineLayout(vkh.device, p.layout, nil)

	if p.graphicsPipeline != {} do vk.DestroyPipeline(vkh.device, p.graphicsPipeline, nil)

}

// is_point_visible :: proc(chunk: ^Chunk, x, y, z: int) -> bool {
// 	p := chunk.points[x][y][z]
// 	if p.type == .Air {
// 		return false
// 	}

// 	dirs := [][3]int{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}

// 	for d in dirs {
// 		nx := x + d[0]
// 		ny := y + d[1]
// 		nz := z + d[2]

// 		if nx < 0 ||
// 		   nx >= POINTS_PER_X_DIR ||
// 		   ny < 0 ||
// 		   ny >= POINTS_PER_Y_DIR ||
// 		   nz < 0 ||
// 		   nz >= POINTS_PER_Z_DIR {
// 			return true
// 		}

// 		if chunk.points[nx][ny][nz].type == .Air {
// 			return true
// 		}
// 	}

// 	return false
// }

// get_visible_points :: proc(chunk: ^Chunk, alloc := context.temp_allocator) -> [dynamic]int3 {
// 	visibles := make([dynamic]int3, 0, alloc)

// 	for x in 0 ..< POINTS_PER_X_DIR {
// 		for y in 0 ..< POINTS_PER_Y_DIR {
// 			for z in 0 ..< POINTS_PER_Z_DIR {
// 				if is_point_visible(chunk, x, y, z) {
// 					append(&visibles, int3{i32(x), i32(y), i32(z)})
// 				}
// 			}
// 		}
// 	}

// 	return visibles
// }

triangle_decide_color :: proc "contextless" (points: [3]u16) -> [4]f32 {
	// for p in points do assert(is_valid_point_u16(p) && p != 0)

	pointTypes: [3]PointType
	for p, i in points do pointTypes[i] = u16_to_point_type(p)
	// assert(is_valid_point_u16())%
	finalColor := [3]f32{0, 0, 0}

	for i in 0 ..< 3 {
		base := Random_Colors_Per_Point_Type[pointTypes[i]]

		energy := energy_to_color(points[i])

		combined := [3]f32 {
			base[0] * 0.9 + energy[0] * 0.1,
			base[1] * 0.9 + energy[1] * 0.1,
			base[2] * 0.9 + energy[2] * 0.1,
		}

		finalColor[0] += combined[0]
		finalColor[1] += combined[1]
		finalColor[2] += combined[2]
	}

	finalColor[0] /= 3.0
	finalColor[1] /= 3.0
	finalColor[2] /= 3.0

	return {finalColor[0], finalColor[1], finalColor[2], 1}
}
energy_to_color :: proc "contextless" (p: u16) -> [3]f32 {
	light := f32(get_light(p)) / 3.0
	life := f32(get_life(p)) / 3.0
	wisdom := f32(get_wisdom(p)) / 3.0

	// Light → yellow (1,1,0)
	// Life  → green  (0,1,0)
	// Wisdom→ blue   (0,0,1)

	return {
		light, // R
		light + life, // G
		wisdom, // B
	}
}
hash_i32 :: proc(x, y, z: i32, seed: u64) -> i32 {
	h := seed
	h ~= u64(x) * 0x9e3779b97f4a7c15
	h ~= u64(y) * 0x6c62272e07bb0142
	h ~= u64(z) * 0xd2a98b26625eee7b
	h = (h ~ (h >> 30)) * 0xbf58476d1ce4e5b9
	h = (h ~ (h >> 27)) * 0x94d049bb133111eb
	h ~= h >> 31
	return i32(h)
}
