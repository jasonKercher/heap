package heap

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"


main :: proc() {
	_check_page_allocator()
}

_run_new :: proc(alignment: int) {
	ptr, err := runtime.new_aligned(int, alignment)
	fmt.assertf(err == nil, "%v: ", err)
	defer free(ptr)

	if virtual.g_last_was_large {
		fmt.printf("%16x|%12x|%12x|%p # large pages\n", alignment, virtual.g_tail_waste, virtual.g_head_waste, ptr)
	} else {
		fmt.printf("%16x|%12x|%12x|%p\n", alignment, virtual.g_tail_waste, virtual.g_head_waste, ptr)
	}

}

_check_page_allocator :: proc() {
	context.allocator = virtual.page_allocator()

	ptr, _ := new(int)
	fmt.printf(" Align Request  | Tail       | Head       | Address\n")
	fmt.printf("----------------|------------|------------|-------------\n")
	fmt.printf("align_of(int)   | ????       | ????       |%p\n", ptr)
	
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
	_run_new(8   * mem.Gigabyte)
	_run_new(32  * mem.Gigabyte)

	fmt.printf("\n")
}

