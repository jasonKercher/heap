package heap

import "core:fmt"
import "core:mem"


main :: proc() {
	ptr := heap_alloc(50)
	ptr2 := heap_alloc(42)

	context.allocator = { procedure = _page_allocator_proc }
	efficiency := new([2 * mem.Megabyte]u8)
	fmt.printf("%v %v %v\n", ptr, ptr2, &efficiency[0])
}

