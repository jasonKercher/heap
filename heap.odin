package heap

import "base:runtime"
import "core:mem"
import "core:sync"
import "core:sys/linux"

// general purpose heap allocator

PAGE_SIZE :: 4096

// Divided into 3 parts by size:
REGION_MAX_ALIGN :: PAGE_SIZE / 2
REGION_MAX_ALLOC :: REGION_MAX_ALIGN

PAGES_MAX_ALIGN :: PAGES_MAX_ALLOC / 2
PAGES_MAX_ALLOC :: 16 * mem.Megabyte

// Range               | Loction
// --------------------|----------------
// <= REGION_MAX_ALLOC | Region: A single page that is subdivided for small allocations.
//                     |
// <  PAGES_MAX_ALLOC  | Pages: Arrays of pages. Main purpose is to reduce the number of
//                     |        individual memory mappings. Some systems limit this.
//                     |
// >= PAGES_MAX_ALLOC  | Independent: Individual mappings at this piont. Huge pages?

heap_alloc :: proc(size: int, alignment: int = size_of(Chunk16), zero_memory: bool = true) -> rawptr {
	if size <= REGION_MAX_ALLOC {
		return _region_alloc(size, alignment, zero_memory)
	}
	if size < PAGES_MAX_ALLOC {
		return _pages_alloc(size, alignment, zero_memory)
	}
	return _independent_alloc(size, alignment, zero_memory)
}

heap_resize :: proc(old_memory: rawptr, new_size: int, new_alignment: int = size_of(Chunk16), zero_memory: bool = true) -> rawptr {
	if old_memory == nil {
		return heap_alloc(new_size, new_alignment, zero_memory)
	}

	header: ^Pages_Header
	if !_is_page_aligned(old_memory) {
		return _region_resize(old_memory, new_size, new_alignment, zero_memory)
	} else {
		header = _pages_get_header(old_memory)
	}

	if header == nil {
		return _independent_resize(old_memory, new_size, new_alignment, zero_memory)
	}
	return _pages_resize(header, old_memory, new_size, new_alignment, zero_memory)
}

heap_free :: proc(memory: rawptr) {
	if memory == nil {
		return
	}

	header: ^Pages_Header
	if !_is_page_aligned(memory) {
		_region_free(memory)
	} else {
		header = _pages_get_header(memory)
	}

	if header == nil {
		_independent_free(memory)
	} else {
		_pages_free(header, memory)
	}
}

CHUNKS_PER_MAP_CELL   :: size_of(Map_Cell) * 8 / 2
MAP_CELLS_PER_REGION  :: PAGE_SIZE / size_of(Chunk16) / CHUNKS_PER_MAP_CELL
REGION_BYTES_PER_PAGE :: (PAGE_SIZE - size_of(Region_Header))
CHUNK16_PER_REGION    :: REGION_BYTES_PER_PAGE / size_of(Chunk16)

Region_Header :: struct #align(16) {
	chunk_map:   [MAP_CELLS_PER_REGION]Map_Cell,
	in_use:      u16,
	max_align:   u16,
	map_end:     u16,
	max_map_end: u16, // no zeroing beyond here necessary
	base_addr:   rawptr,
}
#assert(offset_of(Region_Header, in_use) == 64)
default_region_header : Region_Header : {
	max_align = REGION_MAX_ALIGN,
}

Region :: struct {
	header: Region_Header,
	chunks: [CHUNK16_PER_REGION]Chunk16,  // User Data
}
#assert(size_of(Region) == PAGE_SIZE)

Pages_Header :: struct {
	pages_base: rawptr,
	pages_cap:  int,
}

Cell_State :: enum i8 {
	Empty,
	Begin,
	Data,
	_,
}
#assert(int(max(Cell_State)) < 4) // 2 bit state

Map_Cell :: u64
Chunk16  :: [16]u8

// Regions are stored linearly in multiple linear
// buffers using the page_allocator that has been
// configured to not allow the data to move. Then,
// just start a new buffer.
_regions: [dynamic]Region
_regions_mutex: sync.Mutex

@thread_local _local_region: ^Region

_region_alloc :: proc(size, align: int, zero_memory: bool) -> rawptr {
	if _regions == nil {
		sync.mutex_lock(&_regions_mutex)
		defer sync.mutex_unlock(&_regions_mutex)

		if _regions == nil {
			page_allocator := runtime.Allocator { procedure = _page_allocator_proc }

			err: mem.Allocator_Error
			_regions, err = make([dynamic]Region, 1, 16, page_allocator)
			assert(err == nil)
			_page_allocator_set_config(&page_allocator.data, { .Unmovable_Buffers })
		}
	}

	// First find appropriate region

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

_pages_get_header :: proc(memory: rawptr) -> ^Pages_Header {
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
