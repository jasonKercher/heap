package heap

import "core:mem"
import "core:sync"
import "core:mem/virtual"

// general purpose heap allocator

PAGE_SIZE :: 4096

// Divided into 3 parts by size:
REGION_MAX_ALIGN :: PAGE_SIZE / 2
REGION_MAX_ALLOC :: REGION_MAX_ALIGN

PAGES_MAX_ALIGN :: 1 * mem.Megabyte
PAGES_MAX_ALLOC :: 1 * mem.Megabyte

INDEPENDENT_MIN_ALIGN :: 2 * mem.Megabyte

// Lookup Alignment    | Allocation Range    | Location
// --------------------| --------------------|-----------------
// < page aligned      | <= REGION_MAX_ALLOC | Region: A 4K page subdivided for small allocations
//                     |                     |
// page aligned &&     | <  PAGES_MAX_ALLOC  | Pages: Arrays of 4K pages
// < 2MB aligned       |                     |
//                     |                     |
// >= 2MB Alignment    | >= PAGES_MAX_ALLOC  | Independent: Individual mappings

heap_alloc :: proc(size: int, alignment: int = size_of(Region_Chunk), zero_memory: bool = true) -> rawptr {
	if size <= REGION_MAX_ALLOC {
		return _region_alloc(size, alignment, zero_memory)
	}
	if size < PAGES_MAX_ALLOC {
		return _pages_alloc(size, alignment, zero_memory)
	}
	return _independent_alloc(size, alignment) // no zero_memory
}

heap_resize :: proc(old_memory: rawptr, new_size: int, new_alignment: int = size_of(Region_Chunk), zero_memory: bool = true) -> rawptr {
	if old_memory == nil {
		return heap_alloc(new_size, new_alignment, zero_memory)
	}
	if new_size == 0 {
		heap_free(old_memory)
		return nil
	}

	if !virtual.page_aligned(old_memory) {
		return _region_resize(old_memory, new_size, new_alignment, zero_memory)
	} else if (uintptr(old_memory) & (INDEPENDENT_MIN_ALIGN - 1)) != 0 {
		return _pages_resize(old_memory, new_size, new_alignment, zero_memory)
	} else {
		return _independent_resize(old_memory, new_size, new_alignment, zero_memory)
	}
}

heap_free :: proc(memory: rawptr, size: int = 0) {
	if memory == nil {
		return
	}
	if !virtual.page_aligned(memory) {
		_region_free(memory)
	} else if (uintptr(memory) & (INDEPENDENT_MIN_ALIGN - 1)) != 0 {
		_pages_free(memory)
	} else {
		_independent_free(memory, size)
	}
}

// Region impl
BITS_PER_CELL_STATE :: 2
CHUNKS_PER_CELL     :: size_of(Cell) * 8 / BITS_PER_CELL_STATE
CELLS_PER_REGION    :: PAGE_SIZE / size_of(Region_Chunk) / CHUNKS_PER_CELL

REGION_CHUNK_COUNT    :: REGION_BYTES_PER_PAGE / size_of(Region_Chunk)
REGION_BYTES_PER_PAGE :: (PAGE_SIZE - size_of(Region_Header))

Region_Header :: struct #align(16) {
	chunk_map:         [CELLS_PER_REGION]Cell,
	in_use:            u8,
	max_align:         u8,
	map_in_use_end:    u8,
	max_map_end:       u8, // no zeroing beyond here necessary
	_:                 u32,
	local_region_addr: rawptr,
}
#assert(offset_of(Region_Header, in_use) == 64)

DEFAULT_REGION_HEADER : Region_Header : {
	max_align = REGION_MAX_ALIGN / size_of(Region_Chunk),
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

// 2 bit state
STATE_EMPTY   :: 0x0
STATE_BEGIN   :: 0x1
STATE_DATA    :: 0x2
STATE_BLOCKED :: 0x3

// STATE_BEGIN followed by STATE_DATA
CELL_FILL_MASK_BEGIN :: 0x6aaaaaaaaaaaaaaa
CELL_FILL_MASK_DATA  :: 0xaaaaaaaaaaaaaaaa

Cell :: u64
Region_Chunk :: [16]u8

_region_list: [dynamic][dynamic]Region
_region_list_mutex: sync.Mutex

REGION_IN_USE :: rawptr(~uintptr(0))

@thread_local _local_region:     ^Region
@thread_local _local_list_index: int

_region_aquire_try :: proc(region: ^Region) -> (success: bool) {
	target := region.header.local_region_addr
	owner := sync.atomic_compare_exchange_strong_explicit(&target, &_local_region, REGION_IN_USE, .Acquire, .Relaxed)
	return owner == &_local_region
}

_region_release :: proc() {
	sync.atomic_store_explicit(&_local_region.header.local_region_addr, &_local_region, .Release)
}

_region_list_find_fit :: proc(size, align: int) -> (ptr: rawptr, success: bool) {
	list := _region_list[_local_list_index]
	curr := int(uintptr(_local_region) - uintptr(&list[0])) / size_of(Region)

	i := curr
	for {
		if success := _region_aquire_try(&list[i]); !success {
			continue
		}
		defer _region_release()

		hdr := &list[i].header
		if size > (REGION_CHUNK_COUNT - int(hdr.map_in_use_end)) ||
		   align > int(list[i].header.max_align) {
			continue
		}

		stride := max(align / size_of(Region_Chunk) / CHUNKS_PER_CELL, 1)
		start  := mem.align_forward_int(size_of(Region_Header), align) / size_of(Region_Chunk)

		idx := _chunk_fit(hdr.chunk_map[:], size / size_of(Region_Chunk), stride, start)
		if idx != -1 {
			return &list[i].chunks[idx], true
		}

		i = (i + 1) % len(list)
		if i == curr {
			break
		}
	}
	return nil, false
}

_region_allocator: virtual.Page_Allocator

_region_alloc :: proc(size, align: int, zero_memory: bool) -> rawptr {
	chunk_size  := max(size / size_of(Region_Chunk), 1)
	chunk_align := max(align / size_of(Region_Chunk), 1)

	// region init
	if _region_list == nil {
		sync.mutex_lock(&_region_list_mutex)
		defer sync.mutex_unlock(&_region_list_mutex)

		if _region_list == nil {
			// TODO: better...
			@static region_list_allocator: virtual.Page_Allocator
			virtual.page_allocator_init(&region_list_allocator, {.Never_Free})

			err: mem.Allocator_Error
			_region_list, err = make([dynamic][dynamic]Region, virtual.page_allocator())
			assert(err == nil)

			virtual.page_allocator_init(&_region_allocator, {.Fixed})
			_region_list[0], err = make([dynamic]Region, virtual.page_allocator(&_region_allocator))
			assert(err == nil)

			_region_list[0][0].header = DEFAULT_REGION_HEADER
		}
	}

	if _local_region == nil {
		_local_region = &_region_list[0][0]
	}

	curr := _local_list_index
	for {
		ptr, success := _region_list_find_fit(chunk_size, chunk_align)
		if success {
			return ptr
		}

		_local_list_index = (_local_list_index + 1) % len(_region_list)
		if _local_list_index != curr {
			continue
		}

		// exhausted all active regions and ran out of lists
		err: mem.Allocator_Error
		if _local_list_index, err = append_nothing(&_region_list[_local_list_index]); err != nil {
			// failed to grow in place, just make a whole new list
			_local_list_index = 0
			list: [dynamic]Region
			list, err = make([dynamic]Region, virtual.page_allocator(&_region_allocator))
			if err != nil {
				return nil
			}
			sync.mutex_lock(&_region_list_mutex)
			defer sync.mutex_unlock(&_region_list_mutex)
			append_elem(&_region_list, list)
		}

		// impossible to fail here as we have an fresh region
		ptr, _ = _region_list_find_fit(chunk_size, chunk_align)
		return ptr
	}

	return nil
}

_region_resize :: proc(old_memory: rawptr, size, align: int, zero_memory: bool) -> rawptr {
	region := (^Region)(mem.align_backward(old_memory, mem.DEFAULT_PAGE_SIZE))
	chunk_idx := uintptr(old_memory) - uintptr(&region.chunks) / size_of(Region_Chunk)

	old_size := _size_lookup(region.header.chunk_map[:], int(chunk_idx))
	aligned_old_size := mem.align_forward_int(old_size, size_of(Region_Chunk))
	aligned_size := mem.align_forward_int(size, size_of(Region_Chunk))
	if aligned_old_size == aligned_size {
		return old_memory
	}

	// TODO: if < old_size
	// TODO: else if >

	end_of_old_memory := int(uintptr(old_memory)) + old_size
	// TODO: try to grow in place


	new_ptr  := heap_alloc(size, align, zero_memory)
	mem.copy_non_overlapping(new_ptr, old_memory, old_size)
	_region_free(old_memory)
	return new_ptr
}

_region_free :: proc(old_memory: rawptr) {
	// TODO
}

_chunk_idx_to_cell_and_bit :: proc(chunk_idx: int) -> (cell: int, bit: uint) {
	cell = chunk_idx / CHUNKS_PER_CELL
	bit  = uint(chunk_idx % CHUNKS_PER_CELL)
	return
}

_size_lookup :: proc(chunk_map: []Cell, chunk_idx: int) -> int {
	cell, bit := _chunk_idx_to_cell_and_bit(chunk_idx)

	assert(chunk_map[cell] >> bit & 0x3 == STATE_BEGIN)
	i := chunk_idx + 1

	// TODO: this is probably inefficient
	for ; i < len(chunk_map) * CHUNKS_PER_CELL; i += 1 {
		cell, bit = _chunk_idx_to_cell_and_bit(i)
		if chunk_map[cell] >> bit & 0x3 != STATE_DATA {
			break
		}
	}
	return i - chunk_idx
}

_chunk_fit :: proc(chunk_map: []Cell, size, stride: int, offset: int = 0) -> int {
	size := size
	bit: uint
	cell: int

	idx := 0
	search_loop: for ; idx < len(chunk_map) * CHUNKS_PER_CELL; idx += stride {
		cell, bit = _chunk_idx_to_cell_and_bit(idx)
		if chunk_map[cell] >> bit & 0x3 != STATE_EMPTY {
			continue
		}
		if size == 1 {
			break
		}

		// TODO: this is probably inefficient
		available := 1
		for i := idx + 1 ; i < len(chunk_map) * CHUNKS_PER_CELL; i += 1 {
			c, b := _chunk_idx_to_cell_and_bit(idx)
			if chunk_map[c] >> b & 0x3 != STATE_EMPTY {
				continue search_loop
			}

			available += 1
			if available == size {
				break search_loop
			}
		}
	}
	if idx >= size_of(chunk_map) * CHUNKS_PER_CELL {
		return -1
	}

	// success, populate the map
	mask := Cell(CELL_FILL_MASK_BEGIN >> bit)
	for ; size > 0; size -= CHUNKS_PER_CELL {
		if bit / BITS_PER_CELL_STATE > uint(size) {
			clamp_back := ~u64(0) << uint(size) * 2
			mask &= clamp_back
		}
		chunk_map[cell] |= mask
		mask = CELL_FILL_MASK_DATA
	}

	return idx
}

// Pages impl

_pages_alloc :: proc(size, align: int, zero_memory: bool) -> rawptr {
	unimplemented()
}

_pages_resize :: proc(old_memory: rawptr, new_size, align: int, zero_memory: bool) -> rawptr {
	unimplemented()
}

_pages_free :: proc(old_memory: rawptr) {
	unimplemented()
}

// Independent impl

// The page allocator requires size information to properly unmap pages
_independent_map: map[rawptr]u32
_independent_lock: sync.Mutex // TODO: use this
_independent_allocator: virtual.Page_Allocator

_independent_alloc :: proc(size, align: int) -> rawptr {
	// This map could be removed if we always have size
	if _independent_map == nil {
		_independent_map = make(map[rawptr]u32, 16, virtual.page_allocator())
		virtual.page_allocator_init(&_independent_allocator, {.Allow_Large_Pages})
	}

	bytes, err := virtual.page_aligned_alloc(size, align, 0, _independent_allocator.flags, &_independent_allocator.platform)
	if err == nil {
		return nil
	}
	aligned_size := mem.align_forward_int(size, mem.DEFAULT_PAGE_SIZE)
	page_count := u32(aligned_size / mem.DEFAULT_PAGE_SIZE)
	_independent_map[&bytes[0]] = page_count
	return &bytes[0]
}

_independent_resize :: proc(old_memory: rawptr, new_size, align: int, zero_memory: bool) -> rawptr {
	old_size_4k, found := _independent_map[old_memory]
	if !found {
		return nil
	}

	flags := _independent_allocator.flags
	if zero_memory {
		flags -= {.Uninitialized_Memory}
	} else {
		flags += {.Uninitialized_Memory}
	}

	old_size := int(uint(old_size_4k) * virtual.DEFAULT_PAGE_SIZE)
	if old_size == new_size {
		return old_memory
	}

	bytes, err := virtual.page_aligned_resize(old_memory,
						  old_size,
						  new_size,
						  align,
						  0,
						  flags,
						  &_independent_allocator.platform)
	if err != nil {
		return nil
	}
	if &bytes[0] != old_memory {
		delete_key(&_independent_map, old_memory)
	}
	aligned_size := mem.align_forward_int(new_size, mem.DEFAULT_PAGE_SIZE)
	page_count := u32(aligned_size / mem.DEFAULT_PAGE_SIZE)
	_independent_map[&bytes] = page_count
	return &bytes[0]
}

_independent_free :: proc(old_memory: rawptr, size: int = 0) {
	size := size
	if size == 0 {
		if size_4k, found := _independent_map[old_memory]; found {
			size = int(size_4k * mem.DEFAULT_PAGE_SIZE)
		} else {
			return
		}
	}
	delete_key(&_independent_map, old_memory)
	virtual.page_free(old_memory, size, {}, &_independent_allocator.platform)
}

