package sim

// Generational handles.
//
// Everything in the world lives in a Pool and is referred to by Handle, never
// by pointer. Two reasons:
//
//   1. Pools grow. A [dynamic] realloc invalidates every raw pointer into it,
//      and a run that discovers hosts is appending constantly.
//   2. Things get removed. A handle to a removed object fails lookup instead of
//      silently resolving to whatever object later reused the slot.
//
// `gen` is what buys (2): the slot remembers how many times it has been reused,
// so a handle from a previous tenancy no longer matches. Generation 0 is never
// issued, which makes a zero-valued Handle permanently invalid -- so a
// forgotten field defaults to "nothing" instead of "host index 0".

Handle :: struct($T: typeid) {
	idx: u32,
	gen: u32,
}

Slot :: struct($T: typeid) {
	value: T,
	gen:   u32,
	live:  bool,
}

Pool :: struct($T: typeid) {
	slots:     [dynamic]Slot(T),
	free:      [dynamic]u32,
	live_count: int,
}

pool_init :: proc(p: ^Pool($T), cap: int = 16, allocator := context.allocator) {
	p.slots = make([dynamic]Slot(T), 0, cap, allocator)
	p.free = make([dynamic]u32, 0, cap, allocator)
	p.live_count = 0
}

// Only needed for pools that own their memory. Pools inside a World are backed
// by the run arena and get released wholesale by world_reset/world_destroy, so
// calling this on them is harmless but pointless.
pool_destroy :: proc(p: ^Pool($T)) {
	delete(p.slots)
	delete(p.free)
	p^ = {}
}

// Returns a handle that stays valid until the value is removed, across any
// number of intervening adds.
pool_add :: proc(p: ^Pool($T), value: T) -> Handle(T) {
	p.live_count += 1

	if len(p.free) > 0 {
		idx := pop(&p.free)
		slot := &p.slots[idx]
		slot.value = value
		slot.live = true
		// gen was already bumped on removal, so the old handle is stale.
		return Handle(T){idx = idx, gen = slot.gen}
	}

	idx := u32(len(p.slots))
	append(&p.slots, Slot(T){value = value, gen = 1, live = true})
	return Handle(T){idx = idx, gen = 1}
}

// The returned pointer is invalidated by any subsequent pool_add -- do not hold
// it across one. Take the handle, not the pointer.
pool_get :: proc(p: ^Pool($T), h: Handle(T)) -> (^T, bool) {
	if h.gen == 0 || int(h.idx) >= len(p.slots) {
		return nil, false
	}
	slot := &p.slots[h.idx]
	if !slot.live || slot.gen != h.gen {
		return nil, false
	}
	return &slot.value, true
}

pool_valid :: proc(p: ^Pool($T), h: Handle(T)) -> bool {
	_, ok := pool_get(p, h)
	return ok
}

pool_remove :: proc(p: ^Pool($T), h: Handle(T)) -> bool {
	if h.gen == 0 || int(h.idx) >= len(p.slots) {
		return false
	}
	slot := &p.slots[h.idx]
	if !slot.live || slot.gen != h.gen {
		return false
	}
	slot.live = false
	slot.value = {}
	// Bump now so every outstanding handle to this tenancy is dead immediately,
	// not just once the slot gets reused.
	slot.gen += 1
	if slot.gen == 0 {
		slot.gen = 1 // wrapped after 4 billion reuses; skip the reserved value
	}
	append(&p.free, h.idx)
	p.live_count -= 1
	return true
}

pool_len :: proc(p: ^Pool($T)) -> int {
	return p.live_count
}

// Iterate live values in slot order.
//
//	it: int
//	for value, handle in pool_iter(&w.hosts, &it) { ... }
pool_iter :: proc(p: ^Pool($T), it: ^int) -> (value: ^T, handle: Handle(T), ok: bool) {
	for int(it^) < len(p.slots) {
		idx := it^
		it^ += 1
		slot := &p.slots[idx]
		if slot.live {
			return &slot.value, Handle(T){idx = u32(idx), gen = slot.gen}, true
		}
	}
	return nil, {}, false
}
