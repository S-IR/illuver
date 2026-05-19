package main
import "camera"
import "core:math/linalg"
import "gs"
import vk "vendor:vulkan"
import "vkh"

CSM_EXTENTS := [CSM_CASCADE_COUNT]f32 {
	40,
	150,
	450,
	f32(CHUNKS_PER_XZ_DIRECTION / 2 + 1) * f32(CHUNK_STRIDE_XZ),
}


//match the shader
CSM_SPLIT_DISTANCES :: [4]f32{40, 150, 450, f32(gs.farPlane)}

compute_cascade_light_vps :: proc(
	sunPos, cameraPos: [3]f32,
) -> [CSM_CASCADE_COUNT]matrix[4, 4]f32 {
	sunDir := linalg.normalize(sunPos)
	up := camera.WORLD_UP
	if abs(linalg.dot(sunDir, up)) > .99 do up = {1, 0, 0}


	lightView := linalg.matrix4_look_at_f32(sunDir * 500, cameraPos, up, true)

	result: [CSM_CASCADE_COUNT]matrix[4, 4]f32

	for i in 0 ..< CSM_CASCADE_COUNT {
		extent := CSM_EXTENTS[i]
		lightProj := linalg.matrix_ortho3d_f32(
			-extent,
			extent,
			-extent,
			extent,
			-gs.farPlane,
			gs.farPlane,
			true,
		)
		result[i] = lightProj * lightView

	}

	return result
}
shadow_pass :: proc(cb: vk.CommandBuffer, data: ^SunRenderData) {
	enterBarrier := [?]vk.ImageMemoryBarrier2 {
		{
			sType = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask = {.TOP_OF_PIPE},
			dstStageMask = {.EARLY_FRAGMENT_TESTS},
			dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
			oldLayout = .UNDEFINED,
			newLayout = .ATTACHMENT_OPTIMAL,
			image = data.shadow.image.image,
			subresourceRange = {
				aspectMask = {.DEPTH},
				levelCount = 1,
				layerCount = CSM_CASCADE_COUNT,
			},
		},
	}
	vk.CmdPipelineBarrier2(
		cb,
		&{
			sType = .DEPENDENCY_INFO,
			imageMemoryBarrierCount = len(enterBarrier),
			pImageMemoryBarriers = raw_data(enterBarrier[:]),
		},
	)
	for i in 0 ..< u32(CSM_CASCADE_COUNT) {
		vk.CmdBeginRendering(
			cb,
			&{
				sType = .RENDERING_INFO,
				renderArea = {extent = {width = SHADOW_MAP_SIZE, height = SHADOW_MAP_SIZE}},
				layerCount = 1,
				pDepthAttachment = &vk.RenderingAttachmentInfo {
					sType = .RENDERING_ATTACHMENT_INFO,
					imageView = data.shadow.layerViews[i],
					imageLayout = .ATTACHMENT_OPTIMAL,
					loadOp = .CLEAR,
					storeOp = .STORE,
					clearValue = {depthStencil = {1, 0}},
				},
			},
		)
		iForPtr := i
		chunks_draw_shadow(
			cb,
			data.shadow.pipeline,
			data.uboBuffers[vkh.frameIndex].buffer,
			&iForPtr,
		)
		vk.CmdEndRendering(cb)

	}
	exitBarrier := [?]vk.ImageMemoryBarrier2 {
		{
			sType = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask = {.LATE_FRAGMENT_TESTS},
			srcAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
			dstStageMask = {.FRAGMENT_SHADER},
			dstAccessMask = {.SHADER_READ},
			oldLayout = .ATTACHMENT_OPTIMAL,
			newLayout = .READ_ONLY_OPTIMAL,
			image = data.shadow.image.image,
			subresourceRange = {
				aspectMask = {.DEPTH},
				levelCount = 1,
				layerCount = CSM_CASCADE_COUNT,
			},
		},
	}

	vk.CmdPipelineBarrier2(
		cb,
		&{
			sType = .DEPENDENCY_INFO,
			imageMemoryBarrierCount = len(exitBarrier),
			pImageMemoryBarriers = raw_data(exitBarrier[:]),
		},
	)


}
