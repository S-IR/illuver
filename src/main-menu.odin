package main
import sdl "vendor:sdl3"

import "core:sync"
import "gs"
import "ui"
import vk "vendor:vulkan"
import "vkh"
MouseState :: struct {
	x, y:         f32,
	didLeftClick: bool,
}
main_menu_render :: proc(mainMenuFont: ui.BMFont, ms: MouseState, renderData: struct {
		uiPipeline: ^vkh.PipelineData,
	}) {
	cb := vkh.drawCommandBuffers[vkh.frameIndex]
	vk_begin_frame(cb)
	ui.add_rect(0, 0, f32(gs.screenWidth), f32(gs.screenHeight), [4]f32{0.5, 0.5, 0.5, 1})

	currY: f32 = 50

	// Title
	fontWidth, fontHeight := ui.measure_text("Illuver", mainMenuFont, 32)
	ui.add_text(
		"Illuver",
		mainMenuFont,
		32,
		ui.put_in_middle(fontWidth, f32(gs.screenWidth)),
		currY,
		[4]f32{1, 1, 1, 1},
	)

	currY += fontHeight + f32(gs.screenHeight) / 20

	// SINGLEPLAYER BUTTON
	spTextWidth, spTextHeight := ui.measure_text("Singleplayer", mainMenuFont, 28)

	spRectWidth := spTextWidth + spTextHeight
	spRectHeight := spTextHeight + spTextHeight * 0.5
	spRectX := ui.put_in_middle(spRectWidth, f32(gs.screenWidth))

	hoverSp := ui.is_rect_hovered({ms.x, ms.y}, spRectX, currY, spRectWidth, spRectHeight)
	leftClickThisFrame := .LEFT in sdl.GetMouseState(nil, nil)
	clickSp := hoverSp && leftClickThisFrame
	if hoverSp {
		ui.add_rect(spRectX, currY, spRectWidth, spRectHeight, [4]f32{0.3, 0.3, 0.3, 1})
		if clickSp do gs.CurrGameScreen = .SpRealms
	} else {
		ui.add_rect(spRectX, currY, spRectWidth, spRectHeight, [4]f32{0.2, 0.2, 0.2, 1})
	}

	ui.add_text(
		"Singleplayer",
		mainMenuFont,
		28,
		spRectX + (spRectWidth - spTextWidth) * 0.5,
		currY + (spRectHeight - spTextHeight) * 0.5,
		[4]f32{0.9, 0.9, 0.9, 1},
	)

	currY += spRectHeight + f32(gs.screenHeight) / 20

	// QUIT BUTTON
	quitTextWidth, quitTextHeight := ui.measure_text("Quit", mainMenuFont, 28)

	quitRectWidth := quitTextWidth + quitTextHeight
	quitRectHeight := quitTextHeight + quitTextHeight * 0.5
	quitRectX := ui.put_in_middle(quitRectWidth, f32(gs.screenWidth))

	hoverQuit := ui.is_rect_hovered({ms.x, ms.y}, quitRectX, currY, quitRectWidth, quitRectHeight)
	clickQuit := hoverQuit && (ms.didLeftClick)

	quitLeftClick := hoverQuit && leftClickThisFrame
	if hoverQuit {
		ui.add_rect(quitRectX, currY, quitRectWidth, quitRectHeight, [4]f32{0.3, 0.3, 0.3, 1})
		if quitLeftClick {
			gs.quit = true
		}
	} else {
		ui.add_rect(quitRectX, currY, quitRectWidth, quitRectHeight, [4]f32{0.2, 0.2, 0.2, 1})
	}

	ui.add_text(
		"Quit",
		mainMenuFont,
		28,
		quitRectX + (quitRectWidth - quitTextWidth) * 0.5,
		currY + (quitRectHeight - quitTextHeight) * 0.5,
		[4]f32{0.9, 0.9, 0.9, 1},
	)

	// Render UI
	ui.render(cb, renderData.uiPipeline^)
	vk_end_frame(&cb)

}
sp_realm_menu_render :: proc(mainMenuFont: ui.BMFont, ms: MouseState, renderData: struct {
		uiPipeline: ^vkh.PipelineData,
	}) {
	cb := vkh.drawCommandBuffers[vkh.frameIndex]
	vk_begin_frame(cb)
	ui.add_rect(0, 0, f32(gs.screenWidth), f32(gs.screenHeight), [4]f32{1, 1, 1, 1})

	currY: f32 = 50

	fontWidth, fontHeight := ui.measure_text("Realms", mainMenuFont, 32)
	ui.add_text(
		"Realms",
		mainMenuFont,
		32,
		ui.put_in_middle(fontWidth, f32(gs.screenWidth)),
		currY,
		[4]f32{1, 1, 1, 1},
	)

	currY += fontHeight + f32(gs.screenHeight) / 20

	// SINGLEPLAYER BUTTON
	newRealmTextWidth, newRealmTextHeight := ui.measure_text("New Realm", mainMenuFont, 28)

	newRealmRectWidth := newRealmTextWidth + newRealmTextHeight
	newRealmRectHeight := newRealmTextHeight + newRealmTextHeight * 0.5
	newRealmRectX := ui.put_in_middle(newRealmRectWidth, f32(gs.screenWidth))

	hoverNewRealm := ui.is_rect_hovered(
		{ms.x, ms.y},
		newRealmRectX,
		currY,
		newRealmRectWidth,
		newRealmRectHeight,
	)
	leftClickThisFrame := ms.didLeftClick
	clickNewRealm := hoverNewRealm && leftClickThisFrame
	if hoverNewRealm {
		ui.add_rect(
			newRealmRectX,
			currY,
			newRealmRectWidth,
			newRealmRectHeight,
			[4]f32{0.3, 0.3, 0.3, 1},
		)
		if clickNewRealm do gs.CurrGameScreen = .Loading
	} else {
		ui.add_rect(
			newRealmRectX,
			currY,
			newRealmRectWidth,
			newRealmRectHeight,
			[4]f32{0.2, 0.2, 0.2, 1},
		)
	}

	ui.add_text(
		"New Realm",
		mainMenuFont,
		28,
		newRealmRectX + (newRealmRectWidth - newRealmTextWidth) * 0.5,
		currY + (newRealmRectHeight - newRealmTextHeight) * 0.5,
		[4]f32{0.9, 0.9, 0.9, 1},
	)

	currY += newRealmRectHeight + f32(gs.screenHeight) / 20


	// Render UI
	ui.render(cb, renderData.uiPipeline^)
	vk_end_frame(&cb)

}

loading_screen_render :: proc(mainMenuFont: ui.BMFont, renderData: struct {
		uiPipeline: ^vkh.PipelineData,
	}) {
	cb := vkh.drawCommandBuffers[vkh.frameIndex]
	vk_begin_frame(cb)
	ui.add_rect(0, 0, f32(gs.screenWidth), f32(gs.screenHeight), [4]f32{0.1, 0.1, 0.1, 1})

	textWidth, textHeight := ui.measure_text("Loading...", mainMenuFont, 32)
	ui.add_text(
		"Loading...",
		mainMenuFont,
		32,
		ui.put_in_middle(textWidth, f32(gs.screenWidth)),
		ui.put_in_middle(textHeight, f32(gs.screenHeight)),
		[4]f32{1, 1, 1, 1},
	)

	ui.render(cb, renderData.uiPipeline^)
	vk_end_frame(&cb)
}
