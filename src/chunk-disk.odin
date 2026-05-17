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
IRRF_CHUNKS_PER_FILE_PER_Y_DIR :: 4
IRRF_CHUNKS_PER_FILE_PER_XZ_DIR :: 6
IRRF_CHUNKS_PER_FILE ::
	IRRF_CHUNKS_PER_FILE_PER_XZ_DIR *
	IRRF_CHUNKS_PER_FILE_PER_Y_DIR *
	IRRF_CHUNKS_PER_FILE_PER_XZ_DIR

index_into_irrf_scalar :: #force_inline proc(x, y, z: i32) -> i32 {
	assert(x >= 0 && x < IRRF_CHUNKS_PER_FILE_PER_XZ_DIR)
	assert(y >= 0 && y < IRRF_CHUNKS_PER_FILE_PER_Y_DIR)
	assert(z >= 0 && z < IRRF_CHUNKS_PER_FILE_PER_XZ_DIR)


	return(
		x * IRRF_CHUNKS_PER_FILE_PER_XZ_DIR * IRRF_CHUNKS_PER_FILE_PER_Y_DIR +
		y * IRRF_CHUNKS_PER_FILE_PER_XZ_DIR +
		z \
	)
}

index_into_irrf_vector :: #force_inline proc(v: [3]i32) -> i32 {
	assert(v.x >= 0 && v.x < IRRF_CHUNKS_PER_FILE_PER_XZ_DIR)
	assert(v.y >= 0 && v.y < IRRF_CHUNKS_PER_FILE_PER_Y_DIR)
	assert(v.z >= 0 && v.z < IRRF_CHUNKS_PER_FILE_PER_XZ_DIR)
	return(
		v.x * IRRF_CHUNKS_PER_FILE_PER_XZ_DIR * IRRF_CHUNKS_PER_FILE_PER_Y_DIR +
		v.y * IRRF_CHUNKS_PER_FILE_PER_XZ_DIR +
		v.z \
	)
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
	header:      IrrfDiskHeader,
	mutex:       sync.RW_Mutex,
	path:        string,
	handle:      ^os.File,
}
IRRF_HEADER_SIZE :: size_of(bool) * IRRF_CHUNKS_PER_FILE

MAX_IRRFS_IN_MEMORY := 36
IRRFCacheMutex: sync.RW_Mutex
IRRFCache: lru.Cache([3]i32, InMemoryIRRF)


IRRFNextFreeIndex := 0

chunk_pos_to_irrf_pos :: proc "contextless" (pos: [3]i32) -> [3]i32 {
	regionXZ: i32 : CHUNK_STRIDE_XZ * IRRF_CHUNKS_PER_FILE_PER_XZ_DIR
	regionY: i32 : CHUNK_STRIDE_Y * IRRF_CHUNKS_PER_FILE_PER_Y_DIR

	posRounded := [3]i32 {
		math.floor_div(pos.x, regionXZ) * regionXZ,
		math.floor_div(pos.y, regionY) * regionY,
		math.floor_div(pos.z, regionXZ) * regionXZ,
	}

	return posRounded
}
irrf_pos_to_file_path :: proc(irrfPos: [3]i32) -> string {
	assert(WorldAllocator != {})

	path, err := filepath.join(
		{"singleplayer", "realms", fmt.tprint(gs.seed), fmt.tprint(irrfPos)},
		WorldAllocator,
	)
	ensure(err == nil)
	return path
}
IrrfDiskHeader :: struct {
	chunksIs16:           [IRRF_CHUNKS_PER_FILE_PER_XZ_DIR *
	IRRF_CHUNKS_PER_FILE_PER_Y_DIR *
	IRRF_CHUNKS_PER_FILE_PER_XZ_DIR]bool,
	pointTypeTranslation: [IRRF_CHUNKS_PER_FILE_PER_XZ_DIR *
	IRRF_CHUNKS_PER_FILE_PER_Y_DIR *
	IRRF_CHUNKS_PER_FILE_PER_XZ_DIR]IrrfChunkHeader,
}

IrrfChunkHeader :: [max(u8)]struct {
	realPointType: u16,
	total:         uint,
}
irrf_init_chunk :: proc(
	pos: [3]i32,
	points: ^[MAX_POINTS]u16,
	heightmap: ^[CHUNK_HEIGHTMAP_SIZE]i32,
) {
	tracy.Zone()
	assert(points != nil)
	assert(heightmap != nil)
	assert(pos.x % CHUNK_STRIDE_XZ == 0)
	assert(pos.y % CHUNK_STRIDE_Y == 0)
	assert(pos.z % CHUNK_STRIDE_XZ == 0)


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
					_, osErr = os.seek(irrfFile.handle, 0, .Start)
					ensure(osErr == nil, os.error_string(osErr))


				} else {
					osErr = os.mkdir_all(filepath.dir(irrfFile.path))
					if osErr != .Exist do ensure(osErr == nil)
					irrfFile.handle, osErr = os.create(irrfFile.path)

					ensure(osErr == nil, os.error_string(osErr))
					_, err := os.seek(irrfFile.handle, 0, .Start)
					ensure(osErr == nil, os.error_string(err))

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


		nextIdx := 0
		assert(irrfPos.x <= pos.x)
		assert(irrfPos.y <= pos.y)
		assert(irrfPos.z <= pos.z)

		localPos := (pos - irrfPos) / [3]i32{CHUNK_STRIDE_XZ, CHUNK_STRIDE_Y, CHUNK_STRIDE_XZ}
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
	pos: [3]i32,
	points: ^[MAX_POINTS]u16,
	heightmap: ^[CHUNK_HEIGHTMAP_SIZE]i32,
) -> (
	wasInCache: bool,
) {
	// tracy.Zone()

	assert(pos.x % CHUNK_STRIDE_XZ == 0)
	assert(pos.y % CHUNK_STRIDE_Y == 0)
	assert(pos.z % CHUNK_STRIDE_XZ == 0)


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

	localPos := (pos - irrfPos) / [3]i32{CHUNK_STRIDE_XZ, CHUNK_STRIDE_Y, CHUNK_STRIDE_XZ}
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


irrf_cache_on_remove :: proc(key: [3]i32, value: InMemoryIRRF, user_data: rawptr) {
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
