package heap

import "core:sys/linux"
import "core:sync"
import "core:mem"

PAGE_SIZE :: 4096

CHUNKS_PER_MAP_CELL   :: size_of(Map_Cell) * 8 / 2
MAP_CELLS_PER_REGION  :: PAGE_SIZE / size_of(Chunk) / CHUNKS_PER_MAP_CELL
REGION_BYTES_PER_PAGE :: (PAGE_SIZE - size_of(Region_Header))
CHUNKS_PER_REGION     :: REGION_BYTES_PER_PAGE / size_of(Chunk)



REGION_GROUP_COUNT :: 16

Map_Cell :: u64
Chunk    :: [16]u8

Region_Header :: struct #align(16) {
	chunk_map: [MAP_CELLS_PER_REGION]Map_Cell,
	map_end:   u16,
	_:         u16,
	_:         u16,
	_:         u16,
	_:         u64,
}

// Each chunk's state is represented by 2 bits in a Map_Cell. A chunk is the
// smallest allocation. Regions are page aligned.
Region :: struct {
	header: Region_Header,
	chunks: [CHUNKS_PER_REGION]Chunk,  // User Data
}
#assert(size_of(Region) == PAGE_SIZE)

Pages_Header :: struct {
	data: rawptr
}

Cell_State :: enum {
	Empty,
	Begin,
	Mid_Allocation,
	Back,
}


heap_alloc :: proc(size: int, alignment: int = size_of(Chunk), zero_memory: bool = true) -> rawptr {
	if size < PAGE_SIZE / 2 {
		return _region_alloc(size, alignment, zero_memory)
	}
	if size < 2 * mem.Megabyte {
		return _pages_alloc(size, alignment, zero_memory)
	}
	return _independent_alloc(size, alignment, zero_memory)
}

heap_resize :: proc(old_memory: rawptr, new_size: int, new_alignment: int = size_of(Chunk), zero_memory: bool = true) -> rawptr {
	header: ^Pages_Header
	if !_is_page_aligned(old_memory) {
		return _region_resize(old_memory, new_size, new_alignment, zero_memory)
	} else {
		header = _pages_get(old_memory)
	}

	if header == nil {
		return _independent_resize(old_memory, new_size, new_alignment, zero_memory)
	}
	return _pages_resize(header, old_memory, new_size, new_alignment, zero_memory)
}

heap_free :: proc(memory: rawptr) {
	header: ^Pages_Header
	if !_is_page_aligned(memory) {
		_region_free(memory)
	} else {
		header = _pages_get(memory)
	}

	if header == nil {
		_independent_free(memory)
	} else {
		_pages_free(header, memory)
	}
}

_region_alloc :: proc(size, align: int, zero_memory: bool) -> rawptr {
	return nil
}

_region_resize :: proc(old_memory: rawptr, new_size, align: int, zero_memory: bool) -> rawptr {
	return nil
}

_region_free :: proc(old_memory: rawptr) {
}

_pages_alloc :: proc(size, align: int, zero_memory: bool) -> rawptr {
	unimplemented()
}

_pages_resize :: proc(pages: ^Pages_Header, old_memory: rawptr, new_size, align: int, zero_memory: bool) -> rawptr {
	unimplemented()
}

_pages_free :: proc(pages: ^Pages_Header, old_memory: rawptr) {
	unimplemented()
}

_pages_get :: proc(memory: rawptr) -> ^Pages_Header {
	return {}
}

_independent_alloc :: proc(size, align: int, zero_memory: bool) -> rawptr {
	unimplemented()
}

_independent_resize :: proc(old_memory: rawptr, new_size, align: int, zero_memory: bool) -> rawptr {
	unimplemented()
}

_independent_free :: proc(old_memory: rawptr) {
	unimplemented()
}

_chunk_find_fit :: proc(chunk_map: []Map_Cell, map_end: int, size: int, align: int = 1, align_penalty: int = 0) {
	i := 0

	// align_penalty accounts for user data offset
	if align > align_penalty {
		
	}

	stride := max(align / CHUNKS_PER_MAP_CELL, 1)
	for ; i < len(chunk_map); i += stride {

	}
}
