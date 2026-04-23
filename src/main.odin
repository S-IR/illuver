package main
import "../modules/tracy"
import "../modules/vma"
import "base:runtime"
import "camera"
import "core:c"
import "core:container/small_array"
import "core:fmt"
import "core:math/linalg"
import "core:math/rand"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:prof/spall"
import "core:sync"
import "core:thread"
import "core:time"
import "gs"
import "ui"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"
import "vkh"
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

DEBUG_MODE_IGNORE_SAVE :: false && ODIN_DEBUG
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
	when ODIN_DEBUG do defer sdl.DestroyWindow(gs.window)

	// device = sdl.CreateGPUDevice({.SPIRV}, true, nil)
	vkh.vulkan_init()
	when ODIN_DEBUG do defer vkh.vulkan_cleanup()
	loadCb, fence := vkh.loader_command_buffer_create()

	font: ui.BMFont
	inventory: Inventory
	uiPipeline: vkh.PipelineData
	{


		uiPipeline = ui.init(loadCb)
		dejaVuPath :=
			"assets" +
			filepath.SEPARATOR_STRING +
			"fonts" +
			filepath.SEPARATOR_STRING +
			"DejaVuSans-Bold" +
			filepath.SEPARATOR_STRING +
			"DejaVuSans-Bold.json"
		// ensure(adwaitaFontPathJoinError == nil)
		font = ui.bmfont_json_load(dejaVuPath, loadCb)

		inventory = inventory_init(loadCb, font)

		vkh.chk(vk.EndCommandBuffer(loadCb))
		tempCbArr := [?]vk.CommandBuffer{loadCb}

		vkh.chk(
			vk.QueueSubmit(
				vkh.graphicsQueue,
				1,
				&vk.SubmitInfo {
					sType = .SUBMIT_INFO,
					commandBufferCount = len(tempCbArr),
					pCommandBuffers = raw_data(tempCbArr[:]),
				},
				fence,
			),
		)
	}
	when ODIN_DEBUG do defer ui.bmfont_destroy(font)
	when ODIN_DEBUG do defer ui.destroy(uiPipeline)
	when ODIN_DEBUG do defer inventory_destroy(&inventory)
	// assert(inventory != {})
	// assert(uiPipeline != {})
	userInfoFileHandle: ^os.File

	when ODIN_DEBUG do defer if (userInfoFileHandle != nil) do os.close(userInfoFileHandle)

	// sdl_ensure(device != nil)
	// defer sdl.DestroyGPUDevice(device)

	// sdl_ensure(sdl.ClaimWindowForGPUDevice(device, window) != false)


	when ODIN_DEBUG do defer chunks_destroy()


	pointTrianglePipeline, pointDotPipeline := point_pipeline_init()
	when ODIN_DEBUG {
		defer {
			if pointTrianglePipeline.descriptorSetLayout != {} do vk.DestroyDescriptorSetLayout(vkh.device, pointTrianglePipeline.descriptorSetLayout, nil)
			if pointTrianglePipeline.layout != {} do vk.DestroyPipelineLayout(vkh.device, pointTrianglePipeline.layout, nil)
			if pointTrianglePipeline.pipeline != {} do vk.DestroyPipeline(vkh.device, pointTrianglePipeline.pipeline, nil)
			if pointDotPipeline.pipeline != {} do vk.DestroyPipeline(vkh.device, pointDotPipeline.pipeline, nil)

		}

	}


	chunkGeometryCalcPipeline = chunk_geometry_calc_pipeline_init()
	when ODIN_DEBUG do defer vkh.pipeline_data_delete(chunkGeometryCalcPipeline)

	highlightSphere := highlight_sphere_init()
	when ODIN_DEBUG do defer highlight_sphere_destroy(&highlightSphere)


	e: sdl.Event

	lastFrameTime := time.now()
	TARGET_FPS :: 144
	frameTime := time.Duration(time.Second / TARGET_FPS)

	currRotationAngle: f32 = 0
	ROTATION_SPEED :: 90

	prevScreenWidth := gs.screenWidth
	prevScreenHeight := gs.screenHeight
	rand.reset(gs.seed)
	middleOfChunksInNormalCoords := f32((CHUNKS_PER_DIRECTION / 2)) * CHUNK_SIZE + CHUNK_SIZE / 2
	middleOfMiddleChunkPos := float3{middleOfChunksInNormalCoords, 0, middleOfChunksInNormalCoords}
	// camera = Camera_new(pos = middleOfMiddleChunkPos)

	free_all(context.temp_allocator)
	when ODIN_DEBUG do defer vk.DeviceWaitIdle(vkh.device)


	mouseX, mouseY: f32

	vkh.loader_command_buffer_wait_and_destroy(loadCb, fence)
	gs.CurrGameScreen = .Loading

	prevLeftClick: bool
	chunkInitThread := thread.create(chunks_init_worker_thread)
	when ODIN_DEBUG {
		defer {
			thread.join(chunkInitThread)
			thread.destroy(chunkInitThread)
		}

	}

	ChunksInitWorkerThreadData :: struct {
		inventoryPtr:       ^Inventory,
		userInfoFileHandle: ^os.File,
		currCamera:         ^camera.Camera,
	}
	chunks_init_worker_thread :: proc(t: ^thread.Thread) {
		chunks_destroy()


		chunks_init(&camera.curr)
		energyTickNow := time.tick_now()
		gs.LastLifeTick = energyTickNow
		gs.LastWisdomTick = energyTickNow
		gs.LastLightTick = energyTickNow

		gs.CurrGameScreen = .Game

	}
	for !gs.quit {
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
		pressedRightClickThisFrame := false
		for sdl.PollEvent(&e) {

			SCALE_STEP :: f32(0.001)
			PERSIST_STEP :: f32(0.01)
			LACUNARITY_STEP :: f64(0.1)
			OCTAVE_STEP :: 1
			#partial switch e.type {
			case .QUIT:
				gs.quit = true
				break
			case .KEY_DOWN:
				switch e.key.key {
				case sdl.K_ESCAPE:
					gs.quit = true
				case sdl.K_1:
					spellbar_select(&inventory, 0)
				case sdl.K_2:
					spellbar_select(&inventory, 1)
				case sdl.K_3:
					spellbar_select(&inventory, 2)
				case sdl.K_4:
					spellbar_select(&inventory, 3)
				case sdl.K_5:
					spellbar_select(&inventory, 4)
				case sdl.K_6:
					spellbar_select(&inventory, 5)
				case sdl.K_7:
					spellbar_select(&inventory, 6)
				case sdl.K_8:
					spellbar_select(&inventory, 7)
				case sdl.K_9:
					spellbar_select(&inventory, 8)

				}


			case .WINDOW_RESIZED:
				gs.screenWidth, gs.screenHeight = u32(e.window.data1), u32(e.window.data2)
				if gs.screenWidth != prevScreenWidth || gs.screenHeight != prevScreenHeight {
					vkh.updateSwapchain = true
				}
			case .MOUSE_MOTION:
				camera.Camera_process_mouse_movement(&camera.curr, e.motion.xrel, e.motion.yrel)
				mouseX = f32(e.motion.x)
				mouseY = f32(e.motion.y)
			case .MOUSE_BUTTON_DOWN:
				if e.button.button == sdl.BUTTON_RIGHT {
					pressedRightClickThisFrame = true
				}
			case:
				continue
			}
		}
		if prevScreenWidth != gs.screenWidth || prevScreenHeight != gs.screenHeight {
			sdl.SetWindowSize(gs.window, i32(gs.screenWidth), i32(gs.screenHeight))
			vkh.updateSwapchain = true
			sdl.SyncWindow(gs.window)
		}
		leftClickIsHeldThisFrame := .LEFT in sdl.GetMouseState(nil, nil)
		vkh.vulkan_update_swapchain()


		currLeft := .LEFT in sdl.GetMouseState(nil, nil)
		defer prevLeftClick = currLeft
		leftClickPressed := currLeft && !prevLeftClick

		mouseState := MouseState {
			x            = mouseX,
			y            = mouseY,
			didLeftClick = leftClickPressed,
		}

		switch gs.CurrGameScreen {
		case .MainMenu:
			main_menu_render(font, mouseState, {uiPipeline = &uiPipeline})
		case .SpRealms:
			sp_realm_menu_render(font, mouseState, {uiPipeline = &uiPipeline})
		case .Loading:
			if .Started not_in chunkInitThread.flags {
				// if (chunkInitThread.data != nil) do free(chunkInitThread.data)

				existingInfo: User_Info_Per_Save
				foundExisting: bool
				userInfoFileHandle, existingInfo, foundExisting = user_info_realm_init()
				assert(userInfoFileHandle != nil)

				if !foundExisting {
					camera.curr = camera.Camera_new(pos = {0, 0, -2}, front = {0, 0, 1})
				} else {
					camera.curr = existingInfo.currCamera
					inventory.data = existingInfo.inventoryData
				}


				thread.start(chunkInitThread)


			}
			loading_screen_render(font, {uiPipeline = &uiPipeline})
		case .Game:
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
			camera.Camera_assert(&camera.curr)
			game_render(
				&camera.curr,
				userInfoFileHandle,
				&inventory,
				mouseX,
				mouseY,
				leftClickIsHeldThisFrame,
				pressedRightClickThisFrame,
				{
					highlightSpere = &highlightSphere,
					pointTrianglePipeline = &pointTrianglePipeline,
					pointDotPipeline = &pointDotPipeline,
					uiPipeline = &uiPipeline,
				},
			)

		}

	}
}
game_render :: proc(
	currCamera: ^camera.Camera,
	userInfoFileHandle: ^os.File,
	inventory: ^Inventory,
	mouseX, mouseY: f32,
	leftClickIsHeldThisFrame, pressedRightClickThisFrame: bool,
	renderData: struct {
		highlightSpere:        ^HighlightSphere,
		pointTrianglePipeline: ^vkh.PipelineData,
		pointDotPipeline:      ^vkh.PipelineData,
		uiPipeline:            ^vkh.PipelineData,
	},
) {
	assert(currCamera != nil)
	assert(userInfoFileHandle != nil)
	assert(inventory != nil)
	assert(renderData.highlightSpere != nil)
	assert(renderData.pointTrianglePipeline != nil)
	assert(renderData.pointDotPipeline != nil)
	assert(renderData.uiPipeline != nil)

	defer user_info_frame_end_store(
		userInfoFileHandle,
		&{inventoryData = inventory.data, currCamera = currCamera^},
	)
	camera.camera_process_keyboard_movement(currCamera)

	chunks_frame_update(currCamera)
	// chunks_shift_per_player_movement(&camera)
	// fmt.println("camera pos", camera.pos)
	view, proj := camera.Camera_view_proj(currCamera)
	cameraPtr: rawptr
	vma.map_memory(vkh.allocator, vkh.cameraBuffers[vkh.frameIndex].alloc, &cameraPtr)
	currCameraUBO := vkh.CameraUBO {
		view = view,
		proj = proj,
	}

	mem.copy(cameraPtr, &currCameraUBO, size_of(currCameraUBO))
	vma.unmap_memory(vkh.allocator, vkh.cameraBuffers[vkh.frameIndex].alloc)


	rayDir := compute_mouse_ray(mouseX, mouseY, gs.screenWidth, gs.screenHeight, view, proj)

	inventorySelectedPoint := inventory_get_selected_point(inventory)
	hasItemToPlace := inventorySelectedPoint != .Air

	// raycastPointHit: u16 = 0
	// raycastPointPos: [3]f32
	// raycastDidHappen: bool
	raycastPointHit, raycastPointPos, raycastDidHappen := raycast_get_viewed_point(
		currCamera.pos,
		currCamera.front,
		currCamera^,
		hasItemToPlace,
	)
	// fmt.print("camera pos ", currCamera.pos)
	// fmt.print(" raycastPointPos", raycastPointPos)
	// fmt.print(" 0 4 -2 point", get_point_at_world_pos({0, 4, -2}, currCamera))

	// fmt.println(" raycastPointHit", raycastPointHit)

	raycastIf: if raycastDidHappen && leftClickIsHeldThisFrame {
		changed, prev := chunk_set_point(raycastPointPos, PointType.Air)
		if u16_to_point_type(prev) != .Air {
			inventory_add_item(inventory, u16_to_point_type(prev))
		}

		// if !changed do break raycastIf
	}

	if raycastDidHappen &&
	   pressedRightClickThisFrame &&
	   u16_to_point_type(raycastPointHit) == .Air {
		if inventorySelectedPoint != .Air {
			inventory_reduce_amount_from_selected(inventory)
			chunk_set_point(raycastPointPos, inventorySelectedPoint)
		}

	}

	// if raycastDidHappen do fmt.println("raycast point:", raycastPointHit)
	cb := vkh.drawCommandBuffers[vkh.frameIndex]
	vk_begin_frame(cb)
	if raycastDidHappen && !leftClickIsHeldThisFrame {
		highlight_sphere_draw(
			cb,
			renderData.highlightSpere,
			vkh.cameraBuffers[vkh.frameIndex].buffer,
			vk.DeviceSize(size_of(vkh.CameraUBO)),
			raycastPointPos,
			f32(gs.totalTime),
		)

	}

	chunks_draw(cb, renderData.pointTrianglePipeline, renderData.pointDotPipeline, currCamera)


	spellbar_render(inventory)
	// ui.add_text("TAKING SOULS", font, 32, 20, 20, [4]f32{1, 1, 1, 1})


	ui.render(cb, renderData.uiPipeline^)
	vk_end_frame(&cb)
}


vk_begin_frame :: proc(cb: vk.CommandBuffer) {
	vkh.chk(vk.WaitForFences(vkh.device, 1, &vkh.fences[vkh.frameIndex], true, max(u64)))
	vkh.vk_run_deferred_buffer_releases(vkh.frameIndex)
	vkh.chk(vk.ResetFences(vkh.device, 1, &vkh.fences[vkh.frameIndex]))
	sync.sema_post(&vkh.framesReady[vkh.frameIndex])

	vkh.vk_chk_swapchain(
		vk.AcquireNextImageKHR(
			vkh.device,
			vkh.swapchain,
			max(u64),
			vkh.presentSemaphores[vkh.frameIndex],
			vk.Fence{},
			&vkh.imageIndex,
		),
	)

	vkh.chk(vk.ResetCommandBuffer(cb, {}))
	vkh.chk(
		vk.BeginCommandBuffer(
			cb,
			&{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}},
		),
	)

	imageMemoryBarriers := [?]vk.ImageMemoryBarrier2 {
		{
			sType = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
			dstStageMask = {.COLOR_ATTACHMENT_OUTPUT},
			dstAccessMask = {.COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE},
			oldLayout = .UNDEFINED,
			newLayout = .ATTACHMENT_OPTIMAL,
			image = vkh.swapchainImages[vkh.imageIndex],
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		},
		{
			sType = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
			dstStageMask = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
			dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
			oldLayout = .UNDEFINED,
			newLayout = .ATTACHMENT_OPTIMAL,
			image = vkh.depthImage,
			subresourceRange = {aspectMask = {.DEPTH}, levelCount = 1, layerCount = 1},
		},
	}
	vk.CmdPipelineBarrier2(
		cb,
		&{
			sType = .DEPENDENCY_INFO,
			imageMemoryBarrierCount = 2,
			pImageMemoryBarriers = raw_data(imageMemoryBarriers[:]),
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
				imageView = vkh.swpachainImageViews[vkh.imageIndex],
				imageLayout = .ATTACHMENT_OPTIMAL,
				loadOp = .CLEAR,
				storeOp = .STORE,
				clearValue = {color = {float32 = {0.2, 0.4, 0.6, 1}}},
			},
			pDepthAttachment = &vk.RenderingAttachmentInfo {
				sType = .RENDERING_ATTACHMENT_INFO,
				imageView = vkh.depthImageView,
				imageLayout = .ATTACHMENT_OPTIMAL,
				loadOp = .CLEAR,
				storeOp = .DONT_CARE,
				clearValue = {depthStencil = {1, 0}},
			},
		},
	)
}

vk_end_frame :: proc(cb: ^vk.CommandBuffer) {
	vk.CmdEndRendering(cb^)

	// Transition swapchain image to present layout
	vk.CmdPipelineBarrier2(
		cb^,
		&vk.DependencyInfo {
			sType = .DEPENDENCY_INFO,
			imageMemoryBarrierCount = 1,
			pImageMemoryBarriers = &vk.ImageMemoryBarrier2 {
				sType = .IMAGE_MEMORY_BARRIER_2,
				srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
				dstStageMask = {.COLOR_ATTACHMENT_OUTPUT},
				srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
				oldLayout = .COLOR_ATTACHMENT_OPTIMAL,
				newLayout = .PRESENT_SRC_KHR,
				image = vkh.swapchainImages[vkh.imageIndex],
				subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
			},
		},
	)

	vk.EndCommandBuffer(cb^)

	vkh.timelineValue += 1
	vkh.frameTimelineValues[vkh.frameIndex] = vkh.timelineValue


	// Prepare wait semaphore (presentSemaphore from acquire)
	waitInfo := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = vkh.presentSemaphores[vkh.frameIndex],
		value     = 0, // binary semaphore, value ignored
		stageMask = {.COLOR_ATTACHMENT_OUTPUT},
	}

	// Prepare signal semaphores: renderSemaphore (for present) and timelineSemaphore (for workers)
	renderSignalInfo := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = vkh.renderSemaphores[vkh.imageIndex],
		value     = 0,
		stageMask = {.ALL_COMMANDS},
	}
	timelineSignalInfo := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = vkh.timelineSemaphore,
		value     = vkh.timelineValue,
		stageMask = {.ALL_COMMANDS},
	}

	signalInfos := [?]vk.SemaphoreSubmitInfo{renderSignalInfo, timelineSignalInfo}

	submitInfo := vk.SubmitInfo2 {
		sType                    = .SUBMIT_INFO_2,
		waitSemaphoreInfoCount   = 1,
		pWaitSemaphoreInfos      = &waitInfo,
		signalSemaphoreInfoCount = len(signalInfos),
		pSignalSemaphoreInfos    = raw_data(signalInfos[:]),
		commandBufferInfoCount   = 1,
		pCommandBufferInfos      = &vk.CommandBufferSubmitInfo {
			commandBuffer = cb^,
			sType = .COMMAND_BUFFER_SUBMIT_INFO,
		},
	}
	sync.mutex_lock(&vkh.computeQueueMutex)
	vk.QueueSubmit2(vkh.graphicsQueue, 1, &submitInfo, vkh.fences[vkh.frameIndex])

	// Present
	vkh.frameIndex = (vkh.frameIndex + 1) % vkh.MAX_FRAMES_IN_FLIGHT
	ui.frame_reset()

	vkh.vk_chk_swapchain(
		vk.QueuePresentKHR(
			vkh.graphicsQueue,
			&vk.PresentInfoKHR {
				sType = .PRESENT_INFO_KHR,
				waitSemaphoreCount = 1,
				pWaitSemaphores = &vkh.renderSemaphores[vkh.imageIndex],
				swapchainCount = 1,
				pSwapchains = &vkh.swapchain,
				pImageIndices = &vkh.imageIndex,
			},
		),
	)
	sync.mutex_unlock(&vkh.computeQueueMutex)

}
