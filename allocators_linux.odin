package heap

import "core:mem"
import "core:sys/linux"

MMAP_FLAGS   : linux.Map_Flags      : {.ANONYMOUS, .PRIVATE}
MMAP_PROT    : linux.Mem_Protection : {.READ, .WRITE}

_is_page_aligned :: proc(p: rawptr) -> bool {
	return (uintptr(p) & ((1 << 12) - 1)) == 0
}

_page_allocator_aligned_alloc :: proc(size, alignment: int, old_ptr: rawptr = nil) -> ([]byte, mem.Allocator_Error) {
	if size == 0 {
		return nil, .Invalid_Argument
	}
	size := int(uintptr(mem.align_forward(rawptr(uintptr(size)), 4096)))

	/* NOTE: No guarantees of alignment over 4K, but we will
	 *       take a stab at huge pages if > 2MB.
	 */
	flags := MMAP_FLAGS
	if size > 1 * mem.Gigabyte {
		raw_flags := transmute(i32)(flags) | linux.MAP_HUGE_1GB
		flags = transmute(linux.Map_Flags)(raw_flags)
		flags += {.HUGETLB}
	} else if size > 2 * mem.Megabyte {
		raw_flags := transmute(i32)(flags) | linux.MAP_HUGE_2MB
		flags = transmute(linux.Map_Flags)(raw_flags)
		flags += {.HUGETLB}
	}

	ptr, mmap_err := linux.mmap(0, uint(size), MMAP_PROT, flags)
	if mmap_err != nil || ptr == nil {
		return nil, .Out_Of_Memory
	}
	return mem.byte_slice(ptr, size), nil
}

_page_allocator_aligned_resize :: proc(p: rawptr, old_size: int, new_size: int, new_alignment: int) -> (new_memory: []byte, err: mem.Allocator_Error) {
	if new_alignment > PAGE_SIZE { unimplemented() }
	if p == nil {
		return nil, nil
	}

	ptr, mremap_err := linux.mremap(p, uint(old_size) , uint(new_size), {.MAYMOVE})
	if ptr == nil || mremap_err != nil {
		return nil, .Out_Of_Memory
	}
	return mem.byte_slice(ptr, new_size), nil
}

_page_allocator_free :: proc(p: rawptr, size: int) {
	if p != nil && size >= 0 /* && page_aligned(p) && page_aligned(size) */ {
		// error ignored, but you probably won't make it back anyway =]
		linux.munmap(p, uint(size))
	}
}

_page_allocator_proc :: proc(allocator_data: rawptr, mode: mem.Allocator_Mode,
                            size, alignment: int,
                            old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {

	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		return _page_allocator_aligned_alloc(size, alignment)

	case .Free:
		_page_allocator_free(old_memory, old_size)

	case .Free_All:
		return nil, .Mode_Not_Implemented

	case .Resize, .Resize_Non_Zeroed:
		if old_memory == nil {
			return _page_allocator_aligned_alloc(size, alignment)
		}
		if size == 0 {
			_page_allocator_free(old_memory, old_size)
			return nil, nil
		}
		return _page_allocator_aligned_resize(old_memory, old_size, size, alignment)

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

