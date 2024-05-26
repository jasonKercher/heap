package heap

import "base:runtime"
import "core:mem"
import "core:sys/linux"

MMAP_FLAGS   : linux.Map_Flags      : {.ANONYMOUS, .PRIVATE}
MMAP_PROT    : linux.Mem_Protection : {.READ, .WRITE}

PAGE_ALLOCATOR_MAX_ALIGNMENT :: 64 * mem.Kilobyte

/* TODO: REMOVE */
g_last_was_huge: bool
g_tail_waste: int
g_head_waste: int

Page_Allocator :: runtime.Allocator
Page_Allocator_Config_Bits :: enum {
	Unmovable_Pages,
}
Page_Allocator_Config :: bit_set[Page_Allocator_Config_Bits; uintptr]

// Overload the allocator_data to a bit_set.
_page_allocator_get_config :: proc(allocator_data: rawptr) -> Page_Allocator_Config {
	return transmute(Page_Allocator_Config)(allocator_data)
}

_page_allocator_set_config :: proc(allocator_data: ^rawptr, config: Page_Allocator_Config) {
	allocator_data^ = transmute(rawptr)(config)
}

_page_allocator :: proc(config: Page_Allocator_Config = {}) -> Page_Allocator {
	a : Page_Allocator = {
		procedure = _page_allocator_proc
	}
	_page_allocator_set_config(&a.data, config)
	return a
}

_page_allocator_aligned_alloc :: proc(size, alignment: int) -> ([]byte, mem.Allocator_Error) {
	if size == 0 {
		return nil, .Invalid_Argument
	}
	aligned_size      := mem.align_forward_int(size, PAGE_SIZE)
	aligned_alignment := mem.align_forward_int(alignment, PAGE_SIZE)

	mapping_size := aligned_size

	if alignment > PAGE_SIZE {
		// Add extra pages
		mapping_size += aligned_alignment - PAGE_SIZE
	}

	flags: linux.Map_Flags = MMAP_FLAGS

	// 1 GB *huge* page
	if aligned_size >= 1 * mem.Gigabyte || alignment >= 1 * mem.Gigabyte {
		raw_flags : i32 = transmute(i32)(MMAP_FLAGS) | i32(linux.MAP_HUGE_1GB)
		flags = transmute(linux.Map_Flags)(raw_flags)
		flags += {.HUGETLB}
		if ptr, errno := linux.mmap(0, uint(aligned_size), MMAP_PROT, flags); ptr != nil && errno == nil {
			g_last_was_huge = true
			g_head_waste = 0
			g_tail_waste = 0
			return mem.byte_slice(ptr, size), nil
		}
	}
	// 2 MB huge page
	if aligned_size >= 2 * mem.Megabyte || alignment >= 2 * mem.Megabyte {
		raw_flags : i32 = transmute(i32)(MMAP_FLAGS) | i32(linux.MAP_HUGE_2MB)
		flags = transmute(linux.Map_Flags)(raw_flags)
		flags += {.HUGETLB}
		if ptr, errno := linux.mmap(0, uint(aligned_size), MMAP_PROT, flags); ptr != nil && errno == nil {
			g_last_was_huge = true
			g_head_waste = 0
			g_tail_waste = 0
			return mem.byte_slice(ptr, size), nil
		}
	}
	g_last_was_huge = false
	ptr, errno := linux.mmap(0, uint(mapping_size), MMAP_PROT, MMAP_FLAGS)
	if errno != nil || ptr == nil {
		return nil, .Out_Of_Memory
	}

	// If these don't match, we added extra for alignment.
	// Find the correct alignment, and unmap the waste.
	if aligned_size != mapping_size {
		aligned_ptr := mem.align_forward_uintptr(uintptr(ptr), uintptr(aligned_alignment))

		g_head_waste = int(aligned_ptr - uintptr(ptr))
		g_tail_waste = (aligned_alignment - PAGE_SIZE) - g_head_waste
		if g_head_waste > 0 {
			linux.munmap(ptr, uint(g_head_waste))
		}
		if g_tail_waste > 0 {
			linux.munmap(rawptr(aligned_ptr + uintptr(aligned_size)), uint(g_tail_waste))
		}
		ptr = rawptr(aligned_ptr)
	}
	return mem.byte_slice(ptr, size), nil
}

_page_allocator_aligned_resize :: proc(old_ptr: rawptr,
	                               old_size, new_size, new_align: int,
				       zero_memory, allow_move: bool) -> (new_memory: []byte, err: mem.Allocator_Error) {
	if old_ptr == nil {
		return nil, nil
	}
	if !_is_page_aligned(old_ptr) {
		return nil, .Invalid_Pointer
	}
	new_ptr: rawptr

	new_align := new_align

	aligned_size      := mem.align_forward_int(new_size, PAGE_SIZE)
	aligned_alignment := mem.align_forward_int(new_align, PAGE_SIZE)

	// If we meet all our alignment requirements or we're not allowed to move,
	// we may be able to get away with doing nothing at all or growing in place.
	errno: linux.Errno
	if !allow_move || ((uintptr(aligned_alignment) - 1) & uintptr(old_ptr)) == 0 {
		if aligned_size == mem.align_forward_int(old_size, PAGE_SIZE) {
			return mem.byte_slice(old_ptr, old_size), nil
		}

		new_ptr, errno = linux.mremap(old_ptr, uint(old_size) , uint(new_size), {.FIXED})
		if new_ptr != nil && errno == nil {
			return mem.byte_slice(new_ptr, new_size), nil
		}
		if !allow_move {
			return mem.byte_slice(old_ptr, old_size), .Out_Of_Memory
		}
	}

	// If you want greater than page size alignment (and we failed to expand in place above),
	// send to aligned_alloc, manually copy the conents, and unmap the old mapping.
	if aligned_alignment > PAGE_SIZE {
		new_bytes: []u8
		new_align      = mem.align_forward_int(new_align, PAGE_ALLOCATOR_MAX_ALIGNMENT)
		new_bytes, err = _page_allocator_aligned_alloc(new_size, new_align)
		if new_bytes == nil || err != nil {
			return mem.byte_slice(old_ptr, old_size), err == nil ? .Out_Of_Memory : err
		}

		mem.copy_non_overlapping(&new_bytes[0], old_ptr, old_size)
		linux.munmap(old_ptr, mem.align_forward_uint(uint(old_size), PAGE_SIZE))

		return new_bytes[:new_size], nil
	}

	new_ptr, errno = linux.mremap(old_ptr,
	                              mem.align_forward_uint(uint(old_size), PAGE_SIZE),
	                              uint(aligned_size),
	                              {.MAYMOVE})
	if new_ptr == nil || errno != nil {
		return nil, .Out_Of_Memory
	}
	return mem.byte_slice(new_ptr, new_size), nil
}

_page_allocator_free :: proc(p: rawptr, size: int) {
	if p != nil && size >= 0 /* && page_aligned(p) && page_aligned(size) */ {
		// error ignored, but you might not it back anyway =]
		linux.munmap(p, uint(size))
	}
}

_page_allocator_proc :: proc(allocator_data: rawptr, mode: mem.Allocator_Mode,
                            size, alignment: int,
                            old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	zero_memory := true
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		return _page_allocator_aligned_alloc(size, alignment)

	case .Free:
		_page_allocator_free(old_memory, old_size)

	case .Free_All:
		return nil, .Mode_Not_Implemented

	case .Resize:
		break

	case .Resize_Non_Zeroed:
		zero_memory = false;
		break

	case .Query_Features:
		set := (^mem.Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {.Alloc, .Free, .Resize, .Query_Features}
		}
		return nil, nil

	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}

	// If you got here, we are resizing.
	if old_memory == nil {
		return _page_allocator_aligned_alloc(size, alignment)
	}
	if size == 0 {
		_page_allocator_free(old_memory, old_size)
		return nil, nil
	}

	may_move := .Unmovable_Pages not_in _page_allocator_get_config(allocator_data)
	return _page_allocator_aligned_resize(old_memory, old_size, size, alignment, zero_memory, may_move)
}

_heap_allocator_proc :: proc(allocator_data: rawptr, mode: mem.Allocator_Mode,
                            size, alignment: int,
                            old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	aligned_alloc :: proc(size, alignment: int, old_ptr: rawptr = nil) -> ([]byte, mem.Allocator_Error) {
		ptr: rawptr
		if old_ptr != nil {
			ptr = heap_resize(old_ptr, size, alignment)
		} else {
			ptr = heap_alloc(size, alignment)
		}

		if ptr == nil {
			return nil, .Out_Of_Memory
		}
		return mem.byte_slice(ptr, size), nil
	}

	aligned_free :: proc(p: rawptr) {
		if p != nil {
			heap_free(p)
		}
	}

	aligned_resize :: proc(p: rawptr, old_size: int, new_size: int, new_alignment: int) -> (new_memory: []byte, err: mem.Allocator_Error) {
		if p == nil {
			return nil, nil
		}
		return aligned_alloc(new_size, new_alignment, p)
	}

	switch mode {
	case .Alloc:
		return aligned_alloc(size, alignment)

	case .Alloc_Non_Zeroed:
		return aligned_resize(old_memory, old_size, size, alignment)

	case .Free:
		aligned_free(old_memory)

	case .Free_All:
		return nil, .Mode_Not_Implemented

	case .Resize, .Resize_Non_Zeroed:
		if old_memory == nil {
			return aligned_alloc(size, alignment)
		}
		return aligned_resize(old_memory, old_size, size, alignment)

	case .Query_Features:
		set := (^mem.Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {.Alloc, .Free, .Resize, .Query_Features}
		}
		return nil, nil

	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}

	return nil, nil
}

_is_page_aligned :: #force_inline proc(p: rawptr) -> bool {
	return (uintptr(p) & (PAGE_SIZE - 1)) == 0
}
