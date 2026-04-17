package main
import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "gs"
import "ui"
import stbImage "vendor:stb/image"
import vk "vendor:vulkan"
import "vkh"
SpellbarSlot :: enum u32 {
	One,
	Two,
	Three,
	Four,
	Five,
	Six,
	Seven,
	Eight,
	Nine,
}

// Spellbar ::

DEFAULT_BAG_SIZE :: 16
// StartingBag :: [DEFAULT_BAG_SIZE]u16
INVENTORY_SLOT_MAX_COUNT: u8 : 99
InventorySlot :: struct {
	val:   PointType,
	count: u8,
}
#assert(max(type_of(InventorySlot{}.count)) >= INVENTORY_SLOT_MAX_COUNT)
Inventory :: struct {
	spellbar: struct {
		spells:   [SpellbarSlot]InventorySlot,
		selected: SpellbarSlot,
	},
	bag:      struct {
		default: [DEFAULT_BAG_SIZE]InventorySlot,
	},
	usedFont: ui.BMFont,
}
TexturesPerPointType := [PointType]vkh.GPUTexture{}

inventory_init :: proc(cb: vk.CommandBuffer, usedFont: ui.BMFont) -> (inventory: Inventory) {
	// s.selected = .One
	for &t in TexturesPerPointType do t = ui.vkDummyTexture


	#assert(#exists("../build/assets/textures/yellow-dirt.png"))
	pointTypeTexturePaths := #partial [PointType]cstring {
		.YellowDirt = "assets" + filepath.SEPARATOR_STRING + "textures" + filepath.SEPARATOR_STRING + "yellow-dirt.png",
	}

	for path, pointType in pointTypeTexturePaths {
		if pointType == .Air do continue
		if len(path) == 0 do break
		inputs: vkh.ImageLoaderInputs
		DESIRED_CHANNELS :: 4
		inputs.data = stbImage.load(path, &inputs.width, &inputs.height, nil, DESIRED_CHANNELS)
		assert(inputs.data != nil)
		defer stbImage.image_free(inputs.data)
		inputs.magFilter = .LINEAR
		inputs.minFilter = .LINEAR
		inputs.channels = DESIRED_CHANNELS
		TexturesPerPointType[pointType] = vkh.load_image(inputs, cb)

	}
	inventory.spellbar.selected = .One
	inventory.usedFont = usedFont
	return inventory
}
inventory_destroy :: proc(i: ^Inventory) {
	for t, pointType in TexturesPerPointType {
		if pointType == .Air do continue
		if t.id == ui.VK_UI_DUMMY_TEXTURE_ID do break
		vkh.gpu_texture_destroy(t)
	}
}
spellbar_select :: proc(inventory: ^Inventory, val: u32) {
	assert(val >= 1 && val <= 9)
	inventory.spellbar.selected = SpellbarSlot(val - 1)

	// TexturesPerPointType[.YellowDirt] = vkh.
}
InventoryType :: enum {
	Spellbar,
	BagDefault,
}
inventory_add_item :: proc(inventory: ^Inventory, point: PointType) -> (hasEnoughSpace: bool) {
	emptySlotIdx: int = -1
	hasEmptySlotInventoryType: InventoryType


	for &spell, i in inventory.spellbar.spells {
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
	for &b, i in inventory.bag.default {
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
			assert(inventory.spellbar.spells[SpellbarSlot(emptySlotIdx)] == {})
			inventory.spellbar.spells[SpellbarSlot(emptySlotIdx)] = {
				count = 1,
				val   = point,
			}
		case .BagDefault:
			assert(inventory.bag.default[emptySlotIdx] == {})
			inventory.bag.default[emptySlotIdx] = {
				count = 1,
				val   = point,
			}
		}
		return true
	}
	return false
}
spellbar_render :: proc(inventory: ^Inventory) {
	// if !spellbarIsOpen do return
	// add_rect(f32(0), f32(0), f32(gs.screenWidth), f32(gs.screenHeight), [4]f32{.1, .1, .1, .25})
	halfScreen := gs.screenWidth / 2
	spellbarLen := halfScreen - halfScreen / 5
	spellbarOneSpellWidth := spellbarLen / len(inventory.spellbar.spells)
	spellbarOneSpellHeight := spellbarOneSpellWidth * 1

	currX := halfScreen - spellbarLen / 2
	currY := gs.screenHeight - spellbarOneSpellHeight - 30

	for spell, i in inventory.spellbar.spells {
		if spell.val == .Air {
			color :=
				[4]f32{.03, .27, .86, 1} if i != inventory.spellbar.selected else [4]f32{1, 1, 1, 1}
			ui.add_rect(
				f32(currX),
				f32(currY),
				f32(spellbarOneSpellWidth),
				f32(spellbarOneSpellHeight),
				color,
			)

		} else {
			texture := TexturesPerPointType[spell.val]
			assert(texture != ui.vkDummyTexture)
			ui.add_image(
				f32(currX),
				f32(currY),
				f32(spellbarOneSpellWidth),
				f32(spellbarOneSpellHeight),
				texture,
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
