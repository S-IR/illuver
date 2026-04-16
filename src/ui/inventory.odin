package ui


SpellbarSlot :: enum {
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

Spellbar :: [SpellbarSlot]u16

DEFAULT_BAG_SIZE :: 16
StartingBag :: [DEFAULT_BAG_SIZE]u16

bag_spellbar_init :: proc() -> (s: Spellbar, b: StartingBag) {
	return s, b
}
