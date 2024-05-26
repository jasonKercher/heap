package heap

import "base:runtime"
import "core:fmt"
import "core:mem"


main :: proc() {
	_check_page_allocator()
}

_check_page_allocator :: proc() {
	context.allocator = _page_allocator()
	ptr ,err := new(int)
	fmt.printf("%p ", ptr)

	ptr, err = runtime.new_aligned(int, 1 * mem.Kilobyte)
	fmt.printf(" 1:%p ", ptr)
	ptr, err = runtime.new_aligned(int, 4 * mem.Kilobyte)
	fmt.printf(" 4:%p ", ptr)
	ptr, err = runtime.new_aligned(int, 8 * mem.Kilobyte)
	fmt.printf(" 8:%p ", ptr)
	ptr, err = runtime.new_aligned(int, 16 * mem.Kilobyte)
	fmt.printf("16:%p ", ptr)
	ptr, err = runtime.new_aligned(int, 32 * mem.Kilobyte)
	fmt.printf("32:%p ", ptr)
	ptr, err = runtime.new_aligned(int, 64 * mem.Kilobyte)
	fmt.printf("64:%p ", ptr)
	
	fmt.printf("\n")

	ptr, err = runtime.new_aligned(int, 8 * mem.Megabyte)
	fmt.printf("8M:%p ", ptr)
	ptr, err = runtime.new_aligned(int, 2 * mem.Gigabyte)
	fmt.printf("2G:%p ", ptr)

	fmt.printf("\n")
}

