package vkh
import "../../modules/vma"
import "core:container/small_array"
import "core:fmt"
import vk "vendor:vulkan"

import "../../modules/tracy"
import "../gs"
import "core:log"
import os "core:os"
import "core:sync"
import sdl "vendor:sdl3"
GPUTexture :: struct {
	image:      vk.Image,
	descriptor: vk.DescriptorImageInfo,
	allocation: vma.Allocation,
	id:         u32,
}

instance: vk.Instance
physicalDevice: vk.PhysicalDevice

graphicsQueueFamilyIndex: u32 = max(u32)
computeQueueFamilyIndex: u32 = max(u32)
graphicsQueue: vk.Queue
computeQueue: vk.Queue

device: vk.Device

allocator: vma.Allocator

surface: vk.SurfaceKHR
swapchain: vk.SwapchainKHR
swapchainImageFormat: vk.Format = .B8G8R8A8_SRGB
swapchainColorSpace: vk.ColorSpaceKHR = .SRGB_NONLINEAR

swapchainImages: [dynamic]vk.Image = nil
swpachainImageViews: [dynamic]vk.ImageView = nil

imageCount: u32
depthFormat: vk.Format = .UNDEFINED

depthImage: vk.Image
vmaDepthStencilAlloc: vma.Allocation
depthImageView: vk.ImageView

fences := [MAX_FRAMES_IN_FLIGHT]vk.Fence{}
framesReady: [MAX_FRAMES_IN_FLIGHT]sync.Sema

presentSemaphores := [MAX_FRAMES_IN_FLIGHT]vk.Semaphore{}
renderSemaphores: []vk.Semaphore = nil

timelineSemaphore: vk.Semaphore
timelineValue: u64 = 0
frameTimelineValues: [MAX_FRAMES_IN_FLIGHT]u64

copyTimelineSemaphore: vk.Semaphore
copyTimelineValue: u64


drawCommandPool: vk.CommandPool
drawCommandBuffers := [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer{}

computeCommandPool: vk.CommandPool
// computeCommandBuffers: [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer
computeQueueMutex: sync.Mutex

updateSwapchain: bool
frameIndex: u32 = 0
imageIndex: u32 = 0

MAX_FRAMES_IN_FLIGHT: u32 : 2
MAX_DEFERRED_RELEASES :: 128

VkBufferPoolElem :: struct {
	buffer: vk.Buffer,
	alloc:  vma.Allocation,
}

cameraBuffers := [MAX_FRAMES_IN_FLIGHT]VkBufferPoolElem{}


deferredBufferReleases: [MAX_FRAMES_IN_FLIGHT]small_array.Small_Array(
	MAX_DEFERRED_RELEASES,
	VkBufferPoolElem,
)

CameraUBO :: struct {
	view: matrix[4, 4]f32,
	proj: matrix[4, 4]f32,
}
CameraUBOSize := vk.DeviceSize(size_of(CameraUBO))
PipelineData :: struct {
	descriptorSetLayout: vk.DescriptorSetLayout,
	layout:              vk.PipelineLayout,
	pipeline:            vk.Pipeline,
}
pipeline_data_delete :: proc(p: PipelineData) {
	if p.descriptorSetLayout != {} do vk.DestroyDescriptorSetLayout(device, p.descriptorSetLayout, nil)
	if p.layout != {} do vk.DestroyPipelineLayout(device, p.layout, nil)
	if p.pipeline != {} do vk.DestroyPipeline(device, p.pipeline, nil)

}

vulkan_init :: proc() {
	tracy.Zone()
	sdl.Vulkan_LoadLibrary(nil)


	vkGetProc := sdl.Vulkan_GetVkGetInstanceProcAddr()
	assert(vkGetProc != nil)
	vk.load_proc_addresses_global(rawptr(vkGetProc))

	{
		tracy.Zone()
		appInfo := vk.ApplicationInfo {
			sType            = .APPLICATION_INFO,
			pApplicationName = "Illuver",
			apiVersion       = vk.API_VERSION_1_3,
		}
		instanceExtensionCount: u32
		extensions := sdl.Vulkan_GetInstanceExtensions(&instanceExtensionCount)

		instanceCI := vk.InstanceCreateInfo {
			sType                   = .INSTANCE_CREATE_INFO,
			pApplicationInfo        = &appInfo,
			enabledExtensionCount   = instanceExtensionCount,
			ppEnabledExtensionNames = extensions,
		}
		when ODIN_DEBUG {
			layers := [?]cstring{"VK_LAYER_KHRONOS_validation"}
			instanceCI.enabledLayerCount = u32(len(layers))
			instanceCI.ppEnabledLayerNames = raw_data(layers[:])

		}

		chk(vk.CreateInstance(&instanceCI, nil, &instance))
		vk.load_proc_addresses_instance(instance)

	}
	ensure(instance != nil)

	{
		tracy.Zone()

		deviceCount: u32 = 0
		chk(vk.EnumeratePhysicalDevices(instance, &deviceCount, nil))
		devices := make([]vk.PhysicalDevice, deviceCount, context.temp_allocator)
		if deviceCount == 0 {
			fmt.eprintln("cannot find any device supporting our given Vulkan requirements")
			os.exit(1)
		}

		chk(vk.EnumeratePhysicalDevices(instance, &deviceCount, raw_data(devices)))

		deviceProperties := vk.PhysicalDeviceProperties2 {
			sType = .PHYSICAL_DEVICE_PROPERTIES_2,
		}
		bestScore: i32 = -1
		bestDevice: vk.PhysicalDevice

		for d in devices {
			score: i32 = 0

			props: vk.PhysicalDeviceProperties
			vk.GetPhysicalDeviceProperties(d, &props)
			if props.deviceType == .DISCRETE_GPU {
				score += 1000_000_000
			}

			memProps: vk.PhysicalDeviceMemoryProperties
			vk.GetPhysicalDeviceMemoryProperties(d, &memProps)

			totalVRAM: vk.DeviceSize = 0
			for heap in memProps.memoryHeaps[:memProps.memoryHeapCount] {
				if .DEVICE_LOCAL in heap.flags {
					totalVRAM += heap.size
				}
			}
			score += i32(totalVRAM / (1024 * 1024))

			if score > bestScore {

				bestScore = score
				bestDevice = d
			}
		}

		if bestScore == -1 {
			fmt.eprintln("cannot find any device supporting our given Vulkan requirements")
			os.exit(1)
		}
		physicalDevice = bestDevice
		// vk.GetPhysicalDeviceProperties2(vkPhysicalDevice, &deviceProperties)
	}
	ensure(physicalDevice != {})
	// fmt.printfln("Selected device: %s", deviceProperties.properties.deviceName)

	{
		tracy.Zone()

		queueFamilyCount: u32 = 0
		vk.GetPhysicalDeviceQueueFamilyProperties(physicalDevice, &queueFamilyCount, nil)
		queueFamilies := make([]vk.QueueFamilyProperties, queueFamilyCount, context.temp_allocator)

		vk.GetPhysicalDeviceQueueFamilyProperties(
			physicalDevice,
			&queueFamilyCount,
			raw_data(queueFamilies),
		)
		for queueFamily, i in queueFamilies {
			if (.GRAPHICS in queueFamily.queueFlags) {
				graphicsQueueFamilyIndex = u32(i)
			}
			if (.COMPUTE in queueFamily.queueFlags) {
				computeQueueFamilyIndex = u32(i)
			}
			if graphicsQueueFamilyIndex != max(u32) && computeQueueFamilyIndex != max(u32) do break
		}

		ensure(
			sdl.Vulkan_GetPresentationSupport(instance, physicalDevice, graphicsQueueFamilyIndex),
		)
		// Logical device
		qfpriorities: f32 = 1.0
		queueCI := vk.DeviceQueueCreateInfo {
			sType            = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = graphicsQueueFamilyIndex,
			queueCount       = 1,
			pQueuePriorities = &qfpriorities,
		}

		enabledVk12Features := vk.PhysicalDeviceVulkan12Features {
			sType                                     = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
			descriptorIndexing                        = true,
			shaderSampledImageArrayNonUniformIndexing = true,
			descriptorBindingVariableDescriptorCount  = true,
			runtimeDescriptorArray                    = true,
			bufferDeviceAddress                       = true,
			timelineSemaphore                         = true,
			scalarBlockLayout                         = true,
		}

		storage16Features := vk.PhysicalDevice16BitStorageFeatures {
			sType                              = .PHYSICAL_DEVICE_16BIT_STORAGE_FEATURES,
			storageBuffer16BitAccess           = true,
			uniformAndStorageBuffer16BitAccess = true,
		}
		storage16Features.pNext = &enabledVk12Features

		enabledVk13Features := vk.PhysicalDeviceVulkan13Features {
			sType                          = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
			pNext                          = &storage16Features,
			shaderDemoteToHelperInvocation = true,
			synchronization2               = true,
			dynamicRendering               = true,
		}

		enabledVk10Features := vk.PhysicalDeviceFeatures {
			samplerAnisotropy = true,
			shaderInt64       = true,
			geometryShader    = true,
			shaderInt16       = true,
		}
		deviceExtensions := [?]cstring {
			vk.KHR_SWAPCHAIN_EXTENSION_NAME,
			vk.KHR_PUSH_DESCRIPTOR_EXTENSION_NAME,
		}

		deviceCI := vk.DeviceCreateInfo {
			sType                   = .DEVICE_CREATE_INFO,
			pNext                   = &enabledVk13Features,
			queueCreateInfoCount    = 1,
			pQueueCreateInfos       = &queueCI,
			enabledExtensionCount   = u32(len(deviceExtensions)),
			ppEnabledExtensionNames = raw_data(deviceExtensions[:]),
			pEnabledFeatures        = &enabledVk10Features,
		}
		chk(vk.CreateDevice(physicalDevice, &deviceCI, nil, &device))
		assert(graphicsQueueFamilyIndex != max(u32))
		assert(computeQueueFamilyIndex != max(u32))

		vk.GetDeviceQueue(device, graphicsQueueFamilyIndex, 0, &graphicsQueue)
		vk.GetDeviceQueue(device, computeQueueFamilyIndex, 0, &computeQueue)

	}
	ensure(graphicsQueue != {})
	ensure(device != {})

	{
		tracy.Zone()

		vmaVulkanFunctions := vma.create_vulkan_functions()

		chk(
			vma.create_allocator(
				{
					flags = {.Buffer_Device_Address},
					physical_device = physicalDevice,
					device = device,
					instance = instance,
					vulkan_functions = &vmaVulkanFunctions,
				},
				&allocator,
			),
		)

	}
	ensure(allocator != {})

	{
		tracy.Zone()

		ensure(sdl.Vulkan_CreateSurface(gs.window, instance, nil, &surface))
		surfaceCaps: vk.SurfaceCapabilitiesKHR
		chk(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(physicalDevice, surface, &surfaceCaps))


		formatCount: u32 = 0
		chk(vk.GetPhysicalDeviceSurfaceFormatsKHR(physicalDevice, surface, &formatCount, nil))
		surfaceFormats := make([]vk.SurfaceFormatKHR, formatCount, context.temp_allocator)
		chk(
			vk.GetPhysicalDeviceSurfaceFormatsKHR(
				physicalDevice,
				surface,
				&formatCount,
				raw_data(surfaceFormats),
			),
		)

		preferredFormat := surfaceFormats[0]
		for f in surfaceFormats {
			if (f.format == .A2B10G10R10_UNORM_PACK32 || f.format == .A2B10G10R10_SINT_PACK32) &&
			   f.colorSpace == .HDR10_ST2084_EXT {
				preferredFormat = f
				break
			}
			if f.format == .B10G11R11_UFLOAT_PACK32 || f.format == .R16G16B16A16_SFLOAT {
				preferredFormat = f
				break
			}
			if f.format == .B8G8R8A8_SRGB && f.colorSpace == .SRGB_NONLINEAR {
				preferredFormat = f
			}
		}

		swapchainImageFormat = preferredFormat.format
		swapchainColorSpace = preferredFormat.colorSpace
		ensure(swapchainImageFormat != .UNDEFINED)

		chk(
			vk.CreateSwapchainKHR(
				device,
				&{
					sType = .SWAPCHAIN_CREATE_INFO_KHR,
					surface = surface,
					minImageCount = surfaceCaps.minImageCount,
					imageFormat = swapchainImageFormat,
					imageColorSpace = preferredFormat.colorSpace,
					imageExtent = vk_resolve_extent(surfaceCaps),
					imageArrayLayers = 1,
					imageUsage = {.COLOR_ATTACHMENT},
					preTransform = {.IDENTITY},
					compositeAlpha = {.OPAQUE},
					presentMode = .FIFO,
				},
				nil,
				&swapchain,
			),
		)
		vk.GetSwapchainImagesKHR(device, swapchain, &imageCount, nil)
		swapchainImages = make([dynamic]vk.Image, imageCount)
		swpachainImageViews = make([dynamic]vk.ImageView, imageCount)
		vk.GetSwapchainImagesKHR(device, swapchain, &imageCount, raw_data(swapchainImages))

		for i in 0 ..< imageCount {
			chk(
				vk.CreateImageView(
					device,
					&{
						sType = .IMAGE_VIEW_CREATE_INFO,
						image = swapchainImages[i],
						viewType = .D2,
						format = swapchainImageFormat,
						subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
					},
					nil,
					&swpachainImageViews[i],
				),
			)
		}
	}
	ensure(surface != {})
	ensure(swapchain != {})
	ensure(imageCount > 0)
	for i in swapchainImages do ensure(i != {})
	for i in swpachainImageViews do ensure(i != {})


	{
		tracy.Zone()

		depthFormatList := [?]vk.Format{.D32_SFLOAT, .D24_UNORM_S8_UINT}

		for format in depthFormatList {
			formatProperties := [?]vk.FormatProperties2{{sType = .FORMAT_PROPERTIES_2}}
			vk.GetPhysicalDeviceFormatProperties2(
				physicalDevice,
				format,
				raw_data(formatProperties[:]),
			)

			if .DEPTH_STENCIL_ATTACHMENT in
			   formatProperties[0].formatProperties.optimalTilingFeatures {
				depthFormat = format
				break
			}
		}

		ensure(depthFormat != .UNDEFINED)

		chk(
			vma.create_image(
				allocator,
				{
					sType = .IMAGE_CREATE_INFO,
					imageType = .D2,
					format = depthFormat,
					extent = {
						width = u32(gs.screenWidth),
						height = u32(gs.screenHeight),
						depth = 1,
					},
					mipLevels = 1,
					arrayLayers = 1,
					samples = {._1},
					tiling = .OPTIMAL,
					usage = {.DEPTH_STENCIL_ATTACHMENT},
					initialLayout = .UNDEFINED,
				},
				{flags = {.Dedicated_Memory}, usage = .Auto},
				&depthImage,
				&vmaDepthStencilAlloc,
				nil,
			),
		)

		chk(
			vk.CreateImageView(
				device,
				&{
					sType = .IMAGE_VIEW_CREATE_INFO,
					image = depthImage,
					viewType = .D2,
					format = depthFormat,
					subresourceRange = {
						aspectMask = vk.ImageAspectFlags{.DEPTH} if depthFormat == .D32_SFLOAT else vk.ImageAspectFlags{.DEPTH, .STENCIL},
						levelCount = 1,
						layerCount = 1,
					},
				},
				nil,
				&depthImageView,
			),
		)

	}
	ensure(depthImageView != {})
	ensure(depthImage != {})


	// for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
	// 	vk_chk(
	// 		vma.create_buffer(
	// 			vkAllocator,
	// 			{
	// 				sType = .BUFFER_CREATE_INFO,
	// 				size = size_of(ShaderData),
	// 				usage = {.UNIFORM_BUFFER, .SHADER_DEVICE_ADDRESS},
	// 			},
	// 			{
	// 				flags = {
	// 					.Host_Access_Sequential_Write,
	// 					.Host_Access_Allow_Transfer_Instead,
	// 					.Mapped,
	// 				},
	// 				usage = .Auto,
	// 			},
	// 			&shaderDataBuffers[i].buffer,
	// 			&shaderDataBuffers[i].allocation,
	// 			nil,
	// 		),
	// 	)
	// 	vk_chk(
	// 		vma.map_memory(
	// 			vkAllocator,
	// 			shaderDataBuffers[i].allocation,
	// 			&shaderDataBuffers[i].mapped,
	// 		),
	// 	)
	// 	addr_info := vk.BufferDeviceAddressInfo {
	// 		sType  = .BUFFER_DEVICE_ADDRESS_INFO,
	// 		buffer = shaderDataBuffers[i].buffer,
	// 	}
	// 	shaderDataBuffers[i].deviceAddress = vk.GetBufferDeviceAddress(vkDevice, &addr_info)


	// }
	{
		tracy.Zone()

		semaphoreCI := vk.SemaphoreCreateInfo {
			sType = .SEMAPHORE_CREATE_INFO,
		}
		for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
			chk(
				vk.CreateFence(
					device,
					&{sType = .FENCE_CREATE_INFO, flags = {.SIGNALED}},
					nil,
					&fences[i],
				),
			)
			chk(vk.CreateSemaphore(device, &semaphoreCI, nil, &presentSemaphores[i]))

		}
		renderSemaphores = make([]vk.Semaphore, len(swapchainImages))
		for &s in renderSemaphores {
			chk(vk.CreateSemaphore(device, &semaphoreCI, nil, &s))
		}
		chk(
			vk.CreateSemaphore(
				device,
				&{
					sType = .SEMAPHORE_CREATE_INFO,
					pNext = &vk.SemaphoreTypeCreateInfo {
						sType = .SEMAPHORE_TYPE_CREATE_INFO,
						semaphoreType = .TIMELINE,
						initialValue = timelineValue,
					},
				},
				nil,
				&timelineSemaphore,
			),
		)
		chk(
			vk.CreateSemaphore(
				device,
				&{
					sType = .SEMAPHORE_CREATE_INFO,
					pNext = &vk.SemaphoreTypeCreateInfo {
						sType = .SEMAPHORE_TYPE_CREATE_INFO,
						semaphoreType = .TIMELINE,
						initialValue = 0,
					},
				},
				nil,
				&copyTimelineSemaphore,
			),
		)
		for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
			frameTimelineValues[i] = 0
		}

	}
	assert(len(renderSemaphores) != 0)
	for i in renderSemaphores do ensure(i != {})
	for i in renderSemaphores do ensure(i != {})
	for i in fences do ensure(i != {})
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT do sync.sema_post(&framesReady[i])
	assert(timelineSemaphore != {})
	for v in frameTimelineValues do assert(v == 0)

	assert(copyTimelineSemaphore != {})


	{

		chk(
			vk.CreateCommandPool(
				device,
				&{
					sType = .COMMAND_POOL_CREATE_INFO,
					flags = {.RESET_COMMAND_BUFFER},
					queueFamilyIndex = graphicsQueueFamilyIndex,
				},
				nil,
				&drawCommandPool,
			),
		)

		chk(
			vk.AllocateCommandBuffers(
				device,
				&{
					sType = .COMMAND_BUFFER_ALLOCATE_INFO,
					commandPool = drawCommandPool,
					commandBufferCount = MAX_FRAMES_IN_FLIGHT,
				},
				raw_data(drawCommandBuffers[:]),
			),
		)


		if computeQueueFamilyIndex != graphicsQueueFamilyIndex {
			chk(
				vk.CreateCommandPool(
					device,
					&vk.CommandPoolCreateInfo {
						sType = .COMMAND_POOL_CREATE_INFO,
						flags = {.RESET_COMMAND_BUFFER},
						queueFamilyIndex = computeQueueFamilyIndex,
					},
					nil,
					&computeCommandPool,
				),
			)


		} else {
			computeCommandPool = drawCommandPool

		}

	}

	for cb in drawCommandBuffers do ensure(cb != {})

	{
		tracy.Zone()

		for i in 0 ..< MAX_FRAMES_IN_FLIGHT {

			chk(
				vma.create_buffer(
					allocator,
					{
						sType = .BUFFER_CREATE_INFO,
						size = size_of(CameraUBO),
						usage = {.UNIFORM_BUFFER},
					},
					{flags = {.Host_Access_Sequential_Write, .Mapped}, usage = .Auto},
					&cameraBuffers[i].buffer,
					&cameraBuffers[i].alloc,
					nil,
				),
			)
		}
	}

	for i in cameraBuffers do ensure(i.alloc != {})


}

chk :: proc(r: vk.Result) {
	if r != .SUCCESS {
		when ODIN_DEBUG {
			log.fatalf("[VULKAN RETURN ERROR]: %s", fmt.enum_value_to_string(r))
		} else {
			fmt.eprintf("[VULKAN RETURN ERROR]: %s", fmt.enum_value_to_string(r))
		}
	}
}


vk_run_deferred_buffer_releases :: proc(frameIdx: u32) {
	assert(frameIdx < MAX_FRAMES_IN_FLIGHT)

	releases := small_array.slice(&deferredBufferReleases[frameIdx])

	for release in releases {
		if release.alloc != {} {
			vma.destroy_buffer(allocator, release.buffer, release.alloc)
		}
	}

	small_array.clear(&deferredBufferReleases[frameIdx])
}
vulkan_cleanup :: proc() {
	vk.DeviceWaitIdle(device)
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT do vk_run_deferred_buffer_releases(i)


	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		if fences[i] != {} do vk.DestroyFence(device, fences[i], nil)
		if presentSemaphores[i] != {} do vk.DestroySemaphore(device, presentSemaphores[i], nil)
		if cameraBuffers[i].alloc != {} do vma.destroy_buffer(allocator, cameraBuffers[i].buffer, cameraBuffers[i].alloc)
	}
	if timelineSemaphore != {} do vk.DestroySemaphore(device, timelineSemaphore, nil)
	if copyTimelineSemaphore != {} do vk.DestroySemaphore(device, copyTimelineSemaphore, nil)

	for s in renderSemaphores {
		if s != {} do vk.DestroySemaphore(device, s, nil)
	}
	delete(renderSemaphores)
	if depthImageView != {} do vk.DestroyImageView(device, depthImageView, nil)

	if depthImage != {} do vma.destroy_image(allocator, depthImage, vmaDepthStencilAlloc)


	for view in swpachainImageViews {
		if view != {} do vk.DestroyImageView(device, view, nil)
	}
	delete(swpachainImageViews)

	// for t in textures {
	// 	if t.view != {} do vk.DestroyImageView(vkDevice, t.view, nil)

	// 	if t.sampler != {} do vk.DestroySampler(vkDevice, t.sampler, nil)

	// 	if t.image != {} do vma.destroy_image(vkAllocator, t.image, t.allocation)

	// }


	if swapchain != {} do vk.DestroySwapchainKHR(device, swapchain, nil)
	delete(swapchainImages)

	if drawCommandPool != {} do vk.DestroyCommandPool(device, drawCommandPool, nil)


	if allocator != nil do vma.destroy_allocator(allocator)


	if surface != {} do vk.DestroySurfaceKHR(instance, surface, nil)

	if device != {} do vk.DestroyDevice(device, nil)

	if instance != {} do vk.DestroyInstance(instance, nil)


}

vulkan_update_swapchain :: proc() {
	if updateSwapchain == false do return
	defer updateSwapchain = false
	chk(vk.DeviceWaitIdle(device))

	surfaceCaps: vk.SurfaceCapabilitiesKHR
	chk(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(physicalDevice, surface, &surfaceCaps))

	oldSwapchain := swapchain

	swapchainCI := vk.SwapchainCreateInfoKHR {
		sType = .SWAPCHAIN_CREATE_INFO_KHR,
		surface = surface,
		minImageCount = surfaceCaps.minImageCount,
		imageFormat = swapchainImageFormat,
		imageColorSpace = swapchainColorSpace,
		imageExtent = {width = gs.screenWidth, height = gs.screenHeight},
		imageArrayLayers = 1,
		imageUsage = {.COLOR_ATTACHMENT},
		preTransform = {.IDENTITY},
		compositeAlpha = {.OPAQUE},
		presentMode = .FIFO,
		oldSwapchain = oldSwapchain,
	}

	chk(vk.CreateSwapchainKHR(device, &swapchainCI, nil, &swapchain))

	for view in swpachainImageViews {
		vk.DestroyImageView(device, view, nil)
	}

	chk(vk.GetSwapchainImagesKHR(device, swapchain, &imageCount, nil))
	clear_dynamic_array(&swapchainImages)
	resize(&swapchainImages, imageCount)

	clear_dynamic_array(&swpachainImageViews)
	resize(&swpachainImageViews, imageCount)
	chk(vk.GetSwapchainImagesKHR(device, swapchain, &imageCount, raw_data(swapchainImages)))

	for i in 0 ..< imageCount {
		viewCI := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = swapchainImages[i],
			viewType = .D2,
			format = swapchainImageFormat,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}

		chk(vk.CreateImageView(device, &viewCI, nil, &swpachainImageViews[i]))
	}

	vk.DestroySwapchainKHR(device, oldSwapchain, nil)

	vk.DestroyImageView(device, depthImageView, nil)
	vma.destroy_image(allocator, depthImage, vmaDepthStencilAlloc)

	depthImageCI := vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2,
		format = depthFormat,
		extent = {width = gs.screenWidth, height = gs.screenHeight, depth = 1},
		mipLevels = 1,
		arrayLayers = 1,
		samples = {._1},
		tiling = .OPTIMAL,
		usage = {.DEPTH_STENCIL_ATTACHMENT},
	}

	allocCI := vma.Allocation_Create_Info {
		flags = {.Dedicated_Memory},
		usage = .Auto,
	}

	chk(
		vma.create_image(
			allocator,
			depthImageCI,
			allocCI,
			&depthImage,
			&vmaDepthStencilAlloc,
			nil,
		),
	)

	depthViewCI := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = depthImage,
		viewType = .D2,
		format = depthFormat,
		subresourceRange = {aspectMask = {.DEPTH}, levelCount = 1, layerCount = 1},
	}

	chk(vk.CreateImageView(device, &depthViewCI, nil, &depthImageView))
}
vk_chk_swapchain :: proc(r: vk.Result) {
	if r != .SUCCESS {
		if r == .ERROR_OUT_OF_DATE_KHR {
			updateSwapchain = true
		} else {
			chk(r)
		}
	}
}
create_shader_module :: proc(device: vk.Device, code: []byte) -> vk.ShaderModule {
	assert(len(code) % 4 == 0, "SPIR-V bytecode size must be multiple of 4 bytes")

	code_u32 := cast(^u32)raw_data(code)

	ci := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(code),
		pCode    = code_u32,
	}

	shader_module: vk.ShaderModule
	res := vk.CreateShaderModule(device, &ci, nil, &shader_module)
	chk(res)

	return shader_module
}
vk_resolve_extent :: proc(caps: vk.SurfaceCapabilitiesKHR) -> vk.Extent2D {
	if caps.currentExtent.width != max(u32) {
		return caps.currentExtent
	}
	return {
		width = clamp(gs.screenWidth, caps.minImageExtent.width, caps.maxImageExtent.width),
		height = clamp(gs.screenHeight, caps.minImageExtent.height, caps.maxImageExtent.height),
	}
}
