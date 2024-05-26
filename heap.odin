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

// Range               | Location
// --------------------|-----------------
// <= REGION_MAX_ALLOC | Region: A single page that is subdivided for smaller allocations.
//                     |
// <  PAGES_MAX_ALLOC  | Pages: Arrays of pages. Main purpose is to reduce the number of
//                     |        individual memory mappings. Some systems default to 65535.
//                     |
// >= PAGES_MAX_ALLOC  | Independent: Individual mappings at this piont. Huge pages?

heap_alloc :: proc(size: int, alignment: int = size_of(Region_Chunk), zero_memory: bool = true) -> rawptr {
	if size <= REGION_MAX_ALLOC {
		return _region_alloc(size, alignment, zero_memory)
	}
	if size < PAGES_MAX_ALLOC {
		return _pages_alloc(size, alignment, zero_memory)
	}
	return _independent_alloc(size, alignment, zero_memory)
}

heap_resize :: proc(old_memory: rawptr, new_size: int, new_alignment: int = size_of(Region_Chunk), zero_memory: bool = true) -> rawptr {
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

// impl

CHUNKS_PER_MAP_CELL   :: size_of(Map_Cell) * 8 / 2
MAP_CELLS_PER_REGION  :: PAGE_SIZE / size_of(Region_Chunk) / CHUNKS_PER_MAP_CELL

REGION_CHUNK_COUNT    :: REGION_BYTES_PER_PAGE / size_of(Region_Chunk)
REGION_BYTES_PER_PAGE :: (PAGE_SIZE - size_of(Region_Header))

Region_Header :: struct #align(16) {
	chunk_map:         [MAP_CELLS_PER_REGION]Map_Cell,
	in_use:            u8,
	max_align:         u8,
	map_in_use_end:    u8,
	max_map_end:       u8, // no zeroing beyond here necessary
	_:                 u32,
	local_region_addr: rawptr,
}
#assert(offset_of(Region_Header, in_use) == 64)
DEFAULT_REGION_HEADER : Region_Header : {
	max_align = REGION_MAX_ALIGN / size_of(Region_Chunk)
}

Region :: struct {
	header: Region_Header,
	chunks: [REGION_CHUNK_COUNT]Region_Chunk,  // User Data
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

Map_Cell     :: u64
Region_Chunk :: [16]u8

// Regions are stored linearly in multiple buffers
// using the page_allocator that has been configured
// to not allow the data to move. When we fail to
// resize, just start a new buffer.
_region_list      : [dynamic][]Region
_region_list_mutex: sync.Mutex

REGION_IN_USE :: rawptr(~uintptr(0))

// ownership:  &_local_region == _local_region.header.local_region_addr
@thread_local _local_region:     ^Region
@thread_local _local_list_index: int

_region_aquire_try :: proc(target: rawptr) -> (success: bool) {
	target := target
	owner := sync.atomic_compare_exchange_strong_explicit(
		&target,
		&_local_region,
		REGION_IN_USE,
		.Acquire,
		.Relaxed,
	)
	return owner == &_local_region
}

_region_release :: proc() {
}

_region_alloc :: proc(size, align: int, zero_memory: bool) -> rawptr {
	region_list_find_fit :: proc(size, align: int) -> (success: bool) {
		list := _region_list[_local_list_index]
		curr := mem.ptr_sub(_local_region, &list[0])
		i := (curr + 1) % len(list)
		for ; i != curr; i = (i + 1) % len(list) {
			if success = _region_aquire_try(&list[i].header.local_region_addr); !success {
				continue
			}
			if size > (REGION_CHUNK_COUNT - int(list[i].header.map_in_use_end)) ||
			   align > int(list[i].header.max_align) {
				continue
			}

			/* TODO: Try to FIT IT !!! */
		}

		return /* TODO */
	}

	size  := max(size / size_of(Region_Chunk), 1)
	align := max(align / size_of(Region_Chunk), 1)

	if _region_list == nil {
		sync.mutex_lock(&_region_list_mutex)
		defer sync.mutex_unlock(&_region_list_mutex)

		if _region_list == nil {
			internal_allocator := _page_allocator()
			err: mem.Allocator_Error
			_region_list, err = make([dynamic][]Region, 1, PAGE_SIZE / size_of(_region_list[0]), internal_allocator)
			assert(err == nil)

			external_allocator := _page_allocator({.Unmovable_Pages})
			_region_list[0], err = make([]Region, 16, external_allocator)
			_region_list[0][0].header = DEFAULT_REGION_HEADER
		}
	}

	if _local_region == nil { _local_region = &_region_list[0][0] }

	success := _region_aquire_try(&_local_region.header.local_region_addr)
	/* TODO: check if space */
	for ; !success; {
		// region stolen by another thread; find new one
		success = region_list_find_fit(size, align)
	}

	return nil
}

_region_resize :: proc(old_memory: rawptr, size, align: int, zero_memory: bool) -> rawptr {
	size  := max(size / size_of(Region_Chunk), 1)
	align := max(align / size_of(Region_Chunk), 1)

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
