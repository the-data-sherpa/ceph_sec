package sim

// Segmentation is the load-bearing idea of the whole game.
//
// A flat network where every host can reach every other host has no pivoting,
// no lateral movement, and therefore no real decisions -- you would just attack
// the weakest host and win. Real corporate networks are segmented, and the
// interesting work is getting from the segment you landed in to the segment
// holding what you want.
//
// So: hosts live in subnets, and subnets reach each other only across explicit
// Links, each of which demands a foothold you must already have earned.

Subnet :: struct {
	name:      string, // "DMZ", "CORP", "OT"
	base:      Addr,
	mask_bits: u8,
	hosts:     [dynamic]Handle(Host),
	scanned:   bool,
}

subnet_contains :: proc(s: ^Subnet, a: Addr) -> bool {
	if s.mask_bits == 0 {
		return true
	}
	mask := u32(0xffffffff) << (32 - u32(s.mask_bits))
	return (u32(a) & mask) == (u32(s.base) & mask)
}

// A route from one segment to another, traversable only from a host you hold
// at `min_access` or better. This is the pivot: a jump box in the DMZ with a
// second interface into CORP.
Link :: struct {
	from:       Handle(Subnet),
	to:         Handle(Subnet),
	via:        Handle(Host), // the host that straddles both segments
	min_access: Access,
	known:      bool, // player has discovered the route exists
}

// Whether the player can currently send traffic into `target`.
//
// True if they hold a host inside it, or hold the `via` host of a link leading
// into it at sufficient access. Deliberately a query over current state rather
// than a cached flag -- losing access to a jump box should immediately cut off
// everything behind it, with no invalidation logic to forget.
subnet_reachable :: proc(w: ^World, target: Handle(Subnet)) -> bool {
	sn, ok := pool_get(&w.subnets, target)
	if !ok {
		return false
	}

	for h in sn.hosts {
		host, host_ok := pool_get(&w.hosts, h)
		if host_ok && host.access > .None {
			return true
		}
	}

	for link in w.links {
		if link.to != target {
			continue
		}
		via, via_ok := pool_get(&w.hosts, link.via)
		if via_ok && via.access >= link.min_access {
			return true
		}
	}

	return false
}

// Links out of segments the player currently holds -- i.e. the pivots available
// right now.
links_from_held :: proc(w: ^World, out: ^[dynamic]Link) {
	clear(out)
	for link in w.links {
		via, ok := pool_get(&w.hosts, link.via)
		if ok && via.access >= link.min_access {
			append(out, link)
		}
	}
}

host_by_address :: proc(w: ^World, a: Addr) -> (Handle(Host), bool) {
	it: int
	for host, h in pool_iter(&w.hosts, &it) {
		if host.address == a {
			return h, true
		}
	}
	return {}, false
}
