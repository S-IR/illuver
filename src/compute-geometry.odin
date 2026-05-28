package main
import "../modules/tracy"
import "../modules/vma"
import "core:fmt"
import "core:math/linalg"
import "core:mem"
import "core:simd"
import "core:sync"
import "gs"
import vk "vendor:vulkan"
import "vkh"

ComputeMeshUniforms :: struct {
	chunkMin: [4]i32, // pad to vec4
	seed:     u32,
}
chunkGeometryCalcPipeline: vkh.PipelineData


chunk_geometry_calc_pipeline_init :: proc() -> (p: vkh.PipelineData) {
	tracy.Zone()

	bindings := [5]vk.DescriptorSetLayoutBinding {
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
		{
			binding = 4,
			descriptorType = .STORAGE_BUFFER,
			descriptorCount = 1,
			stageFlags = {.COMPUTE},
		}, // indices
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
	tracy.Zone()

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
	if chunk.buffers.compute.stagingIndices.buffer == {} {
		vkh.chk(
			vma.create_buffer(
				vkh.allocator,
				{
					sType = .BUFFER_CREATE_INFO,
					size = vk.DeviceSize(INDEX_BUFFER_SIZE),
					usage = {.STORAGE_BUFFER, .TRANSFER_SRC},
				},
				{usage = .Auto, flags = {.Mapped, .Host_Access_Sequential_Write}},
				&chunk.buffers.compute.stagingIndices.buffer,
				&chunk.buffers.compute.stagingIndices.alloc,
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
	tracy.Zone()

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

	writes := [5]vk.WriteDescriptorSet {
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
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstBinding = 4,
			descriptorCount = 1,
			descriptorType = .STORAGE_BUFFER,
			pBufferInfo = &vk.DescriptorBufferInfo {
				buffer = chunk.buffers.compute.stagingIndices.buffer,
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
			buffer = chunk.buffers.compute.stagingIndices.buffer,
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
	chunk.pointTotal = counts^

	//TODO: have some ductape here in emergy case that the transparent buffer is too small
	ensure(chunk.pointTotal.opaque <= MAX_OPAQUE_INDICES)
	ensure(chunk.pointTotal.transparent <= MAX_TRANSPARENT_INDICES)

	vma.unmap_memory(vkh.allocator, chunk.buffers.compute.counter.alloc)

}
chunk_geometry_calculate_cpu :: proc(chunk: ^Chunk) {
	tracy.Zone()
	if chunk.points == {} do return
	vertexMapper: [MAX_VERTS]u32 = ---
	mem.set(
		raw_data(mem.slice_to_bytes(vertexMapper[:])),
		0xFF,
		len(vertexMapper) * size_of(vertexMapper[0]),
	)

	vertsPtr, indicesPtr, counterPtr: rawptr
	vma.map_memory(vkh.allocator, chunk.buffers.compute.stagingVertices.alloc, &vertsPtr)
	vma.map_memory(vkh.allocator, chunk.buffers.compute.stagingIndices.alloc, &indicesPtr)
	vma.map_memory(vkh.allocator, chunk.buffers.compute.counter.alloc, &counterPtr)
	defer {
		vma.unmap_memory(vkh.allocator, chunk.buffers.compute.stagingVertices.alloc)
		vma.unmap_memory(vkh.allocator, chunk.buffers.compute.stagingIndices.alloc)
		vma.unmap_memory(vkh.allocator, chunk.buffers.compute.counter.alloc)
	}
	verts := mem.slice_ptr((^PointVertexInput)(vertsPtr), int(MAX_VERTS))
	indices := mem.slice_ptr((^INDEX_TYPE_USED_IN_CHUNKS)(indicesPtr), int(MAX_INDICES))
	counts := (^ChunkComputeCounterElement)(counterPtr)
	counts^ = {}
	vertCount: u32 = 0

	pts := raw_data(chunk.points[:])
	seed := u32(gs.seed)
	cmin := chunk.pos
	get_pt :: #force_inline proc "contextless" (pts: [^]u16, c: [3]i32) -> u16 {
		if c.x < 0 || c.x >= VERTS_PER_X_DIR do return 0
		if c.y < 0 || c.y >= VERTS_PER_Y_DIR do return 0
		if c.z < 0 || c.z >= VERTS_PER_Z_DIR do return 0
		#no_bounds_check {
			return pts[c.x * VERT_STRIDE_X + c.y * VERT_STRIDE_Y + c.z]
		}
	}
	U32_INVALID :: u32(0xFFFFFFFF)
	get_or_add :: proc(
		mapper: []INDEX_TYPE_USED_IN_CHUNKS,
		verts: []PointVertexInput,
		vertCount: ^u32,
		local: [3]i32,
		cmin: [3]i32,
		pointVal: u16,
		seed: u32,
	) -> u32 {
		#no_bounds_check {
			cellIdx := index_into_point_arrays(local)
			if mapper[index_into_point_arrays(local)] != U32_INVALID do return mapper[cellIdx]
			w := cmin + local

			finalCoord := point_real_world_position(linalg.to_f32(w))

			verts[vertCount^] = {
				pos      = finalCoord,
				pointVal = u32(pointVal),
			}
			currIdx := vertCount^
			mapper[cellIdx] = currIdx

			vertCount^ += 1
			return currIdx
		}

	}

	cell := [3]i32{0, 0, 0}
	vertexMapperSlice := vertexMapper[:]

	#no_bounds_check for cell.x = 0; cell.x < CUBES_PER_X_DIR; cell.x += 1 {
		isEdgeX := cell.x == 0 || cell.x == CUBES_PER_X_DIR - 1

		for cell.z = 0; cell.z < CUBES_PER_Z_DIR; cell.z += 1 {
			isEdgeZ := cell.z == 0 || cell.z == CUBES_PER_Z_DIR - 1
			xzIdx := index_into_height_map(cell.xz)
			height := chunk.heightMap[xzIdx]
			cellIter: for cell.y = 0; (cell.y + chunk.pos.y) < height; cell.y += 1 {

				baseIndex := index_into_point_arrays(cell)
				pVal := pts[index_into_point_arrays(cell)]
				if pVal == 0 do continue

				isEdgeY := cell.y == 0 || (cell.y + chunk.pos.y == height - 1)

				isChunkEdge := isEdgeX || isEdgeY || isEdgeZ
				cellType := u16_to_point_type(pVal)


				typeMask8 := #simd[8]u16 {
					TYPE_MASK,
					TYPE_MASK,
					TYPE_MASK,
					TYPE_MASK,
					TYPE_MASK,
					TYPE_MASK,
					TYPE_MASK,
					TYPE_MASK,
				}
				airSimd8 := #simd[8]u16{}
				waterSimd8 := #simd[8]u16 {
					u16(PointType.Water),
					u16(PointType.Water),
					u16(PointType.Water),
					u16(PointType.Water),
					u16(PointType.Water),
					u16(PointType.Water),
					u16(PointType.Water),
					u16(PointType.Water),
				}

				checkForSkipRender: if !isChunkEdge {
					for p in pointsSimdNeighbors {
						ni := baseIndex + p
						neighbour := #simd[8]u16 {
							pts[simd.extract(ni, 0)],
							pts[simd.extract(ni, 1)],
							pts[simd.extract(ni, 2)],
							pts[simd.extract(ni, 3)],
							pts[simd.extract(ni, 4)],
							pts[simd.extract(ni, 5)],
							pts[simd.extract(ni, 6)],
							pts[simd.extract(ni, 7)],
						}
						typeVals := neighbour & typeMask8

						airEqMask := simd.lanes_eq(typeVals, airSimd8)
						anyAir := simd.reduce_or(airEqMask) != 0
						if anyAir do break checkForSkipRender

						waterEqMask := simd.lanes_eq(typeVals, waterSimd8)
						anyWater := simd.reduce_or(waterEqMask) != 0
						if anyWater do break checkForSkipRender

					}
					lVal := pts[baseIndex + pointsNeighbourLeftCoords]
					rVal := pts[baseIndex + pointsNeighbourRightCoords]
					lType, rType := u16_to_point_type(lVal), u16_to_point_type(rVal)
					if lType == .Air || is_transparent_point(lType) do break checkForSkipRender
					if rType == .Air || is_transparent_point(rType) do break checkForSkipRender

					continue cellIter

				}

				triVerts := [6][3][3]i32 {
					{{0, 0, 0}, {1, 1, 0}, {1, 0, 0}},
					{{0, 0, 0}, {0, 1, 0}, {1, 1, 0}},
					{{0, 0, 0}, {0, 0, 1}, {0, 1, 1}},
					{{0, 0, 0}, {0, 1, 1}, {0, 1, 0}},
					{{0, 0, 0}, {1, 0, 0}, {1, 0, 1}},
					{{0, 0, 0}, {1, 0, 1}, {0, 0, 1}},
				}

				for tri in triVerts {
					c0, c1, c2 := cell + tri[0], cell + tri[1], cell + tri[2]
					p0, p1, p2 := get_pt(pts, c0), get_pt(pts, c1), get_pt(pts, c2)
					t0, t1, t2 :=
						u16_to_point_type(p0), u16_to_point_type(p1), u16_to_point_type(p2)

					if t0 == .Air || t1 == .Air || t2 == .Air do continue
					tc :=
						(is_transparent_point(t0) ? 1 : 0) +
						(is_transparent_point(t1) ? 1 : 0) +
						(is_transparent_point(t2) ? 1 : 0)

					if tc > 0 && tc < 3 do continue
					isTransp := tc == 3

					i0 := get_or_add(vertexMapperSlice, verts, &vertCount, c0, cmin, p0, seed)
					i1 := get_or_add(vertexMapperSlice, verts, &vertCount, c1, cmin, p1, seed)
					i2 := get_or_add(vertexMapperSlice, verts, &vertCount, c2, cmin, p2, seed)

					if !isTransp {
						iIdx := counts.opaque
						indices[iIdx] = i0; indices[iIdx + 1] = i1; indices[iIdx + 2] = i2
						counts.opaque += 3
					} else {
						iIdx := MAX_OPAQUE_INDICES + counts.transparent
						indices[iIdx] = i0; indices[iIdx + 1] = i1; indices[iIdx + 2] = i2
						counts.transparent += 3
					}

				}

			}
		}
	}

	chunk.pointTotal = counts^
}


chunk_copy_current_to_other_frames :: proc(
	chunk: ^Chunk,
	state: ^ChunkWorkerState,
	currentFrame: u32,
) {
	if chunk.pointTotal == {} do return
	vk.WaitForFences(vkh.device, 1, &state.computeFence, true, max(u64))
	vk.ResetFences(vkh.device, 1, &state.computeFence)

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
		vk.CmdCopyBuffer(
			state.computeCB,
			chunk.buffers.compute.stagingIndices.buffer,
			chunk.buffers.indices[i].buffer,
			1,
			&vk.BufferCopy{size = vk.DeviceSize(INDEX_BUFFER_SIZE)},
		)

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
	if chunk.buffers.compute.stagingIndices.buffer != {} do vma.destroy_buffer(vkh.allocator, chunk.buffers.compute.stagingIndices.buffer, chunk.buffers.compute.stagingIndices.alloc)


}
