package main
import "../modules/tracy"
import "base:intrinsics"
import "core:bufio"
import "core:container/lru"
import "core:container/small_array"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"
import "gs"
import "vendor:compress/lz4"
import "vendor:stb/easy_font"
import "vendor:zlib"
// illuver realm region file
IRRF_CHUNKS_PER_FILE_PER_DIR :: 6
IRRF_CHUNKS_PER_FILE :: IRRF_CHUNKS_PER_FILE_PER_DIR * IRRF_CHUNKS_PER_FILE_PER_DIR

index_into_irrf_scalar :: proc "contextless" (x, z: i32) -> i32 {
	return x * IRRF_CHUNKS_PER_FILE_PER_DIR + z
}

index_into_irrf_vector :: proc "contextless" (v: [2]i32) -> i32 {
	return v[0] * IRRF_CHUNKS_PER_FILE_PER_DIR + v[1]
}
index_into_irrf :: proc {
	index_into_irrf_vector,
	index_into_irrf_scalar,
}
IRRF_POINTS_BYTES :: MAX_POINTS * size_of(u16)
IRRF_HEIGHT_BYTES :: VERTS_PER_X_DIR * VERTS_PER_Z_DIR * size_of(i32)
IRRF_CHUNK_SIZE_IN_BYTES :: (IRRF_POINTS_BYTES + IRRF_HEIGHT_BYTES)
#assert(int(IRRF_POINTS_BYTES) < int(max(u32)))


IRRF_CHUNK_DATA :: struct {
	heightmap: [VERTS_PER_X_DIR * VERTS_PER_Z_DIR]i32,
	points:    [MAX_POINTS]u16,
}
InMemoryIRRF :: struct {
	data:        [IRRF_CHUNKS_PER_FILE]IRRF_CHUNK_DATA,
	initialized: [IRRF_CHUNKS_PER_FILE]bool,
	mutex:       sync.RW_Mutex,
	path:        string,
	handle:      ^os.File,
}
IRRF_HEADER_SIZE :: size_of(bool) * IRRF_CHUNKS_PER_FILE

MAX_IRRFS_IN_MEMORY := CHUNKS_PER_DIRECTION * CHUNKS_PER_DIRECTION
IRRFCacheMutex: sync.RW_Mutex
IRRFCache: lru.Cache([2]i32, InMemoryIRRF)


IRRFNextFreeIndex := 0

chunk_pos_to_irrf_pos :: proc "contextless" (pos: [2]i32) -> [2]i32 {
	region: i32 = CHUNK_STRIDE * IRRF_CHUNKS_PER_FILE_PER_DIR

	return [2]i32{math.floor_div(pos[0], region) * region, math.floor_div(pos[1], region) * region}
}
irrf_pos_to_file_path :: proc(irrfPos: [2]i32) -> string {
	assert(WorldAllocator != {})

	path, err := filepath.join(
		{"singleplayer", "realms", fmt.tprint(gs.seed), fmt.tprint(irrfPos)},
		WorldAllocator,
	)
	ensure(err == nil)
	return path
}
irrf_set_chunk :: proc(
	pos: [2]i32,
	points: ^[MAX_POINTS]u16,
	heightmap: ^[CHUNK_HEIGHTMAP_SIZE]i32,
) {
	tracy.Zone()
	assert(points != nil)
	assert(heightmap != nil)
	assert(pos[0] % CHUNK_STRIDE == 0)
	assert(pos[1] % CHUNK_STRIDE == 0)


	irrfFile: ^InMemoryIRRF
	inCache: bool
	irrfPos := chunk_pos_to_irrf_pos(pos)

	{
		sync.lock(&IRRFCacheMutex)
		defer sync.unlock(&IRRFCacheMutex)

		irrfFile, inCache = lru.get_ptr(&IRRFCache, irrfPos)
		if !inCache {
			lru.set(&IRRFCache, irrfPos, InMemoryIRRF{})
			irrfFile, inCache = lru.get_ptr(&IRRFCache, irrfPos)
			assert(inCache)
			osErr: os.Error
			irrfFile.path = irrf_pos_to_file_path(irrfPos)

			{
				sync.lock(&irrfFile.mutex)
				defer sync.unlock(&irrfFile.mutex)

				if os.exists(irrfFile.path) {
					irrfFile.handle, osErr = os.open(irrfFile.path, {.Read, .Write})
					ensure(osErr == nil, "could not open irrf file")
				} else {
					osErr = os.mkdir_all(filepath.dir(irrfFile.path))
					if osErr != .Exist do ensure(osErr == nil)
					irrfFile.handle, osErr = os.create(irrfFile.path)
					ensure(osErr == nil)
				}

			}


		}
	}


	assert(inCache)
	assert(irrfFile != nil)
	assert(irrfFile.path != "")

	{
		sync.lock(&irrfFile.mutex)
		defer sync.unlock(&irrfFile.mutex)

		localPos := (pos - irrfPos) / CHUNK_STRIDE
		indexIntoIrrfScalar := index_into_irrf(localPos)
		assert(indexIntoIrrfScalar >= 0)

		irrfFile.data[indexIntoIrrfScalar].points = points^
		irrfFile.data[indexIntoIrrfScalar].heightmap = heightmap^
		irrfFile.initialized[indexIntoIrrfScalar] = true


		tempPath := fmt.tprintf("%s.tmp", irrfFile.path)
		tempHandle, err := os.create(tempPath)
		// defer _ = os.remove(tempPath)
		ensure(err == nil)


		_, err = os.write(tempHandle, mem.slice_to_bytes(irrfFile.initialized[:]))
		ensure(err == nil)


		dataBytes := mem.slice_to_bytes(irrfFile.data[:])
		irrf_compress_to_file(tempHandle, dataBytes)

		if irrfFile.handle != nil {
			err = os.close(irrfFile.handle)
			ensure(err == nil)
		}
		err = os.rename(tempPath, irrfFile.path)
		ensure(err == nil)

		irrfFile.handle = tempHandle
	}

}
irrf_get_chunk :: proc(
	pos: [2]i32,
	points: ^[MAX_POINTS]u16,
	heightmap: ^[CHUNK_HEIGHTMAP_SIZE]i32,
) -> (
	wasInCache: bool,
) {
	tracy.Zone()

	assert(pos[0] % CHUNK_STRIDE == 0)
	assert(pos[1] % CHUNK_STRIDE == 0)


	irrfFile: ^InMemoryIRRF
	inCache: bool
	irrfPos := chunk_pos_to_irrf_pos(pos)


	{
		sync.shared_lock(&IRRFCacheMutex)
		irrfFile, inCache = lru.get_ptr(&IRRFCache, irrfPos)
		sync.shared_unlock(&IRRFCacheMutex)

		if !inCache {
			irrfFilePath := irrf_pos_to_file_path(irrfPos)
			if !os.exists(irrfFilePath) {
				return false
			}
			sync.lock(&IRRFCacheMutex)
			defer sync.unlock(&IRRFCacheMutex)
			lru.set(&IRRFCache, irrfPos, InMemoryIRRF{})
			irrfFile, inCache = lru.get_ptr(&IRRFCache, irrfPos)
			assert(inCache)


			osErr: os.Error
			{
				sync.lock(&irrfFile.mutex)
				defer sync.unlock(&irrfFile.mutex)

				irrfFile.handle, osErr = os.open(irrfFilePath, {.Read, .Write})
				ensure(osErr == nil)
				irrfFile.path = irrfFilePath


				_, osErr = os.read_at(
					irrfFile.handle,
					mem.slice_to_bytes(irrfFile.initialized[:]),
					0,
				)
				ensure(osErr == nil)

				irrf_decompress_to_buffer(irrfFile.handle, mem.slice_to_bytes(irrfFile.data[:]))
				// defer delete(compressed, context.temp_allocator)

			}

		}
	}


	assert(inCache)
	assert(irrfFile != nil)
	assert(irrfFile.path != "")

	localPos := (pos - irrfPos) / CHUNK_STRIDE
	indexIntoIrrfScalar := index_into_irrf(localPos)

	{
		sync.shared_lock(&irrfFile.mutex)
		defer sync.shared_unlock(&irrfFile.mutex)
		if irrfFile.initialized[indexIntoIrrfScalar] == false do return false

		points^ = irrfFile.data[indexIntoIrrfScalar].points
		heightmap^ = irrfFile.data[indexIntoIrrfScalar].heightmap

	}

	return true
}


irrf_cache_on_remove :: proc(key: [2]i32, value: InMemoryIRRF, user_data: rawptr) {
	os.close(value.handle)
}
irrf_compress_to_file :: proc(handle: ^os.File, data: []byte) {
	bound := lz4.compressBound(i32(len(data)))
	compressed := make([]byte, bound, context.temp_allocator)

	size := lz4.compress_default(raw_data(data), raw_data(compressed), i32(len(data)), bound)
	ensure(size > 0)
	osErr: os.Error

	_, osErr = os.seek(handle, IRRF_HEADER_SIZE, .Start)
	ensure(osErr == nil)


	_, osErr = os.write(handle, compressed[:size])
	ensure(osErr == nil)
}

irrf_decompress_to_buffer :: proc(handle: ^os.File, out: []byte) {
	fileSize, fileSizeErr := os.file_size(handle)
	ensure(fileSizeErr == nil)
	// Guard against truncated files: without this, the subtraction underflows
	// (i64) and we make a multi-exabyte allocation that OOMs the process.
	ensure(fileSize >= IRRF_HEADER_SIZE, "irrf file is truncated below header")
	compressed := make([]byte, fileSize - IRRF_HEADER_SIZE, context.temp_allocator)

	_, seekErr := os.seek(handle, IRRF_HEADER_SIZE, .Start)
	ensure(seekErr == nil)
	_, readErr := os.read(handle, compressed)
	ensure(readErr == nil)
	decompressed := lz4.decompress_safe(
		raw_data(compressed),
		raw_data(out),
		i32(len(compressed)),
		i32(len(out)),
	)
	ensure(decompressed == i32(len(out)))
}

//POINTER CAN CHANGE EVERY FRAME. MANUALLY CALL THIS FN WITH THE POSITON EVERY TIME TO ENSURE YOU ARE GETTING THE RIGHT DATA
// load_chunk :: proc(pos: [2]i32) -> ^Chunk {
// 	assert(pos[0] % CHUNK_STRIDE == 0)
// 	assert(pos[1] % CHUNK_STRIDE == 0)
// 	cornerChunkXZ := RenderedChunks[0][0].pos

// 	diff := cornerChunkXZ - pos
// 	MAXIMUM_CHUNK_DELTA_FROM_CORNER_CHUNK :: CHUNKS_PER_DIRECTION * CHUNK_STRIDE
// 	getFromRenderedChunks := diff[0] >= 0 && diff[0] < MAXIMUM_CHUNK_DELTA_FROM_CORNER_CHUNK
// 	getFromRenderedChunks =
// 		getFromRenderedChunks && diff[1] >= 0 && diff[1] < MAXIMUM_CHUNK_DELTA_FROM_CORNER_CHUNK
// 	when ODIN_DEBUG {
// 		worldWasNotInitialized :=
// 			RenderedChunks[0][0].pos == {} &&
// 			RenderedChunks[CHUNKS_PER_DIRECTION - 1][CHUNKS_PER_DIRECTION - 1].pos == {}
// 		assert(!worldWasNotInitialized)

// 	}

// 	// getFromRenderedChunks = getFromRenderedChunks && !worldWasNotInitialized

// 	if getFromRenderedChunks {
// 		idx := diff / CHUNK_STRIDE
// 		return &RenderedChunks[idx[0]][idx[1]]
// 	}


// }
