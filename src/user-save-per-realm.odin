package main
import "camera"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "gs"
User_Info_Per_Save :: struct {
	currCamera:    camera.Camera,
	inventoryData: InventoryData,
}

user_info_realm_init :: proc(
) -> (
	userInfoFileHandle: ^os.File,
	existingInfo: User_Info_Per_Save,
	foundExisting: bool,
) {
	defer assert(userInfoFileHandle != nil)
	path, allocErr := filepath.join(
		{"singleplayer", "realms", fmt.tprint(gs.seed), "info"},
		context.temp_allocator,
	)
	ensure(allocErr == nil)
	err: os.Error

	if !os.exists(path) {
		err = os.mkdir_all(filepath.dir(path, context.temp_allocator))
		if err != .Exist do ensure(err == nil)
		userInfoFileHandle, err = os.create(path)
		ensure(err == nil)
		return userInfoFileHandle, {}, false
	} else {
		userInfoFileHandle, err = os.open(path, {.Read, .Write})
		ensure(err == nil)

		if DEBUG_MODE_IGNORE_SAVE {
			return userInfoFileHandle, {}, false
		}
		fileSize: i64
		fileSize, err = os.file_size(userInfoFileHandle)
		ensure(err == nil)
		if fileSize == 0 {
			return userInfoFileHandle, {}, false
		}

		infoBytes: [size_of(User_Info_Per_Save)]byte
		n: int
		n, err = os.read(userInfoFileHandle, infoBytes[:])
		ensure(err == nil)
		ensure(n == len(infoBytes))
		reinterpreted := (^User_Info_Per_Save)(raw_data(infoBytes[:]))^
		return userInfoFileHandle, reinterpreted, true

	}
}
user_info_frame_end_store :: proc(userInfoFileHandle: ^os.File, info: ^User_Info_Per_Save) {
	assert(userInfoFileHandle != nil)

	_, err := os.seek(userInfoFileHandle, 0, .Start)
	ensure(err == nil)

	_, err = os.write(userInfoFileHandle, mem.byte_slice(info, size_of(User_Info_Per_Save)))
	ensure(err == nil)
}
