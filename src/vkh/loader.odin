package vkh
import vk "vendor:vulkan"

loader_command_buffer_create :: proc() -> (cb: vk.CommandBuffer, fence: vk.Fence) {
	chk(
		vk.AllocateCommandBuffers(
			device,
			&vk.CommandBufferAllocateInfo {
				sType = .COMMAND_BUFFER_ALLOCATE_INFO,
				commandPool = drawCommandPool,
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

	chk(vk.CreateFence(device, &{sType = .FENCE_CREATE_INFO}, nil, &fence))
	return cb, fence
}
loader_command_buffer_wait_and_destroy :: proc(cb: vk.CommandBuffer, fence: vk.Fence) {
	tempCbArr := [?]vk.CommandBuffer{cb}


	tempFenceArr := [?]vk.Fence{fence}
	chk(vk.WaitForFences(device, len(tempFenceArr), raw_data(tempFenceArr[:]), true, max(u64)))

	vk.FreeCommandBuffers(device, drawCommandPool, len(tempCbArr), raw_data(tempCbArr[:]))
	vk.DestroyFence(device, fence, nil)

}
