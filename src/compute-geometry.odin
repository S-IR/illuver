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
chunkGeometryCalcPipeline: vkh.PipelineData

ChunkComputeCounterElement :: struct {
	totalOpaquePoints, totalTransparentPoints: u32,
}
chunk_geometry_calc_pipeline_init :: proc() -> (p: vkh.PipelineData) {
	bindings := [4]vk.DescriptorSetLayoutBinding {
		{
			binding = 0,
			descriptorType = .STORAGE_BUFFER,
			descriptorCount = 1,
			stageFlags = {.COMPUTE},
		}, // points
		{
			binding = 1,
			descriptorType = .STORAGE_BUFFER,
			descriptorCount = 1,
			stageFlags = {.COMPUTE},
		}, // verts
		{
			binding = 2,
			descriptorType = .STORAGE_BUFFER,
			descriptorCount = 1,
			stageFlags = {.COMPUTE},
		}, // counter
		{
			binding = 3,
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


	COMP_SPV :: #load("../build/shader-binaries/mesh-gen.compute.spv")
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

	if chunk.buffers.compute.counter.buffer == {} {
		vkh.chk(
			vma.create_buffer(
				vkh.allocator,
				vk.BufferCreateInfo {
					sType = .BUFFER_CREATE_INFO,
					size = vk.DeviceSize(size_of(ChunkComputeCounterElement)),
					usage = {.STORAGE_BUFFER, .TRANSFER_DST},
				},
				{
					flags = {.Host_Access_Sequential_Write, .Mapped},
					required_flags = {.HOST_VISIBLE},
				},
				&chunk.buffers.compute.counter.buffer,
				&chunk.buffers.compute.counter.alloc,
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
					size = vk.DeviceSize(VERTEX_BUFFER_SIZE),
					usage = {.STORAGE_BUFFER, .TRANSFER_SRC},
				},
				{usage = .Auto, flags = {.Mapped, .Host_Access_Sequential_Write}},
				&chunk.buffers.compute.stagingVertices.buffer,
				&chunk.buffers.compute.stagingVertices.alloc,
				nil,
			),
		)
	}


}
chunk_geometry_calculate :: proc(
	chunk: ^Chunk,
	state: ^ChunkWorkerState,
	pipeline: vkh.PipelineData,
) {
	if chunk.points == {} do return
	vk.WaitForFences(vkh.device, 1, &state.computeFence, true, max(u64))
	vk.ResetFences(vkh.device, 1, &state.computeFence)

	vk.ResetCommandBuffer(state.computeCB, {})
	vk.BeginCommandBuffer(
		state.computeCB,
		&vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}},
	)

	zero := u32(0)
	vk.CmdFillBuffer(
		state.computeCB,
		chunk.buffers.compute.counter.buffer,
		0,
		vk.DeviceSize(vk.WHOLE_SIZE),
		zero,
	)

	barrier := vk.BufferMemoryBarrier {
		sType         = .BUFFER_MEMORY_BARRIER,
		srcAccessMask = {.TRANSFER_WRITE},
		dstAccessMask = {.SHADER_READ, .SHADER_WRITE},
		buffer        = chunk.buffers.compute.counter.buffer,
		size          = vk.DeviceSize(vk.WHOLE_SIZE),
	}
	vk.CmdPipelineBarrier(
		state.computeCB,
		{.TRANSFER},
		{.COMPUTE_SHADER},
		{},
		0,
		nil,
		1,
		&barrier,
		0,
		nil,
	)

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
	vk.CmdPipelineBarrier(
		state.computeCB,
		{.HOST},
		{.COMPUTE_SHADER},
		{},
		0,
		nil,
		1,
		&barrier2,
		0,
		nil,
	)

	assert(chunk.pos.x % CHUNK_STRIDE_XZ == 0)
	assert(chunk.pos.y % CHUNK_STRIDE_Y == 0)
	assert(chunk.pos.z % CHUNK_STRIDE_XZ == 0)

	uniforms := ComputeMeshUniforms {
		chunkMin = {chunk.pos.x, chunk.pos.y, chunk.pos.z, 0},
		seed     = u32(gs.seed),
	}

	uniformPtr: rawptr
	vkh.chk(vma.map_memory(vkh.allocator, chunk.buffers.compute.uniform.alloc, &uniformPtr))
	mem.copy(uniformPtr, &uniforms, size_of(ComputeMeshUniforms))
	vma.unmap_memory(vkh.allocator, chunk.buffers.compute.uniform.alloc)

	vk.CmdBindPipeline(state.computeCB, .COMPUTE, pipeline.pipeline)

	writes := [4]vk.WriteDescriptorSet {
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstBinding = 0,
			descriptorCount = 1,
			descriptorType = .STORAGE_BUFFER,
			pBufferInfo = &vk.DescriptorBufferInfo {
				buffer = chunk.buffers.compute.pointsInput.buffer,
				range = vk.DeviceSize(vk.WHOLE_SIZE),
			},
		},
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstBinding = 1,
			descriptorCount = 1,
			descriptorType = .STORAGE_BUFFER,
			pBufferInfo = &vk.DescriptorBufferInfo {
				buffer = chunk.buffers.compute.stagingVertices.buffer,
				range = vk.DeviceSize(vk.WHOLE_SIZE),
			},
		},
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstBinding = 2,
			descriptorCount = 1,
			descriptorType = .STORAGE_BUFFER,
			pBufferInfo = &vk.DescriptorBufferInfo {
				buffer = chunk.buffers.compute.counter.buffer,
				range = vk.DeviceSize(vk.WHOLE_SIZE),
			},
		},
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstBinding = 3,
			descriptorCount = 1,
			descriptorType = .UNIFORM_BUFFER,
			pBufferInfo = &vk.DescriptorBufferInfo {
				buffer = chunk.buffers.compute.uniform.buffer,
				range = vk.DeviceSize(vk.WHOLE_SIZE),
			},
		},
	}
	vk.CmdPushDescriptorSetKHR(
		state.computeCB,
		.COMPUTE,
		pipeline.layout,
		0,
		len(writes),
		raw_data(writes[:]),
	)

	outBarriers := [1]vk.BufferMemoryBarrier {
		{
			sType = .BUFFER_MEMORY_BARRIER,
			srcAccessMask = {.SHADER_WRITE},
			dstAccessMask = {.TRANSFER_READ},
			buffer = chunk.buffers.compute.stagingVertices.buffer,
			size = vk.DeviceSize(vk.WHOLE_SIZE),
		},
	}
	vk.CmdDispatch(
		state.computeCB,
		(u32(CUBES_PER_X_DIR) + 7) / 8,
		(u32(CUBES_PER_Y_DIR) + 7) / 8,
		(u32(CUBES_PER_Z_DIR) + 7) / 8,
	)

	vk.CmdPipelineBarrier(
		state.computeCB,
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

	vk.EndCommandBuffer(state.computeCB)

	cmdBufInfo := vk.CommandBufferSubmitInfo {
		sType         = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = state.computeCB,
	}
	submitInfo := vk.SubmitInfo2 {
		sType                  = .SUBMIT_INFO_2,
		commandBufferInfoCount = 1,
		pCommandBufferInfos    = &cmdBufInfo,
	}
	sync.mutex_lock(&vkh.computeQueueMutex)
	vk.QueueSubmit2(vkh.computeQueue, 1, &submitInfo, state.computeFence)
	sync.mutex_unlock(&vkh.computeQueueMutex)

	vk.WaitForFences(vkh.device, 1, &state.computeFence, true, max(u64))
	// vk.ResetFences(vkh.device, 1, &state.computeFence)

	countersPtr: rawptr
	vma.map_memory(vkh.allocator, chunk.buffers.compute.counter.alloc, &countersPtr)
	counts := (^ChunkComputeCounterElement)(countersPtr)
	chunk.totalOpaquePoints = counts.totalOpaquePoints
	assert(chunk.totalOpaquePoints <= u32(MAX_OPAQUE_VERTS), "opaque vertex overflow")
	chunk.totalTransparentPoints = counts.totalTransparentPoints
	assert(chunk.totalTransparentPoints <= u32(MAX_TRANSPARENT_VERTS), "transparent vertex overflow")

	vma.unmap_memory(vkh.allocator, chunk.buffers.compute.counter.alloc)

}
chunk_copy_current_to_other_frames :: proc(
	chunk: ^Chunk,
	state: ^ChunkWorkerState,
	currentFrame: u32,
) {
	if chunk.totalOpaquePoints == 0 && chunk.totalTransparentPoints == 0 do return
	vk.ResetCommandBuffer(state.computeCB, {})
	vk.BeginCommandBuffer(
		state.computeCB,
		&vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}},
	)

	barriers: [vkh.MAX_FRAMES_IN_FLIGHT]vk.BufferMemoryBarrier

	for i in 0 ..< vkh.MAX_FRAMES_IN_FLIGHT {
		vk.CmdCopyBuffer(
			state.computeCB,
			chunk.buffers.compute.stagingVertices.buffer,
			chunk.buffers.vertices[i].buffer,
			1,
			&vk.BufferCopy{size = vk.DeviceSize(VERTEX_BUFFER_SIZE)},
		)
		barriers[i] = {
			sType         = .BUFFER_MEMORY_BARRIER,
			srcAccessMask = {.TRANSFER_WRITE},
			dstAccessMask = {.VERTEX_ATTRIBUTE_READ},
			buffer        = chunk.buffers.vertices[i].buffer,
			size          = vk.DeviceSize(vk.WHOLE_SIZE),
		}
	}

	vk.CmdPipelineBarrier(
		state.computeCB,
		{.TRANSFER},
		{.VERTEX_INPUT, .FRAGMENT_SHADER},
		{},
		0,
		nil,
		u32(len(barriers)),
		raw_data(barriers[:]),
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
		waitSemaphoreInfoCount   = 0,
		pWaitSemaphoreInfos      = nil,
		commandBufferInfoCount   = 1,
		pCommandBufferInfos      = &vk.CommandBufferSubmitInfo {
			sType = .COMMAND_BUFFER_SUBMIT_INFO,
			commandBuffer = state.computeCB,
		},
		signalSemaphoreInfoCount = u32(signalCount),
		pSignalSemaphoreInfos    = raw_data(signalInfos[:signalCount]),
	}
	vk.ResetFences(vkh.device, 1, &state.computeFence)
	vkh.chk(vk.QueueSubmit2(vkh.computeQueue, 1, &submitInfo, state.computeFence))
}
chunk_geometry_calc_buffers_destroy :: proc(chunk: ^Chunk) {
	if chunk.buffers.compute.pointsInput.buffer != {} do vma.destroy_buffer(vkh.allocator, chunk.buffers.compute.pointsInput.buffer, chunk.buffers.compute.pointsInput.alloc)
	if chunk.buffers.compute.counter.buffer != {} do vma.destroy_buffer(vkh.allocator, chunk.buffers.compute.counter.buffer, chunk.buffers.compute.counter.alloc)
	if chunk.buffers.compute.uniform.buffer != {} do vma.destroy_buffer(vkh.allocator, chunk.buffers.compute.uniform.buffer, chunk.buffers.compute.uniform.alloc)

	if chunk.buffers.compute.stagingVertices.buffer != {} do vma.destroy_buffer(vkh.allocator, chunk.buffers.compute.stagingVertices.buffer, chunk.buffers.compute.stagingVertices.alloc)


}
