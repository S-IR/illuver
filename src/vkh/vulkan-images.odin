package vkh
import "../../modules/vma"
import "core:container/small_array"
import "core:mem"
import vk "vendor:vulkan"


VK_UI_DUMMY_TEXTURE_ID: u32 : 0

ImageLoaderInputs :: struct {
	data:                    [^]u8,
	width, height, channels: i32,
	magFilter:               vk.Filter,
	minFilter:               vk.Filter,
}
vkUiNextTextureID := VK_UI_DUMMY_TEXTURE_ID + 1

load_gltf_image :: proc(
	pi: ImageLoaderInputs,
	cb: vk.CommandBuffer,
	giveID := true,
) -> (
	texture: GPUTexture,
) {
	primitive_image_assert(pi)
	//i assume 4 channels to set the format properly
	assert(pi.channels == 4)
	imageFormat: vk.Format = .R8G8B8A8_SRGB

	chk(
		vma.create_image(
			vkAllocator,
			{
				sType = .IMAGE_CREATE_INFO,
				imageType = .D2,
				format = imageFormat,
				extent = {width = u32(pi.width), height = u32(pi.height), depth = 1},
				mipLevels = 1,
				arrayLayers = 1,
				samples = {._1},
				tiling = .OPTIMAL,
				usage = {.TRANSFER_DST, .SAMPLED},
				initialLayout = .UNDEFINED,
			},
			{usage = .Auto},
			&texture.image,
			&texture.allocation,
			nil,
		),
	)

	poolIndex := small_array.len(deferredBufferReleases[vkFrameIndex])
	small_array.append(&deferredBufferReleases[vkFrameIndex], VkBufferPoolElem{})

	poolElem := small_array.get_ptr(&deferredBufferReleases[vkFrameIndex], poolIndex)
	imgSrcBuffer := &poolElem.buffer
	imgSrcAllocation := &poolElem.alloc

	chk(
		vma.create_buffer(
			vkAllocator,
			{
				sType = .BUFFER_CREATE_INFO,
				size = vk.DeviceSize(pi.width * pi.height * pi.channels),
				usage = {.TRANSFER_SRC},
			},
			{flags = {.Host_Access_Sequential_Write, .Mapped}, usage = .Auto},
			imgSrcBuffer,
			imgSrcAllocation,
			nil,
		),
	)
	imgSrcBufferPtr: rawptr
	chk(vma.map_memory(vkAllocator, imgSrcAllocation^, &imgSrcBufferPtr))
	mem.copy(imgSrcBufferPtr, pi.data, int(pi.width) * int(pi.height) * int(pi.channels))


	barrier := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = {},
		srcAccessMask = {},
		dstStageMask = {.TRANSFER},
		dstAccessMask = {.TRANSFER_WRITE},
		oldLayout = .UNDEFINED,
		newLayout = .TRANSFER_DST_OPTIMAL,
		image = texture.image,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	vma.unmap_memory(vkAllocator, imgSrcAllocation^)
	vk.CmdPipelineBarrier2(
		cb,
		&vk.DependencyInfo {
			sType = .DEPENDENCY_INFO,
			imageMemoryBarrierCount = 1,
			pImageMemoryBarriers = &barrier,
		},
	)

	copyRegion := vk.BufferImageCopy {
		bufferOffset = 0,
		imageSubresource = {aspectMask = {.COLOR}, mipLevel = 0, layerCount = 1},
		imageExtent = {width = u32(pi.width), height = u32(pi.height), depth = 1},
	}
	vk.CmdCopyBufferToImage(
		cb,
		imgSrcBuffer^,
		texture.image,
		.TRANSFER_DST_OPTIMAL,
		1,
		&copyRegion,
	)

	barrier = vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = {.TRANSFER},
		srcAccessMask = {.TRANSFER_WRITE},
		dstStageMask = {.FRAGMENT_SHADER},
		dstAccessMask = {.SHADER_READ},
		oldLayout = .TRANSFER_DST_OPTIMAL,
		newLayout = .READ_ONLY_OPTIMAL,
		image = texture.image,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	vk.CmdPipelineBarrier2(
		cb,
		&vk.DependencyInfo {
			sType = .DEPENDENCY_INFO,
			imageMemoryBarrierCount = 1,
			pImageMemoryBarriers = &barrier,
		},
	)


	chk(
		vk.CreateImageView(
			vkDevice,
			&vk.ImageViewCreateInfo {
				sType = .IMAGE_VIEW_CREATE_INFO,
				image = texture.image,
				viewType = .D2,
				format = imageFormat,
				subresourceRange = {
					aspectMask = {.COLOR},
					baseMipLevel = 0,
					levelCount = 1,
					baseArrayLayer = 0,
					layerCount = 1,
				},
			},
			nil,
			&texture.descriptor.imageView,
		),
	)

	chk(
		vk.CreateSampler(
			vkDevice,
			&vk.SamplerCreateInfo {
				sType = .SAMPLER_CREATE_INFO,
				magFilter = .LINEAR,
				minFilter = .LINEAR,
				mipmapMode = .LINEAR,
				anisotropyEnable = true,
				maxAnisotropy = 8.0,
				maxLod = 1.0,
			},
			nil,
			&texture.descriptor.sampler,
		),
	)
	texture.descriptor.imageLayout = .READ_ONLY_OPTIMAL

	if giveID {
		texture.descriptor.imageLayout = .READ_ONLY_OPTIMAL
		texture.id = vkUiNextTextureID
		if vkUiNextTextureID == max(u32) - 1 {
			vkUiNextTextureID = (VK_UI_DUMMY_TEXTURE_ID + 1)
		} else {
			vkUiNextTextureID += 1
		}

	}
	return texture
}
