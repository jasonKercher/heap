package heap

import "core:fmt"
import "core:mem"
import "core:mem/virtual"

main :: proc() {
	_check_page_allocator()
}

_run_new :: proc(size: int, alignment: int = 8) {
	alignment := alignment
	alignment = size

	alignment = min(alignment, mem.Gigabyte)

	bytes: []u8
	err: mem.Allocator_Error

	bytes, err = virtual.page_aligned_alloc(size, alignment, 0, {.Allow_Large_Pages})
	fmt.assertf(err == nil, "%v", err)

	mem.set(&bytes[0], 0xaa, len(bytes))

	fmt.printf("A: %16x|%16x|%p\n", size, alignment, &bytes[0])

	bytes, err = virtual.page_aligned_resize(&bytes[0], size, size / 2, alignment, 0, {.Allow_Large_Pages})
	fmt.assertf(err == nil, "2: %v", err)

	fmt.printf("R: %16x|%16x|%p\n", size, alignment, &bytes[0])

	err = mem.free_bytes(bytes)
	if err != nil {
		fmt.println(err)
	}
}

_check_page_allocator :: proc() {
	context.allocator = virtual.page_allocator()

	ptr, _ := new(int)
	fmt.printf("    Size           | Align Request  | Address\n")
	fmt.printf("   ----------------|----------------|-------------\n")
	fmt.printf("   0000000000000008|align_of(int)   |%p\n", ptr)
	
	_run_new(1   * mem.Kilobyte)
	_run_new(2   * mem.Kilobyte)
	_run_new(4   * mem.Kilobyte)
	_run_new(8   * mem.Kilobyte)
	_run_new(16  * mem.Kilobyte)
	_run_new(32  * mem.Kilobyte)
	_run_new(64  * mem.Kilobyte)
	_run_new(256 * mem.Kilobyte)
	_run_new(1   * mem.Megabyte)
	_run_new(8   * mem.Megabyte)
	_run_new(128 * mem.Megabyte)
	//_run_new(8   * mem.Gigabyte)
	//_run_new(32  * mem.Gigabyte)

	fmt.printf("\n")
}

