package main
import "camera"
import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "gs"
import "ui"
import stbImage "vendor:stb/image"
import vk "vendor:vulkan"
import "vkh"

// Spellbar ::

DEFAULT_BAG_SIZE :: 16
// StartingBag :: [DEFAULT_BAG_SIZE]u16
INVENTORY_SLOT_MAX_COUNT: u8 : 255
InventorySlot :: struct {
	val:   PointType,
	count: u8,
}
#assert(max(type_of(InventorySlot{}.count)) >= INVENTORY_SLOT_MAX_COUNT)
InventoryData :: struct {
	spellbar: struct {
		spells:   [9]InventorySlot,
		selected: uint,
	},
	bag:      struct {
		default: [DEFAULT_BAG_SIZE]InventorySlot,
	},
}
Inventory :: struct {
	data:     InventoryData,
	usedFont: ui.BMFont,
}
InventoryTexturesAtlas := vkh.GPUTexture{}

inventory_init :: proc(cb: vk.CommandBuffer, usedFont: ui.BMFont) -> (inventory: Inventory) {
	// s.selected = .One
	// for &t in InventoryTexturesAtlas do t = ui.vkDummyTexture


	atlasPath: cstring :
		"assets" +
		filepath.SEPARATOR_STRING +
		"textures" +
		filepath.SEPARATOR_STRING +
		"inventory-atlas.png"
	#assert(#exists("../build/" + atlasPath))

	inputs: vkh.ImageLoaderInputs
	DESIRED_CHANNELS :: 4
	inputs.data = stbImage.load(atlasPath, &inputs.width, &inputs.height, nil, DESIRED_CHANNELS)
	assert(inputs.data != nil)
	defer stbImage.image_free(inputs.data)
	inputs.magFilter = .LINEAR
	inputs.minFilter = .LINEAR
	inputs.channels = DESIRED_CHANNELS
	InventoryTexturesAtlas = vkh.load_image(inputs, cb)

	inventory.data.spellbar.selected = 0
	inventory.usedFont = usedFont
	return inventory
}
inventory_destroy :: proc(i: ^Inventory) {
	if (i != nil) do vkh.gpu_texture_destroy(InventoryTexturesAtlas)
}
spellbar_select :: proc(inventory: ^Inventory, val: uint) {
	assert(val >= 0 && val <= 8)
	inventory.data.spellbar.selected = val

	// TexturesPerPointType[.YellowDirt] = vkh.
}
InventoryType :: enum {
	Spellbar,
	BagDefault,
}
inventory_add_item :: proc(inventory: ^Inventory, point: PointType) -> (hasEnoughSpace: bool) {
	assert(point != .Air)
	emptySlotIdx: int = -1
	hasEmptySlotInventoryType: InventoryType


	for &spell, i in inventory.data.spellbar.spells {
		if emptySlotIdx == -1 && spell.val == .Air {
			emptySlotIdx = int(i)
			hasEmptySlotInventoryType = .Spellbar

			// spell.val = point
			// return true
		}
		if spell.val == point {
			assert(spell.count <= INVENTORY_SLOT_MAX_COUNT)
			if spell.count == INVENTORY_SLOT_MAX_COUNT {
				continue
			} else {
				spell.count += 1
				return true
			}
		}

	}
	for &b, i in inventory.data.bag.default {
		if emptySlotIdx == -1 && b.val == .Air {
			emptySlotIdx = i
			hasEmptySlotInventoryType = .BagDefault
		}

		if b.val == point {
			assert(b.count <= INVENTORY_SLOT_MAX_COUNT)
			if b.count == INVENTORY_SLOT_MAX_COUNT {
				continue
			} else {
				b.count += 1
				return true
			}
		}

	}
	if emptySlotIdx != -1 {
		switch hasEmptySlotInventoryType {
		case .Spellbar:
			assert(inventory.data.spellbar.spells[emptySlotIdx] == {})

			inventory.data.spellbar.spells[emptySlotIdx] = {
				count = 1,
				val   = point,
			}
		case .BagDefault:
			assert(inventory.data.bag.default[emptySlotIdx] == {})
			inventory.data.bag.default[emptySlotIdx] = {
				count = 1,
				val   = point,
			}
		}
		return true
	}
	return false
}
inventory_get_selected_point :: proc(inventory: ^Inventory) -> PointType {
	return inventory.data.spellbar.spells[inventory.data.spellbar.selected].val
}
inventory_reduce_amount_from_selected :: proc(inventory: ^Inventory) {
	assert(inventory.data.spellbar.selected < len(inventory.data.spellbar.spells))
	assert(inventory.data.spellbar.spells[inventory.data.spellbar.selected] != {})
	inventory.data.spellbar.spells[inventory.data.spellbar.selected].count -= 1
	if inventory.data.spellbar.spells[inventory.data.spellbar.selected].count == 0 {
		inventory.data.spellbar.spells[inventory.data.spellbar.selected] = {}
	}

}
spellbar_render :: proc(inventory: ^Inventory) {
	// if !spellbarIsOpen do return
	// add_rect(f32(0), f32(0), f32(gs.screenWidth), f32(gs.screenHeight), [4]f32{.1, .1, .1, .25})
	halfScreen := gs.screenWidth / 2
	spellbarLen := halfScreen - halfScreen / 5
	spellbarOneSpellWidth := spellbarLen / len(inventory.data.spellbar.spells)
	spellbarOneSpellHeight := spellbarOneSpellWidth * 1

	currX := halfScreen - spellbarLen / 2
	currY := gs.screenHeight - spellbarOneSpellHeight - 30

	for spell, i in inventory.data.spellbar.spells {
		if spell.val == .Air {
			color :=
				[4]f32{.03, .27, .86, 1} if uint(i) != inventory.data.spellbar.selected else [4]f32{1, 1, 1, 1}
			ui.add_rect(
				f32(currX),
				f32(currY),
				f32(spellbarOneSpellWidth),
				f32(spellbarOneSpellHeight),
				color,
			)

		} else {

			assert(InventoryTexturesAtlas != ui.vkDummyTexture)
			ui.add_image(
				f32(currX),
				f32(currY),
				f32(spellbarOneSpellWidth),
				f32(spellbarOneSpellHeight),
				InventoryTexturesAtlas,
			)
			countText := fmt.tprint(spell.count)
			countTextFontSize: f32 = 32
			textWidth, textHeight := ui.measure_text(
				countText,
				inventory.usedFont,
				countTextFontSize,
			)
			textX: f32 = f32(currX) + (f32(spellbarOneSpellWidth / 2) - (textWidth / 2))
			textY: f32 = f32(currY) + (f32(spellbarOneSpellHeight / 2) - (textHeight / 2))
			ui.add_text(
				countText,
				inventory.usedFont,
				countTextFontSize,
				f32(textX),
				f32(textY),
				{1, 1, 1, 1},
			)
		}
		currX += spellbarOneSpellWidth
	}

}
