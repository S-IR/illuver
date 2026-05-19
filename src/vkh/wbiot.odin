package vkh

import "../../modules/vma"
import "core:container/small_array"
import "core:fmt"
import vk "vendor:vulkan"

import "../../modules/tracy"
import "../gs"
import os "core:os"
import "core:sync"
import sdl "vendor:sdl3"


wbAccum: ImageAlloc
wbAccumView: vk.ImageView

wbReveal: ImageAlloc
wbRevealView: vk.ImageView

wbSampler: vk.Sampler

wbiot_textures_init :: proc() {
	chk(
		vma.create_image(
			allocator,
			{
				sType = .IMAGE_CREATE_INFO,
				imageType = .D2,
				format = .R16G16B16A16_SFLOAT,
				extent = {width = u32(gs.screenWidth), height = u32(gs.screenHeight), depth = 1},
				mipLevels = 1,
				arrayLayers = 1,
				samples = {._1},
				tiling = .OPTIMAL,
				usage = {.COLOR_ATTACHMENT, .SAMPLED},
				initialLayout = .UNDEFINED,
			},
			{flags = {.Dedicated_Memory}, usage = .Auto},
			&wbAccum.image,
			&wbAccum.alloc,
			nil,
		),
	)

	chk(
		vk.CreateImageView(
			device,
			&{
				sType = .IMAGE_VIEW_CREATE_INFO,
				image = wbAccum.image,
				viewType = .D2,
				format = .R16G16B16A16_SFLOAT,
				subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
			},
			nil,
			&wbAccumView,
		),
	)

	chk(
		vma.create_image(
			allocator,
			{
				sType = .IMAGE_CREATE_INFO,
				imageType = .D2,
				format = .R16_SFLOAT,
				extent = {width = u32(gs.screenWidth), height = u32(gs.screenHeight), depth = 1},
				mipLevels = 1,
				arrayLayers = 1,
				samples = {._1},
				tiling = .OPTIMAL,
				usage = {.COLOR_ATTACHMENT, .SAMPLED},
				initialLayout = .UNDEFINED,
			},
			{flags = {.Dedicated_Memory}, usage = .Auto},
			&wbReveal.image,
			&wbReveal.alloc,
			nil,
		),
	)

	chk(
		vk.CreateImageView(
			device,
			&vk.ImageViewCreateInfo {
				sType = .IMAGE_VIEW_CREATE_INFO,
				image = wbReveal.image,
				viewType = .D2,
				format = .R16_SFLOAT,
				subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
			},
			nil,
			&wbRevealView,
		),
	)

	chk(
		vk.CreateSampler(
			device,
			&vk.SamplerCreateInfo {
				sType = .SAMPLER_CREATE_INFO,
				magFilter = .NEAREST,
				minFilter = .NEAREST,
				addressModeU = .CLAMP_TO_EDGE,
				addressModeV = .CLAMP_TO_EDGE,
				addressModeW = .CLAMP_TO_EDGE,
			},
			nil,
			&wbSampler,
		),
	)
}
wbiot_destroy :: proc() {
	if wbSampler != {} do vk.DestroySampler(device, wbSampler, nil)
	if wbRevealView != {} do vk.DestroyImageView(device, wbRevealView, nil)
	if wbAccumView != {} do vk.DestroyImageView(device, wbAccumView, nil)
	if wbReveal.image != {} do vma.destroy_image(allocator, wbReveal.image, wbReveal.alloc)
	if wbAccum.image != {} do vma.destroy_image(allocator, wbAccum.image, wbAccum.alloc)
}
