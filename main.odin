package heap

import "base:runtime"
import "core:fmt"
import "core:mem"


main :: proc() {
	_check_page_allocator()
}

_run_new :: proc(alignment: int) {
	ptr, err := runtime.new_aligned(int, alignment)
	assert(err == nil)

	if g_last_was_huge {
		fmt.printf("%16x|%9d|%9d|%p # 2MB pages\n", alignment, g_tail_waste, g_head_waste, ptr)
	} else {
		fmt.printf("%16x|%9d|%9d|%p\n", alignment, g_tail_waste, g_head_waste, ptr)
	}
}

_check_page_allocator :: proc() {
	context.allocator = _page_allocator()

	ptr, _ := new(int)
	fmt.printf(" Align Request  | Tail    | Head    | Address\n")
	fmt.printf("----------------|---------|---------|--------\n")
	fmt.printf("align_of(int)   | ????    | ????    |%p\n", ptr)
	
	_run_new(1   * mem.Kilobyte)
	_run_new(2   * mem.Kilobyte)
	_run_new(4   * mem.Kilobyte)
	_run_new(8   * mem.Kilobyte)
	_run_new(64  * mem.Kilobyte)
	_run_new(256 * mem.Kilobyte)
	_run_new(1   * mem.Megabyte)
	_run_new(8   * mem.Megabyte)
	_run_new(128 * mem.Megabyte)

	fmt.printf("\n")
}

