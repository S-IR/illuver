package main
import "../modules/tracy"
import "../modules/vma"
import "base:runtime"
import "camera"
import "core:c"
import "core:fmt"
import "core:math/linalg"
import "core:math/rand"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:prof/spall"
import "core:sync"
import "core:time"
import "gs"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"
sdl_ensure :: proc(cond: bool, message: string = "") {
	msg := fmt.tprintf("%s:%s\n", message, sdl.GetError())
	ensure(cond, msg)
}

float2 :: [2]f32
float3 :: [3]f32
float4 :: [4]f32

ENABLE_SPALL :: false && ODIN_DEBUG
VISUAL_REPRESENTATION_OF_NOISE_FN_RUN :: false && ODIN_DEBUG
VISUAL_REPRESENTATION_OF_NOISE_FN_RUN_2D :: true && VISUAL_REPRESENTATION_OF_NOISE_FN_RUN

when ODIN_DEBUG && ENABLE_SPALL {
	spall_ctx: spall.Context
	@(thread_local)
	spall_buffer: spall.Buffer


	// @(instrumentation_enter)
	// spall_enter :: proc "contextless" (
	// 	proc_address, call_site_return_address: rawptr,
	// 	loc: runtime.Source_Code_Location,
	// ) {
	// 	spall._buffer_begin(&spall_ctx, &spall_buffer, "", "", loc)
	// }

	// @(instrumentation_exit)
	// spall_exit :: proc "contextless" (
	// 	proc_address, call_site_return_address: rawptr,
	// 	loc: runtime.Source_Code_Location,
	// ) {
	// 	spall._buffer_end(&spall_ctx, &spall_buffer)
	// }

}
TRACY_ENABLE :: true


main :: proc() {

	when TRACY_ENABLE {
		tracy.SetThreadName("main")
	}
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {
			if len(track.allocation_map) > 0 {
				fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
				for _, entry in track.allocation_map {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			}
			if len(track.bad_free_array) > 0 {
				fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
				for entry in track.bad_free_array {
					fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}

		when ENABLE_SPALL {
			spall_ctx = spall.context_create("spall-trace.spall")
			defer spall.context_destroy(&spall_ctx)

			buffer_backing := make([]u8, spall.BUFFER_DEFAULT_SIZE)
			defer delete(buffer_backing)

			spall_buffer = spall.buffer_create(buffer_backing, u32(sync.current_thread_id()))
			defer spall.buffer_destroy(&spall_ctx, &spall_buffer)
		}

	}
	gs.NUM_CORES = os.get_processor_core_count()
	{
		tracy.Zone()
		sdl_ensure(sdl.Init({.VIDEO, .EVENTS}))
		gs.window = sdl.CreateWindow(
			"Illuver",
			i32(gs.screenWidth),
			i32(gs.screenHeight),
			{.RESIZABLE, .VULKAN},
		)
		sdl_ensure(gs.window != nil)
		sdl.SetLogPriorities(.WARN)

	}
	when ODIN_DEBUG {
		defer sdl.DestroyWindow(gs.window)

	}

	// device = sdl.CreateGPUDevice({.SPIRV}, true, nil)
	gs.vulkan_init()
	when ODIN_DEBUG {
		defer gs.vulkan_cleanup()
	}
	// sdl_ensure(device != nil)
	// defer sdl.DestroyGPUDevice(device)

	// sdl_ensure(sdl.ClaimWindowForGPUDevice(device, window) != false)

	currCamera := camera.Camera_new(pos = {0, 0, -2}, front = {0, 0, 1})

	chunks_init(&currCamera)
	energyTickNow := time.tick_now()
	gs.LastLifeTick = energyTickNow
	gs.LastWisdomTick = energyTickNow
	gs.LastLightTick = energyTickNow
	defer chunks_destroy()


	pointPipeline := point_pipeline_init()
	defer pipeline_data_delete(pointPipeline)

	highlightSphere := highlight_sphere_init()
	defer highlight_sphere_destroy(&highlightSphere)

	e: sdl.Event
	quit := false

	lastFrameTime := time.now()
	FPS :: 144
	frameTime := time.Duration(time.Second / FPS)

	currRotationAngle: f32 = 0
	ROTATION_SPEED :: 90

	prevScreenWidth := gs.screenWidth
	prevScreenHeight := gs.screenHeight
	rand.reset(gs.seed)
	middleOfChunksInNormalCoords := f32((CHUNKS_PER_DIRECTION / 2)) * CHUNK_SIZE + CHUNK_SIZE / 2
	middleOfMiddleChunkPos := float3{middleOfChunksInNormalCoords, 0, middleOfChunksInNormalCoords}
	// camera = Camera_new(pos = middleOfMiddleChunkPos)

	free_all(context.temp_allocator)
	when ODIN_DEBUG {
		defer vk.DeviceWaitIdle(gs.vkDevice)
	}

	didLeftClickThisFrame := false
	mouseX, mouseY: f32

	for !quit {
		tracy.FrameMark()
		tracy.Plot("Test", f64(time.now()._nsec))
		defer free_all(context.temp_allocator)
		defer {
			frameEnd := time.now()
			frameDuration := time.diff(frameEnd, lastFrameTime)

			gs.dt = time.duration_seconds(time.since(lastFrameTime))
			lastFrameTime = time.now()
			gs.totalTime += f64(gs.dt)

		}
		defer {
			prevScreenWidth, prevScreenHeight = gs.screenWidth, gs.screenHeight
		}

		didLeftClickThisFrame = false
		for sdl.PollEvent(&e) {

			SCALE_STEP :: f32(0.001)
			PERSIST_STEP :: f32(0.01)
			LACUNARITY_STEP :: f64(0.1)
			OCTAVE_STEP :: 1
			#partial switch e.type {
			case .QUIT:
				quit = true
				break
			case .KEY_DOWN:
				switch e.key.key {
				case sdl.K_ESCAPE:
					quit = true
				}


			case .WINDOW_RESIZED:
				gs.screenWidth, gs.screenHeight = u32(e.window.data1), u32(e.window.data2)
				if gs.screenWidth != prevScreenWidth || gs.screenHeight != prevScreenHeight {
					gs.vkUpdateSwapchain = true
				}
			case .MOUSE_MOTION:
				camera.Camera_process_mouse_movement(&currCamera, e.motion.xrel, e.motion.yrel)
				mouseX = f32(e.motion.x)
				mouseY = f32(e.motion.y)
			case .MOUSE_BUTTON_DOWN:
				if e.button.button == sdl.BUTTON_LEFT {
					didLeftClickThisFrame = true
				}
			case:
				continue
			}
		}
		if prevScreenWidth != gs.screenWidth || prevScreenHeight != gs.screenHeight {
			sdl.SetWindowSize(gs.window, i32(gs.screenWidth), i32(gs.screenHeight))
			gs.vkUpdateSwapchain = true
			sdl.SyncWindow(gs.window)

		}
		gs.vulkan_update_swapchain()

		ticksToDo: bit_set[EnergyType] = {}
		if time.tick_since(gs.LastLifeTick) >= gs.LifeInterval {
			ticksToDo += {.Life}
			// energy_tick({.Life})
		}

		if time.tick_since(gs.LastWisdomTick) >= gs.WisdomInterval {
			ticksToDo += {.Wisdom}
			// energy_tick({.Wisdom})
		}

		if time.tick_since(gs.LastLightTick) >= gs.LightInterval {
			ticksToDo += {.Light}

			// energy_tick({.Light})
		}
		if ticksToDo != {} {
			energy_tick(ticksToDo)
			if .Light in ticksToDo {
				gs.LastLightTick = time.tick_now()
			}
			if .Wisdom in ticksToDo {
				gs.LastWisdomTick = time.tick_now()
			}
			if .Life in ticksToDo {
				gs.LastLifeTick = time.tick_now()
			}
		}

		camera.camera_process_keyboard_movement(&currCamera)

		chunks_frame_update(&currCamera)
		// chunks_shift_per_player_movement(&camera)
		// fmt.println("camera pos", camera.pos)
		view, proj := camera.Camera_view_proj(&currCamera)
		cameraPtr: rawptr
		vma.map_memory(gs.vkAllocator, gs.cameraBuffers[gs.vkFrameIndex].alloc, &cameraPtr)
		currCameraUBO := gs.CameraUBO {
			view = view,
			proj = proj,
		}

		mem.copy(cameraPtr, &currCameraUBO, size_of(currCameraUBO))
		vma.unmap_memory(gs.vkAllocator, gs.cameraBuffers[gs.vkFrameIndex].alloc)


		//TODO. I FORGOT CAMERA HAS F32 AS POSITION AND NOT I32. THAT MIGHT MEAN THAT TRAVELLING FAR TO I32 IS GOING TO CAUSE PROBLEMS
		// biomeWeights := get_biome_weights(i32(camera.pos.x), i32(camera.pos.z), seed)
		// for weight, biome in biomeWeights {
		// 	str, _ := fmt.enum_value_to_string(biome)
		// 	fmt.printf("%s : %d ,", str, int(weight))
		// }
		// fmt.println()
		rayDir := compute_mouse_ray(mouseX, mouseY, gs.screenWidth, gs.screenHeight, view, proj)

		raycastPointHit, raycastPointPos, raycastDidHappen := raycast_get_viewed_point(
			currCamera.pos,
			currCamera.front,
		)
		if raycastDidHappen && didLeftClickThisFrame {
			chunk_set_point(raycastPointPos, u16(PointType.Air))
		}
		// if raycastDidHappen do fmt.println("raycast point:", raycastPointHit)

		// gs.vulkan_update_swapchain()
		gs.vk_chk(vk.WaitForFences(gs.vkDevice, 1, &gs.vkFences[gs.vkFrameIndex], true, max(u64)))
		gs.vk_run_deferred_buffer_releases(gs.vkFrameIndex)

		gs.vk_chk(vk.ResetFences(gs.vkDevice, 1, &gs.vkFences[gs.vkFrameIndex]))
		gs.vk_chk_swapchain(
			vk.AcquireNextImageKHR(
				gs.vkDevice,
				gs.vkSwapchain,
				max(u64),
				gs.vkPresentSemaphores[gs.vkFrameIndex],
				vk.Fence{},
				&gs.imageIndex,
			),
		)


		cb := gs.vkDrawCommandBuffers[gs.vkFrameIndex]
		gs.vk_chk(vk.ResetCommandBuffer(cb, {}))

		gs.vk_chk(
			vk.BeginCommandBuffer(
				cb,
				&{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}},
			),
		)
		barriers := [?]vk.ImageMemoryBarrier2 {
			{
				sType = .IMAGE_MEMORY_BARRIER_2,
				srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
				srcAccessMask = {},
				dstStageMask = {.COLOR_ATTACHMENT_OUTPUT},
				dstAccessMask = {.COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE},
				oldLayout = .UNDEFINED,
				newLayout = .ATTACHMENT_OPTIMAL,
				image = gs.vkSwapchainImages[gs.imageIndex],
				subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
			},
			{
				sType = .IMAGE_MEMORY_BARRIER_2,
				srcStageMask = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
				srcAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
				dstStageMask = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
				dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
				oldLayout = .UNDEFINED,
				newLayout = .ATTACHMENT_OPTIMAL,
				image = gs.vkDepthImage,
				subresourceRange = {aspectMask = {.DEPTH}, levelCount = 1, layerCount = 1},
			},
		}
		vk.CmdPipelineBarrier2(
			cb,
			&{
				sType = .DEPENDENCY_INFO,
				imageMemoryBarrierCount = len(barriers),
				pImageMemoryBarriers = raw_data(barriers[:]),
			},
		)
		vk.CmdBeginRendering(
			cb,
			&{
				sType = .RENDERING_INFO,
				renderArea = {extent = {width = gs.screenWidth, height = gs.screenHeight}},
				layerCount = 1,
				colorAttachmentCount = 1,
				pColorAttachments = &vk.RenderingAttachmentInfo {
					sType = .RENDERING_ATTACHMENT_INFO,
					imageView = gs.vkSwpachainImageViews[gs.imageIndex],
					imageLayout = .ATTACHMENT_OPTIMAL,
					loadOp = .CLEAR,
					storeOp = .STORE,
					clearValue = {color = {float32 = {0.2, 0.4, 0.6, 1}}},
				},
				pDepthAttachment = &vk.RenderingAttachmentInfo {
					sType = .RENDERING_ATTACHMENT_INFO,
					imageView = gs.vkDepthImageView,
					imageLayout = .ATTACHMENT_OPTIMAL,
					loadOp = .CLEAR,
					storeOp = .DONT_CARE,
					clearValue = {depthStencil = {1, 0}},
				},
			},
		)

		MIN_RANGE_TO_SEE_POINT :: 6.0
		if raycastDidHappen &&
		   !didLeftClickThisFrame &&
		   linalg.length(currCamera.pos - raycastPointPos) < MIN_RANGE_TO_SEE_POINT {
			highlight_sphere_draw(
				cb,
				&highlightSphere,
				gs.cameraBuffers[gs.vkFrameIndex].buffer,
				vk.DeviceSize(size_of(gs.CameraUBO)),
				raycastPointPos,
				f32(gs.totalTime),
			)

		}

		chunks_draw(
			cb,
			&pointPipeline,
			gs.cameraBuffers[gs.vkFrameIndex].buffer,
			vk.DeviceSize(size_of(gs.CameraUBO)),
			&currCamera,
		)


		vk.CmdEndRendering(cb)

		vk.CmdPipelineBarrier2(
			cb,
			&{
				sType = .DEPENDENCY_INFO,
				imageMemoryBarrierCount = 1,
				pImageMemoryBarriers = &vk.ImageMemoryBarrier2 {
					sType = .IMAGE_MEMORY_BARRIER_2,
					srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
					srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
					dstStageMask = {.COLOR_ATTACHMENT_OUTPUT},
					dstAccessMask = {},
					oldLayout = .COLOR_ATTACHMENT_OPTIMAL,
					newLayout = .PRESENT_SRC_KHR,
					image = gs.vkSwapchainImages[gs.imageIndex],
					subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
				},
			},
		)
		vk.EndCommandBuffer(cb)
		waitStage: vk.PipelineStageFlags = {.COLOR_ATTACHMENT_OUTPUT}
		gs.vk_chk(
			vk.QueueSubmit(
				gs.vkQueue,
				1,
				&vk.SubmitInfo {
					sType = .SUBMIT_INFO,
					waitSemaphoreCount = 1,
					pWaitSemaphores = &gs.vkPresentSemaphores[gs.vkFrameIndex],
					pWaitDstStageMask = &waitStage,
					commandBufferCount = 1,
					pCommandBuffers = &cb,
					signalSemaphoreCount = 1,
					pSignalSemaphores = &gs.vkRenderSemaphores[gs.imageIndex],
				},
				gs.vkFences[gs.vkFrameIndex],
			),
		)
		gs.vkFrameIndex = (gs.vkFrameIndex + 1) % gs.MAX_FRAMES_IN_FLIGHT
		gs.vk_chk_swapchain(
			vk.QueuePresentKHR(
				gs.vkQueue,
				&{
					sType = .PRESENT_INFO_KHR,
					waitSemaphoreCount = 1,
					pWaitSemaphores = &gs.vkRenderSemaphores[gs.imageIndex],
					swapchainCount = 1,
					pSwapchains = &gs.vkSwapchain,
					pImageIndices = &gs.imageIndex,
				},
			),
		)


	}
}
