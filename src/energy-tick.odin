package main

import "../modules/tracy"
import "base:intrinsics"
import "core:simd"

@(rodata)
LIFE_MASK_VEC := #simd[8]u16 {
	LIFE_MASK,
	LIFE_MASK,
	LIFE_MASK,
	LIFE_MASK,
	LIFE_MASK,
	LIFE_MASK,
	LIFE_MASK,
	LIFE_MASK,
}
LIGHT_MASK_VEC := #simd[8]u16 {
	LIGHT_MASK,
	LIGHT_MASK,
	LIGHT_MASK,
	LIGHT_MASK,
	LIGHT_MASK,
	LIGHT_MASK,
	LIGHT_MASK,
	LIGHT_MASK,
}

broadcast_u16 :: #force_inline proc "contextless" (val: u16) -> #simd[8]u16 {
	return #simd[8]u16{val, val, val, val, val, val, val, val}
}
point_tick_energy :: proc "contextless" (
	point: u16,
	neighbors: [6]u16,
	energyTickType: bit_set[EnergyType],
) -> u16 {
	l0 := get_life(point)
	L0 := get_light(point)
	w0 := get_wisdom(point)

	v := #simd[8]u16 {
		neighbors[0],
		neighbors[1],
		neighbors[2],
		neighbors[3],
		neighbors[4],
		neighbors[5],
		0,
		0,
	}

	life := simd.shr(v, LIFE_SHIFT) & LIFE_MASK_VEC
	light := simd.shr(v, LIGHT_SHIFT) & LIGHT_MASK_VEC

	zeroVec := broadcast_u16(0)
	oneVec := broadcast_u16(1)

	lifeCountVec := simd.select(simd.lanes_gt(life, zeroVec), oneVec, zeroVec)
	lifeCount := intrinsics.simd_reduce_add_ordered(lifeCountVec)

	lightSum := intrinsics.simd_reduce_add_ordered(light)

	l0Vec := broadcast_u16(l0)
	L0Vec := broadcast_u16(L0)
	combined := (life ~ l0Vec) | (light ~ L0Vec)
	diff := simd.lanes_ne(combined, zeroVec)
	diffCountVec := simd.select(diff, oneVec, zeroVec)
	diffCount := intrinsics.simd_reduce_add_ordered(diffCountVec)

	newLife := l0
	newLight := L0
	newWisdom := w0

	if .Life in energyTickType {
		newLife = u16(
			(int(lifeCount > 1) & 1) + (int(lifeCount > 3) & 1) + (int(lifeCount > 5) & 1),
		)
	}
	if .Light in energyTickType {
		avg := lightSum / 6
		if avg > L0 && L0 < 3 {
			newLight = L0 + 1
		} else if avg < L0 && L0 > 0 {
			newLight = L0 - 1
		}
	}
	if .Wisdom in energyTickType {
		if diffCount < 2 {
			if w0 > 0 {
				newWisdom = w0 - 1
			}
		} else if diffCount < 5 {
			if diffCount >= 3 && w0 < 3 {
				newWisdom = w0 + 1
			}
		} else {
			newWisdom = 3
		}
	}

	result := point
	if .Life in energyTickType {
		result = (result & ~(LIFE_MASK << LIFE_SHIFT)) | (newLife << LIFE_SHIFT)
	}
	if .Light in energyTickType {
		result = (result & ~(LIGHT_MASK << LIGHT_SHIFT)) | (newLight << LIGHT_SHIFT)
	}
	if .Wisdom in energyTickType {
		result = (result & ~(WISDOM_MASK << WISDOM_SHIFT)) | (newWisdom << WISDOM_SHIFT)
	}

	return result
}
