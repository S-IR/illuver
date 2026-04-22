package main
import "../modules/vma"
import "core:fmt"
import "core:mem"
import "core:sync"
import "gs"
import vk "vendor:vulkan"
import "vkh"
ComputeMeshUniforms :: struct {
	chunkMin: [4]i32, // pad to vec4
	seed:     u32,
}
computeMeshPipeline: vkh.PipelineData

compute_mesh_gen_pipeline_init :: proc() -> (p: vkh.PipelineData) {
	bindings := [5]vk.DescriptorSetLayoutBinding {
		{
			binding = 0,
			descriptorType = .STORAGE_BUFFER,
			descriptorCount = 1,
			stageFlags = {.COMPUTE},
		}, // points (u16[])
		{
			binding = 1,
			descriptorType = .STORAGE_BUFFER,
			descriptorCount = 1,
			stageFlags = {.COMPUTE},
		}, // vertices
		{
			binding = 2,
			descriptorType = .STORAGE_BUFFER,
			descriptorCount = 1,
			stageFlags = {.COMPUTE},
		}, // colors
		{
			binding = 3,
			descriptorType = .STORAGE_BUFFER,
			descriptorCount = 1,
			stageFlags = {.COMPUTE},
		}, // atomic counters
		{
			binding = 4,
			descriptorType = .UNIFORM_BUFFER,
			descriptorCount = 1,
			stageFlags = {.COMPUTE},
		}, // uniform
	}
	vkh.chk(
		vk.CreateDescriptorSetLayout(
			vkh.device,
			&vk.DescriptorSetLayoutCreateInfo {
				sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
				bindingCount = len(bindings),
				pBindings = raw_data(bindings[:]),
				flags = {.PUSH_DESCRIPTOR_KHR},
			},
			nil,
			&p.descriptorSetLayout,
		),
	)

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


	COMP_SPV :: #load("../build/shader-binaries/mesh-gen.comp.spv")
	module := vkh.create_shader_module(vkh.device, COMP_SPV)
	defer vk.DestroyShaderModule(vkh.device, module, nil)

	vkh.chk(
		vk.CreateComputePipelines(
			vkh.device,
			{},
			1,
			&vk.ComputePipelineCreateInfo {
				sType = .COMPUTE_PIPELINE_CREATE_INFO,
				stage = {
					sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
					stage = {.COMPUTE},
					module = module,
					pName = "main",
				},
				layout = p.layout,
			},
			nil,
			&p.pipeline,
		),
	)

	return p

}

chunk_compute_dispatch :: proc(cb: vk.CommandBuffer, pipeline: vkh.PipelineData, chunk: ^Chunk) {

	assert(cb != {})
	assert(chunk != nil)

	zero := u32(0)
	vk.CmdFillBuffer(
		cb,
		chunk.buffers.compute.counters.buffer,
		0,
		vk.DeviceSize(vk.WHOLE_SIZE),
		zero,
	)

	barrier := vk.BufferMemoryBarrier {
		sType         = .BUFFER_MEMORY_BARRIER,
		srcAccessMask = {.TRANSFER_WRITE},
		dstAccessMask = {.SHADER_READ, .SHADER_WRITE},
		buffer        = chunk.buffers.compute.counters.buffer,
		size          = vk.DeviceSize(vk.WHOLE_SIZE),
	}
	vk.CmdPipelineBarrier(cb, {.TRANSFER}, {.COMPUTE_SHADER}, {}, 0, nil, 1, &barrier, 0, nil)

	pointsPtr: rawptr
	vkh.chk(vma.map_memory(vkh.allocator, chunk.buffers.compute.pointsInput.alloc, &pointsPtr))
	mem.copy(pointsPtr, raw_data(chunk.points[:]), len(chunk.points) * size_of(u16))
	vma.unmap_memory(vkh.allocator, chunk.buffers.compute.pointsInput.alloc)

	barrier2 := vk.BufferMemoryBarrier {
		sType         = .BUFFER_MEMORY_BARRIER,
		srcAccessMask = {.HOST_WRITE},
		dstAccessMask = {.SHADER_READ},
		buffer        = chunk.buffers.compute.pointsInput.buffer,
		size          = vk.DeviceSize(vk.WHOLE_SIZE),
	}
	vk.CmdPipelineBarrier(cb, {.HOST}, {.COMPUTE_SHADER}, {}, 0, nil, 1, &barrier2, 0, nil)

	uniforms := ComputeMeshUniforms {
		chunkMin = {chunk.pos[0], MIN_Y, chunk.pos[1], 0},
		seed     = u32(gs.seed),
	}

	ptr: rawptr
	vkh.chk(vma.map_memory(vkh.allocator, chunk.buffers.compute.uniform.alloc, &ptr))
	mem.copy(ptr, &uniforms, size_of(ComputeMeshUniforms))
	vma.unmap_memory(vkh.allocator, chunk.buffers.compute.uniform.alloc)

	vk.CmdBindPipeline(cb, .COMPUTE, pipeline.pipeline)


	writes := [5]vk.WriteDescriptorSet {
		{ 	// binding 0: pointsInput
			sType           = .WRITE_DESCRIPTOR_SET,
			dstBinding      = 0,
			descriptorCount = 1,
			descriptorType  = .STORAGE_BUFFER,
			pBufferInfo     = &vk.DescriptorBufferInfo {
				buffer = chunk.buffers.compute.pointsInput.buffer,
				range = vk.DeviceSize(vk.WHOLE_SIZE),
			},
		},
		{ 	// binding 1: stagingVertices
			sType           = .WRITE_DESCRIPTOR_SET,
			dstBinding      = 1,
			descriptorCount = 1,
			descriptorType  = .STORAGE_BUFFER,
			pBufferInfo     = &vk.DescriptorBufferInfo {
				buffer = chunk.buffers.compute.stagingVertices.buffer,
				range = vk.DeviceSize(vk.WHOLE_SIZE),
			},
		},
		{ 	// binding 2: stagingColors
			sType           = .WRITE_DESCRIPTOR_SET,
			dstBinding      = 2,
			descriptorCount = 1,
			descriptorType  = .STORAGE_BUFFER,
			pBufferInfo     = &vk.DescriptorBufferInfo {
				buffer = chunk.buffers.compute.stagingColors.buffer,
				range = vk.DeviceSize(vk.WHOLE_SIZE),
			},
		},
		{ 	// binding 3: counters
			sType           = .WRITE_DESCRIPTOR_SET,
			dstBinding      = 3,
			descriptorCount = 1,
			descriptorType  = .STORAGE_BUFFER,
			pBufferInfo     = &vk.DescriptorBufferInfo {
				buffer = chunk.buffers.compute.counters.buffer,
				range = vk.DeviceSize(vk.WHOLE_SIZE),
			},
		},
		{ 	// binding 4: uniform
			sType           = .WRITE_DESCRIPTOR_SET,
			dstBinding      = 4,
			descriptorCount = 1,
			descriptorType  = .UNIFORM_BUFFER,
			pBufferInfo     = &vk.DescriptorBufferInfo {
				buffer = chunk.buffers.compute.uniform.buffer,
				range = vk.DeviceSize(vk.WHOLE_SIZE),
			},
		},
	}
	vk.CmdPushDescriptorSetKHR(cb, .COMPUTE, pipeline.layout, 0, len(writes), raw_data(writes[:]))


	outBarriers := [2]vk.BufferMemoryBarrier {
		{
			sType = .BUFFER_MEMORY_BARRIER,
			srcAccessMask = {.SHADER_WRITE},
			dstAccessMask = {.TRANSFER_READ},
			buffer = chunk.buffers.compute.stagingVertices.buffer,
			size = vk.DeviceSize(vk.WHOLE_SIZE),
		},
		{
			sType = .BUFFER_MEMORY_BARRIER,
			srcAccessMask = {.SHADER_WRITE},
			dstAccessMask = {.TRANSFER_READ},
			buffer = chunk.buffers.compute.stagingColors.buffer,
			size = vk.DeviceSize(vk.WHOLE_SIZE),
		},
	}
	vk.CmdDispatch(
		cb,
		(u32(CUBES_PER_X_DIR) + 7) / 8,
		(u32(CUBES_PER_Y_DIR) + 7) / 8,
		(u32(CUBES_PER_Z_DIR) + 7) / 8,
	)

	vk.CmdPipelineBarrier(
		cb,
		{.COMPUTE_SHADER},
		{.TRANSFER},
		{},
		0,
		nil,
		len(outBarriers),
		raw_data(outBarriers[:]),
		0,
		nil,
	)

}
chunk_geometry_calc_buffers_create :: proc(chunk: ^Chunk) {

	if chunk.buffers.compute.pointsInput.buffer == {} {

		vkh.chk(
			vma.create_buffer(
				vkh.allocator,
				vk.BufferCreateInfo {
					sType = .BUFFER_CREATE_INFO,
					size = vk.DeviceSize(MAX_POINTS * size_of(u16)),
					usage = {.STORAGE_BUFFER, .TRANSFER_DST},
				},
				{usage = .Auto, flags = {.Mapped, .Host_Access_Sequential_Write}},
				&chunk.buffers.compute.pointsInput.buffer,
				&chunk.buffers.compute.pointsInput.alloc,
				nil,
			),
		)
	}

	if chunk.buffers.compute.counters.buffer == {} {
		vkh.chk(
			vma.create_buffer(
				vkh.allocator,
				vk.BufferCreateInfo {
					sType = .BUFFER_CREATE_INFO,
					size = vk.DeviceSize(2 * size_of(u32)),
					usage = {.STORAGE_BUFFER, .TRANSFER_DST},
				},
				{
					flags = {.Host_Access_Sequential_Write, .Mapped},
					required_flags = {.HOST_VISIBLE},
				},
				&chunk.buffers.compute.counters.buffer,
				&chunk.buffers.compute.counters.alloc,
				nil,
			),
		)
	}

	if chunk.buffers.compute.uniform.buffer == {} {
		vkh.chk(
			vma.create_buffer(
				vkh.allocator,
				vk.BufferCreateInfo {
					sType = .BUFFER_CREATE_INFO,
					size = vk.DeviceSize(size_of(ComputeMeshUniforms)),
					usage = {.UNIFORM_BUFFER},
				},
				{
					flags = {.Host_Access_Sequential_Write, .Mapped},
					required_flags = {.HOST_VISIBLE},
				},
				&chunk.buffers.compute.uniform.buffer,
				&chunk.buffers.compute.uniform.alloc,
				nil,
			),
		)
	}

	if chunk.buffers.compute.stagingVertices.buffer == {} {
		vkh.chk(
			vma.create_buffer(
				vkh.allocator,
				{
					sType = .BUFFER_CREATE_INFO,
					size = vk.DeviceSize(MAX_INDICES * size_of([3]f32)),
					usage = {.STORAGE_BUFFER, .TRANSFER_SRC},
				},
				{usage = .Auto, flags = {.Mapped, .Host_Access_Sequential_Write}},
				&chunk.buffers.compute.stagingVertices.buffer,
				&chunk.buffers.compute.stagingVertices.alloc,
				nil,
			),
		)
	}


	// Staging color buffer (size = MAX_COLORS * sizeof(float4))
	//
	if chunk.buffers.compute.stagingColors.buffer == {} {
		vkh.chk(
			vma.create_buffer(
				vkh.allocator,
				{
					sType = .BUFFER_CREATE_INFO,
					size = vk.DeviceSize(MAX_COLORS * size_of([4]f32)),
					usage = {.STORAGE_BUFFER, .TRANSFER_SRC},
				},
				{usage = .Auto, flags = {.Mapped, .Host_Access_Sequential_Write}},
				&chunk.buffers.compute.stagingColors.buffer,
				&chunk.buffers.compute.stagingColors.alloc,
				nil,
			),
		)
	}


}
chunk_generate_gpu :: proc(chunk: ^Chunk, state: ^ChunkWorkerState, pipeline: vkh.PipelineData) {
	vk.WaitForFences(vkh.device, 1, &state.computeFence, true, max(u64))
	vk.ResetFences(vkh.device, 1, &state.computeFence)

	vk.ResetCommandBuffer(state.computeCB, {})
	vk.BeginCommandBuffer(
		state.computeCB,
		&vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}},
	)

	chunk_compute_dispatch(state.computeCB, pipeline, chunk)

	vk.EndCommandBuffer(state.computeCB)


	submitInfo := vk.SubmitInfo {
		sType              = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers    = &state.computeCB,
	}
	sync.mutex_lock(&vkh.computeQueueMutex)
	vk.QueueSubmit(vkh.computeQueue, 1, &submitInfo, state.computeFence)
	sync.mutex_unlock(&vkh.computeQueueMutex)
	vk.WaitForFences(vkh.device, 1, &state.computeFence, true, max(u64))

	ptr: rawptr
	vma.map_memory(vkh.allocator, chunk.buffers.compute.counters.alloc, &ptr)
	counts := (^[2]u32)(ptr)
	chunk.totalPoints = counts[0]
	chunk.totalTriangles = counts[1]
	assert(chunk.totalPoints > 0)
	assert(chunk.totalTriangles > 0)

	vma.unmap_memory(vkh.allocator, chunk.buffers.compute.counters.alloc)


}
chunk_copy_current_to_other_frames :: proc(
	chunk: ^Chunk,
	state: ^ChunkWorkerState,
	currentFrame: u32, // now passed from job data, not read globally
) {
	assert(chunk.totalPoints > 0)

	vk.WaitForFences(vkh.device, 1, &state.computeFence, true, max(u64))
	vk.ResetFences(vkh.device, 1, &state.computeFence)

	vk.ResetCommandBuffer(state.computeCB, {})
	vk.BeginCommandBuffer(
		state.computeCB,
		&vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}},
	)

	srcVert := chunk.buffers.compute.stagingVertices.buffer
	srcColor := chunk.buffers.compute.stagingColors.buffer
	copySizeVert := vk.DeviceSize(chunk.totalPoints * size_of([3]f32))
	copySizeColor := vk.DeviceSize(chunk.totalTriangles * size_of([4]f32))

	barrierCount := 0
	barriers: [vkh.MAX_FRAMES_IN_FLIGHT * 2]vk.BufferMemoryBarrier

	for i in 0 ..< vkh.MAX_FRAMES_IN_FLIGHT {
		vk.CmdCopyBuffer(
			state.computeCB,
			srcVert,
			chunk.buffers.vertices[i].buffer,
			1,
			&vk.BufferCopy{size = copySizeVert},
		)
		vk.CmdCopyBuffer(
			state.computeCB,
			srcColor,
			chunk.buffers.colors[i].buffer,
			1,
			&vk.BufferCopy{size = copySizeColor},
		)

		barriers[barrierCount] = {
			sType         = .BUFFER_MEMORY_BARRIER,
			srcAccessMask = {.TRANSFER_WRITE},
			dstAccessMask = {.VERTEX_ATTRIBUTE_READ},
			buffer        = chunk.buffers.vertices[i].buffer,
			size          = vk.DeviceSize(vk.WHOLE_SIZE),
		}
		barrierCount += 1
		barriers[barrierCount] = {
			sType         = .BUFFER_MEMORY_BARRIER,
			srcAccessMask = {.TRANSFER_WRITE},
			dstAccessMask = {.SHADER_READ},
			buffer        = chunk.buffers.colors[i].buffer,
			size          = vk.DeviceSize(vk.WHOLE_SIZE),
		}
		barrierCount += 1
	}

	vk.CmdPipelineBarrier(
		state.computeCB,
		{.TRANSFER},
		{.VERTEX_INPUT, .FRAGMENT_SHADER},
		{},
		0,
		nil,
		u32(barrierCount),
		raw_data(barriers[:barrierCount]),
		0,
		nil,
	)

	vk.EndCommandBuffer(state.computeCB)

	signalInfos: [vkh.MAX_FRAMES_IN_FLIGHT]vk.SemaphoreSubmitInfo
	signalCount := 0

	sync.mutex_lock(&vkh.computeQueueMutex)
	defer sync.mutex_unlock(&vkh.computeQueueMutex)

	for i in 0 ..< vkh.MAX_FRAMES_IN_FLIGHT {
		vkh.copyTimelineValue += 1
		nextValue := vkh.copyTimelineValue

		signalInfos[signalCount] = {
			sType     = .SEMAPHORE_SUBMIT_INFO,
			semaphore = vkh.copyTimelineSemaphore,
			value     = nextValue,
			stageMask = {.TRANSFER},
		}
		signalCount += 1
		chunk.copyTimelineValue[i] = nextValue
	}

	submitInfo := vk.SubmitInfo2 {
		sType                    = .SUBMIT_INFO_2,
		commandBufferInfoCount   = 1,
		pCommandBufferInfos      = &vk.CommandBufferSubmitInfo {
			sType = .COMMAND_BUFFER_SUBMIT_INFO,
			commandBuffer = state.computeCB,
		},
		signalSemaphoreInfoCount = u32(signalCount),
		pSignalSemaphoreInfos    = raw_data(signalInfos[:signalCount]),
	}

	vkh.chk(vk.QueueSubmit2(vkh.computeQueue, 1, &submitInfo, state.computeFence))
}
chunk_geometry_calc_buffers_destroy :: proc(chunk: ^Chunk) {
	if chunk.buffers.compute.pointsInput.buffer != {} do vma.destroy_buffer(vkh.allocator, chunk.buffers.compute.pointsInput.buffer, chunk.buffers.compute.pointsInput.alloc)
	if chunk.buffers.compute.counters.buffer != {} do vma.destroy_buffer(vkh.allocator, chunk.buffers.compute.counters.buffer, chunk.buffers.compute.counters.alloc)
	if chunk.buffers.compute.uniform.buffer != {} do vma.destroy_buffer(vkh.allocator, chunk.buffers.compute.uniform.buffer, chunk.buffers.compute.uniform.alloc)

	if chunk.buffers.compute.stagingColors.buffer != {} do vma.destroy_buffer(vkh.allocator, chunk.buffers.compute.stagingColors.buffer, chunk.buffers.compute.stagingColors.alloc)
	if chunk.buffers.compute.stagingVertices.buffer != {} do vma.destroy_buffer(vkh.allocator, chunk.buffers.compute.stagingVertices.buffer, chunk.buffers.compute.stagingVertices.alloc)


}
