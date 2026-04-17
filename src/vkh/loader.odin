package vkh
import vk "vendor:vulkan"

loader_command_buffer_create :: proc() -> (cb: vk.CommandBuffer, fence: vk.Fence) {
	chk(
		vk.AllocateCommandBuffers(
			vkDevice,
			&vk.CommandBufferAllocateInfo {
				sType = .COMMAND_BUFFER_ALLOCATE_INFO,
				commandPool = vkCommandPool,
				commandBufferCount = 1,
			},
			&cb,
		),
	)
	chk(
		vk.BeginCommandBuffer(
			cb,
			&vk.CommandBufferBeginInfo {
				sType = .COMMAND_BUFFER_BEGIN_INFO,
				flags = {.ONE_TIME_SUBMIT},
			},
		),
	)

	chk(vk.CreateFence(vkDevice, &{sType = .FENCE_CREATE_INFO}, nil, &fence))
	return cb, fence
}
loader_command_buffer_wait_and_destroy :: proc(cb: vk.CommandBuffer, fence: vk.Fence) {

	chk(vk.EndCommandBuffer(cb))
	tempCbArr := [?]vk.CommandBuffer{cb}

	chk(
		vk.QueueSubmit(
			vkQueue,
			1,
			&vk.SubmitInfo {
				sType = .SUBMIT_INFO,
				commandBufferCount = len(tempCbArr),
				pCommandBuffers = raw_data(tempCbArr[:]),
			},
			fence,
		),
	)
	tempFenceArr := [?]vk.Fence{fence}
	chk(
		vk.WaitForFences(vkDevice, len(tempFenceArr), raw_data(tempFenceArr[:]), true, max(u64)),
	)

	vk.FreeCommandBuffers(vkDevice, vkCommandPool, len(tempCbArr), raw_data(tempCbArr[:]))
	vk.DestroyFence(vkDevice, fence, nil)

}
