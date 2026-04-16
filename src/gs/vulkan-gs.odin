package gs
import "../../modules/vma"
import "core:container/small_array"
import "core:fmt"
import vk "vendor:vulkan"


import "../../modules/tracy"
import "core:log"
import os "core:os"
import sdl "vendor:sdl3"


vkInstance: vk.Instance
vkPhysicalDevice: vk.PhysicalDevice

vkGraphicsQueueFamilyIndex: u32 = 0
vkQueue: vk.Queue

vkDevice: vk.Device

vkAllocator: vma.Allocator

vkSurface: vk.SurfaceKHR
vkSwapchain: vk.SwapchainKHR
vkSwapchainImageFormat: vk.Format = .B8G8R8A8_SRGB
vkSwapchainColorSpace: vk.ColorSpaceKHR = .SRGB_NONLINEAR

vkSwapchainImages: [dynamic]vk.Image = nil
vkSwpachainImageViews: [dynamic]vk.ImageView = nil

vkImageCount: u32
vkDepthFormat: vk.Format = .UNDEFINED

vkDepthImage: vk.Image
vmaDepthStencilAlloc: vma.Allocation
vkDepthImageView: vk.ImageView

vkFences := [MAX_FRAMES_IN_FLIGHT]vk.Fence{}
vkPresentSemaphores := [MAX_FRAMES_IN_FLIGHT]vk.Semaphore{}
vkRenderSemaphores: []vk.Semaphore = nil

vkCommandPool: vk.CommandPool
vkDrawCommandBuffers := [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer{}
vkUpdateSwapchain: bool
vkFrameIndex: u32 = 0
imageIndex: u32 = 0

MAX_FRAMES_IN_FLIGHT: u32 : 2
MAX_DEFERRED_RELEASES :: 128

VkBufferPoolElem :: struct {
	buffer: vk.Buffer,
	alloc:  vma.Allocation,
}

cameraBuffers := [MAX_FRAMES_IN_FLIGHT]VkBufferPoolElem{}

DeferredBufferRelease :: struct {
	buffer: vk.Buffer,
	alloc:  vma.Allocation,
}


deferredBufferReleases: [MAX_FRAMES_IN_FLIGHT]small_array.Small_Array(
	MAX_DEFERRED_RELEASES,
	DeferredBufferRelease,
)

CameraUBO :: struct {
	view: matrix[4, 4]f32,
	proj: matrix[4, 4]f32,
}
CameraUBOSize := vk.DeviceSize(size_of(CameraUBO))
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

		vk_chk(vk.CreateInstance(&instanceCI, nil, &vkInstance))
		vk.load_proc_addresses_instance(vkInstance)

	}
	ensure(vkInstance != nil)

	{
		tracy.Zone()

		deviceCount: u32 = 0
		vk_chk(vk.EnumeratePhysicalDevices(vkInstance, &deviceCount, nil))
		devices := make([]vk.PhysicalDevice, deviceCount, context.temp_allocator)
		if deviceCount == 0 {
			fmt.eprintln("cannot find any device supporting our given Vulkan requirements")
			os.exit(1)
		}

		vk_chk(vk.EnumeratePhysicalDevices(vkInstance, &deviceCount, raw_data(devices)))

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
		vkPhysicalDevice = bestDevice
		// vk.GetPhysicalDeviceProperties2(vkPhysicalDevice, &deviceProperties)
	}
	ensure(vkPhysicalDevice != {})
	// fmt.printfln("Selected device: %s", deviceProperties.properties.deviceName)

	{
		tracy.Zone()

		queueFamilyCount: u32 = 0
		vk.GetPhysicalDeviceQueueFamilyProperties(vkPhysicalDevice, &queueFamilyCount, nil)
		queueFamilies := make([]vk.QueueFamilyProperties, queueFamilyCount, context.temp_allocator)

		vk.GetPhysicalDeviceQueueFamilyProperties(
			vkPhysicalDevice,
			&queueFamilyCount,
			raw_data(queueFamilies),
		)
		for queueFamily, i in queueFamilies {
			if (.GRAPHICS in queueFamily.queueFlags) {
				vkGraphicsQueueFamilyIndex = u32(i)
				break
			}
		}

		ensure(
			sdl.Vulkan_GetPresentationSupport(
				vkInstance,
				vkPhysicalDevice,
				vkGraphicsQueueFamilyIndex,
			),
		)
		// Logical device
		qfpriorities: f32 = 1.0
		queueCI := vk.DeviceQueueCreateInfo {
			sType            = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = vkGraphicsQueueFamilyIndex,
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
		}
		enabledVk13Features := vk.PhysicalDeviceVulkan13Features {
			sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
			pNext            = &enabledVk12Features,
			synchronization2 = true,
			dynamicRendering = true,
		}
		deviceExtensions := [?]cstring {
			vk.KHR_SWAPCHAIN_EXTENSION_NAME,
			vk.KHR_PUSH_DESCRIPTOR_EXTENSION_NAME,
		}
		enabledVk10Features := vk.PhysicalDeviceFeatures {
			samplerAnisotropy = true,
			shaderInt64       = true,
			geometryShader    = true,
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
		vk_chk(vk.CreateDevice(vkPhysicalDevice, &deviceCI, nil, &vkDevice))
		vk.GetDeviceQueue(vkDevice, vkGraphicsQueueFamilyIndex, 0, &vkQueue)
	}
	ensure(vkQueue != {})
	ensure(vkDevice != {})

	{
		tracy.Zone()

		vmaVulkanFunctions := vma.create_vulkan_functions()

		vk_chk(
			vma.create_allocator(
				{
					flags = {.Buffer_Device_Address},
					physical_device = vkPhysicalDevice,
					device = vkDevice,
					instance = vkInstance,
					vulkan_functions = &vmaVulkanFunctions,
				},
				&vkAllocator,
			),
		)

	}
	ensure(vkAllocator != {})

	{
		tracy.Zone()

		ensure(sdl.Vulkan_CreateSurface(window, vkInstance, nil, &vkSurface))
		surfaceCaps: vk.SurfaceCapabilitiesKHR
		vk_chk(
			vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(vkPhysicalDevice, vkSurface, &surfaceCaps),
		)


		formatCount: u32 = 0
		vk_chk(
			vk.GetPhysicalDeviceSurfaceFormatsKHR(vkPhysicalDevice, vkSurface, &formatCount, nil),
		)
		surfaceFormats := make([]vk.SurfaceFormatKHR, formatCount, context.temp_allocator)
		vk_chk(
			vk.GetPhysicalDeviceSurfaceFormatsKHR(
				vkPhysicalDevice,
				vkSurface,
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

		vkSwapchainImageFormat = preferredFormat.format
		vkSwapchainColorSpace = preferredFormat.colorSpace
		ensure(vkSwapchainImageFormat != .UNDEFINED)

		vk_chk(
			vk.CreateSwapchainKHR(
				vkDevice,
				&{
					sType = .SWAPCHAIN_CREATE_INFO_KHR,
					surface = vkSurface,
					minImageCount = surfaceCaps.minImageCount,
					imageFormat = vkSwapchainImageFormat,
					imageColorSpace = preferredFormat.colorSpace,
					imageExtent = vk_resolve_extent(surfaceCaps),
					imageArrayLayers = 1,
					imageUsage = {.COLOR_ATTACHMENT},
					preTransform = {.IDENTITY},
					compositeAlpha = {.OPAQUE},
					presentMode = .FIFO,
				},
				nil,
				&vkSwapchain,
			),
		)
		vk.GetSwapchainImagesKHR(vkDevice, vkSwapchain, &vkImageCount, nil)
		vkSwapchainImages = make([dynamic]vk.Image, vkImageCount)
		vkSwpachainImageViews = make([dynamic]vk.ImageView, vkImageCount)
		vk.GetSwapchainImagesKHR(vkDevice, vkSwapchain, &vkImageCount, raw_data(vkSwapchainImages))

		for i in 0 ..< vkImageCount {
			vk_chk(
				vk.CreateImageView(
					vkDevice,
					&{
						sType = .IMAGE_VIEW_CREATE_INFO,
						image = vkSwapchainImages[i],
						viewType = .D2,
						format = vkSwapchainImageFormat,
						subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
					},
					nil,
					&vkSwpachainImageViews[i],
				),
			)
		}
	}
	ensure(vkSurface != {})
	ensure(vkSwapchain != {})
	ensure(vkImageCount > 0)
	for i in vkSwapchainImages do ensure(i != {})
	for i in vkSwpachainImageViews do ensure(i != {})


	{
		tracy.Zone()

		depthFormatList := [?]vk.Format{.D32_SFLOAT, .D24_UNORM_S8_UINT}

		for format in depthFormatList {
			formatProperties := [?]vk.FormatProperties2{{sType = .FORMAT_PROPERTIES_2}}
			vk.GetPhysicalDeviceFormatProperties2(
				vkPhysicalDevice,
				format,
				raw_data(formatProperties[:]),
			)

			if .DEPTH_STENCIL_ATTACHMENT in
			   formatProperties[0].formatProperties.optimalTilingFeatures {
				vkDepthFormat = format
				break
			}
		}

		ensure(vkDepthFormat != .UNDEFINED)

		vk_chk(
			vma.create_image(
				vkAllocator,
				{
					sType = .IMAGE_CREATE_INFO,
					imageType = .D2,
					format = vkDepthFormat,
					extent = {width = u32(screenWidth), height = u32(screenHeight), depth = 1},
					mipLevels = 1,
					arrayLayers = 1,
					samples = {._1},
					tiling = .OPTIMAL,
					usage = {.DEPTH_STENCIL_ATTACHMENT},
					initialLayout = .UNDEFINED,
				},
				{flags = {.Dedicated_Memory}, usage = .Auto},
				&vkDepthImage,
				&vmaDepthStencilAlloc,
				nil,
			),
		)

		vk_chk(
			vk.CreateImageView(
				vkDevice,
				&{
					sType = .IMAGE_VIEW_CREATE_INFO,
					image = vkDepthImage,
					viewType = .D2,
					format = vkDepthFormat,
					subresourceRange = {
						aspectMask = vk.ImageAspectFlags{.DEPTH} if vkDepthFormat == .D32_SFLOAT else vk.ImageAspectFlags{.DEPTH, .STENCIL},
						levelCount = 1,
						layerCount = 1,
					},
				},
				nil,
				&vkDepthImageView,
			),
		)

	}
	ensure(vkDepthImageView != {})
	ensure(vkDepthImage != {})


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
			vk_chk(
				vk.CreateFence(
					vkDevice,
					&{sType = .FENCE_CREATE_INFO, flags = {.SIGNALED}},
					nil,
					&vkFences[i],
				),
			)
			vk_chk(vk.CreateSemaphore(vkDevice, &semaphoreCI, nil, &vkPresentSemaphores[i]))

		}
		vkRenderSemaphores = make([]vk.Semaphore, len(vkSwapchainImages))
		for &s in vkRenderSemaphores {
			vk_chk(vk.CreateSemaphore(vkDevice, &semaphoreCI, nil, &s))
		}
	}
	assert(len(vkRenderSemaphores) != 0)
	for i in vkRenderSemaphores do ensure(i != {})
	for i in vkRenderSemaphores do ensure(i != {})
	for i in vkFences do ensure(i != {})

	{
		tracy.Zone()

		vk_chk(
			vk.CreateCommandPool(
				vkDevice,
				&{
					sType = .COMMAND_POOL_CREATE_INFO,
					flags = {.RESET_COMMAND_BUFFER},
					queueFamilyIndex = vkGraphicsQueueFamilyIndex,
				},
				nil,
				&vkCommandPool,
			),
		)

		vk_chk(
			vk.AllocateCommandBuffers(
				vkDevice,
				&{
					sType = .COMMAND_BUFFER_ALLOCATE_INFO,
					commandPool = vkCommandPool,
					commandBufferCount = MAX_FRAMES_IN_FLIGHT,
				},
				raw_data(vkDrawCommandBuffers[:]),
			),
		)
	}
	ensure(vkCommandPool != {})
	for i in vkDrawCommandBuffers do ensure(i != {})

	{
		tracy.Zone()

		for i in 0 ..< MAX_FRAMES_IN_FLIGHT {

			vk_chk(
				vma.create_buffer(
					vkAllocator,
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

vk_chk :: proc(r: vk.Result) {
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
			vma.destroy_buffer(vkAllocator, release.buffer, release.alloc)
		}
	}

	small_array.clear(&deferredBufferReleases[frameIdx])
}
vulkan_cleanup :: proc() {
	vk.DeviceWaitIdle(vkDevice)
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT do vk_run_deferred_buffer_releases(i)


	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		if vkFences[i] != {} do vk.DestroyFence(vkDevice, vkFences[i], nil)
		if vkPresentSemaphores[i] != {} do vk.DestroySemaphore(vkDevice, vkPresentSemaphores[i], nil)
		if cameraBuffers[i].alloc != {} do vma.destroy_buffer(vkAllocator, cameraBuffers[i].buffer, cameraBuffers[i].alloc)
	}

	for s in vkRenderSemaphores {
		if s != {} do vk.DestroySemaphore(vkDevice, s, nil)
	}
	delete(vkRenderSemaphores)
	if vkDepthImageView != {} do vk.DestroyImageView(vkDevice, vkDepthImageView, nil)

	if vkDepthImage != {} do vma.destroy_image(vkAllocator, vkDepthImage, vmaDepthStencilAlloc)


	for view in vkSwpachainImageViews {
		if view != {} do vk.DestroyImageView(vkDevice, view, nil)
	}
	delete(vkSwpachainImageViews)

	// for t in textures {
	// 	if t.view != {} do vk.DestroyImageView(vkDevice, t.view, nil)

	// 	if t.sampler != {} do vk.DestroySampler(vkDevice, t.sampler, nil)

	// 	if t.image != {} do vma.destroy_image(vkAllocator, t.image, t.allocation)

	// }


	if vkSwapchain != {} do vk.DestroySwapchainKHR(vkDevice, vkSwapchain, nil)
	delete(vkSwapchainImages)

	if vkCommandPool != {} do vk.DestroyCommandPool(vkDevice, vkCommandPool, nil)


	if vkAllocator != nil do vma.destroy_allocator(vkAllocator)


	if vkSurface != {} do vk.DestroySurfaceKHR(vkInstance, vkSurface, nil)

	if vkDevice != {} do vk.DestroyDevice(vkDevice, nil)

	if vkInstance != {} do vk.DestroyInstance(vkInstance, nil)


}

vulkan_update_swapchain :: proc() {
	if vkUpdateSwapchain == false do return
	defer vkUpdateSwapchain = false
	vk_chk(vk.DeviceWaitIdle(vkDevice))

	surfaceCaps: vk.SurfaceCapabilitiesKHR
	vk_chk(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(vkPhysicalDevice, vkSurface, &surfaceCaps))

	oldSwapchain := vkSwapchain

	swapchainCI := vk.SwapchainCreateInfoKHR {
		sType = .SWAPCHAIN_CREATE_INFO_KHR,
		surface = vkSurface,
		minImageCount = surfaceCaps.minImageCount,
		imageFormat = vkSwapchainImageFormat,
		imageColorSpace = vkSwapchainColorSpace,
		imageExtent = {width = screenWidth, height = screenHeight},
		imageArrayLayers = 1,
		imageUsage = {.COLOR_ATTACHMENT},
		preTransform = {.IDENTITY},
		compositeAlpha = {.OPAQUE},
		presentMode = .FIFO,
		oldSwapchain = oldSwapchain,
	}

	vk_chk(vk.CreateSwapchainKHR(vkDevice, &swapchainCI, nil, &vkSwapchain))

	for view in vkSwpachainImageViews {
		vk.DestroyImageView(vkDevice, view, nil)
	}

	vk_chk(vk.GetSwapchainImagesKHR(vkDevice, vkSwapchain, &vkImageCount, nil))
	clear_dynamic_array(&vkSwapchainImages)
	resize(&vkSwapchainImages, vkImageCount)

	clear_dynamic_array(&vkSwpachainImageViews)
	resize(&vkSwpachainImageViews, vkImageCount)
	vk_chk(
		vk.GetSwapchainImagesKHR(
			vkDevice,
			vkSwapchain,
			&vkImageCount,
			raw_data(vkSwapchainImages),
		),
	)

	for i in 0 ..< vkImageCount {
		viewCI := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = vkSwapchainImages[i],
			viewType = .D2,
			format = vkSwapchainImageFormat,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}

		vk_chk(vk.CreateImageView(vkDevice, &viewCI, nil, &vkSwpachainImageViews[i]))
	}

	vk.DestroySwapchainKHR(vkDevice, oldSwapchain, nil)

	vk.DestroyImageView(vkDevice, vkDepthImageView, nil)
	vma.destroy_image(vkAllocator, vkDepthImage, vmaDepthStencilAlloc)

	depthImageCI := vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2,
		format = vkDepthFormat,
		extent = {width = screenWidth, height = screenHeight, depth = 1},
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

	vk_chk(
		vma.create_image(
			vkAllocator,
			depthImageCI,
			allocCI,
			&vkDepthImage,
			&vmaDepthStencilAlloc,
			nil,
		),
	)

	depthViewCI := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = vkDepthImage,
		viewType = .D2,
		format = vkDepthFormat,
		subresourceRange = {aspectMask = {.DEPTH}, levelCount = 1, layerCount = 1},
	}

	vk_chk(vk.CreateImageView(vkDevice, &depthViewCI, nil, &vkDepthImageView))
}
vk_chk_swapchain :: proc(r: vk.Result) {
	if r != .SUCCESS {
		if r == .ERROR_OUT_OF_DATE_KHR {
			vkUpdateSwapchain = true
		} else {
			vk_chk(r)
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
	vk_chk(res)

	return shader_module
}
vk_resolve_extent :: proc(caps: vk.SurfaceCapabilitiesKHR) -> vk.Extent2D {
	// 0xFFFFFFFF means the surface lets us pick; use the actual window size
	if caps.currentExtent.width != max(u32) {
		return caps.currentExtent
	}
	return {
		width = clamp(screenWidth, caps.minImageExtent.width, caps.maxImageExtent.width),
		height = clamp(screenHeight, caps.minImageExtent.height, caps.maxImageExtent.height),
	}
}
