package sim

// Digests: determinism made checkable.
//
// FNV-1a, 64-bit, hand-rolled for exactly the reason PCG32 is. A digest
// committed to the repository -- in a golden test, or in a replay file someone
// mailed you -- has to mean the same thing in five years. A hash taken from a
// library is free to change representation between releases, and the failure
// would look like a determinism regression rather than like a dependency
// upgrade.
//
// This lives in `sim` rather than in the test suite because it is now load
// bearing at runtime: a replay carries marks, and a mark is a pair of digests.
// It is pure -- arithmetic over bytes -- so it sits inside the purity gate
// alongside everything else the simulation is made of.
//
// Two digests, deliberately kept apart:
//
//   world_digest   what is true: hosts, access, credentials, trace, the clock.
//   Event_Ring.digest   what was said: every line and every fact, in push order.
//
// Either can move without the other. A world that reaches the same state by a
// different route has the same world digest and a different event digest, and
// that difference is a real divergence -- so a mark carries both.

FNV_OFFSET :: 0xcbf29ce484222325
FNV_PRIME :: 0x100000001b3

Digest :: struct {
	h: u64,
}

digest_init :: proc() -> Digest {
	return Digest{h = FNV_OFFSET}
}

digest_bytes :: proc(d: ^Digest, data: []byte) {
	for b in data {
		d.h ~= u64(b)
		d.h *= FNV_PRIME
	}
}

digest_str :: proc(d: ^Digest, s: string) {
	digest_bytes(d, transmute([]byte)s)
	digest_bytes(d, {0}) // separator, so "ab"+"c" and "a"+"bc" differ
}

digest_u64 :: proc(d: ^Digest, v: u64) {
	buf: [8]byte
	x := v
	for i in 0 ..< 8 {
		buf[i] = byte(x & 0xff)
		x >>= 8
	}
	digest_bytes(d, buf[:])
}

digest_i64 :: proc(d: ^Digest, v: i64) {
	digest_u64(d, u64(v))
}

// --- the world --------------------------------------------------------------

// Everything observable about a world, in a fixed order.
//
// Iteration is by pool slot throughout, which is the same order the simulation
// itself uses -- a digest that walked a map would hash differently run to run
// and prove nothing.
//
// The byte sequence produced here is pinned by the golden literals in
// tests/golden_test.odin. Adding a field changes all three, and that is the
// system working: it means something newly observable is now covered.
digest_world :: proc(w: ^World, d: ^Digest) {
	digest_u64(d, w.seed)
	digest_u64(d, u64(w.now))
	digest_u64(d, w.rng.state)
	digest_u64(d, w.rng.inc)
	digest_u64(d, u64(w.tag_counter))

	digest_i64(d, i64(w.trace.level))
	digest_i64(d, w.trace.accum)
	digest_u64(d, u64(transmute(u8)w.trace.responses))
	digest_u64(d, u64(w.run.state))
	digest_u64(d, u64(w.run.ended_at))

	it: int
	for sn in pool_iter(&w.subnets, &it) {
		digest_str(d, sn.name)
		digest_u64(d, u64(sn.monitoring))
		digest_i64(d, i64(sn.suspicion))
		digest_u64(d, u64(sn.hot_ticks))
		digest_u64(d, sn.alarmed ? 1 : 0)
	}

	ith: int
	for host in pool_iter(&w.hosts, &ith) {
		digest_str(d, host.hostname)
		digest_u64(d, u64(host.address))
		digest_u64(d, u64(host.access))
		digest_u64(d, u64(host.access_at))
		digest_u64(d, host.discovered ? 1 : 0)
		for svc in host.services {
			digest_u64(d, u64(svc.port))
			digest_u64(d, svc.discovered ? 1 : 0)
		}
		for f in host.files {
			digest_str(d, f.path)
			digest_u64(d, f.found ? 1 : 0)
		}
		for a in host.accounts {
			digest_str(d, a.username)
			digest_str(d, a.password) // the 50% response rewrites these
		}
	}

	for c in w.keyring {
		digest_str(d, c.username)
		digest_str(d, c.password)
	}

	// The noise log carries what was charged and by which command.
	for i in 0 ..< w.noise_log.count {
		r, ok := noise_log_at(w, i)
		if !ok {
			continue
		}
		digest_u64(d, u64(r.at))
		digest_i64(d, i64(r.applied))
		digest_str(d, r.source)
	}
}

// The world alone, as one number. What a replay mark carries.
world_digest :: proc(w: ^World) -> u64 {
	d := digest_init()
	digest_world(w, &d)
	return d.h
}

// --- events -----------------------------------------------------------------

// One event, folded into a running digest.
//
// The leading discriminant is written by hand rather than taken from the union's
// tag, because the union's tag is an ordering decision in event.odin and a
// digest must not change when someone reorders a type list. The exhaustive
// switch means a new event variant is a compile error here, which is the right
// place to be asked what it contributes to a replay's identity.
digest_event :: proc(d: ^Digest, e: Event) {
	switch ev in e {
	case Ev_Log:
		digest_u64(d, 1)
		digest_str(d, ev.text)
		digest_u64(d, u64(ev.level))
		digest_u64(d, u64(ev.job))
	case Ev_Host_Discovered:
		digest_u64(d, 2)
		digest_u64(d, u64(ev.host.idx))
		digest_u64(d, u64(ev.host.gen))
	case Ev_Service_Discovered:
		digest_u64(d, 3)
		digest_u64(d, u64(ev.host.idx))
		digest_u64(d, u64(ev.host.gen))
		digest_i64(d, i64(ev.index))
	case Ev_Access_Gained:
		digest_u64(d, 4)
		digest_u64(d, u64(ev.host.idx))
		digest_u64(d, u64(ev.host.gen))
		digest_u64(d, u64(ev.level))
	case Ev_Cred_Obtained:
		digest_u64(d, 5)
		digest_i64(d, i64(ev.index))
	case Ev_Noise:
		digest_u64(d, 6)
		digest_u64(d, u64(ev.subnet.idx))
		digest_i64(d, i64(ev.units))
		digest_i64(d, i64(ev.applied))
		digest_i64(d, i64(ev.total))
	case Ev_Trace_Alarm:
		digest_u64(d, 7)
		digest_u64(d, u64(ev.subnet.idx))
		digest_u64(d, ev.on ? 1 : 0)
	case Ev_Trace_Stage:
		digest_u64(d, 8)
		digest_u64(d, u64(ev.stage))
	case Ev_Access_Lost:
		digest_u64(d, 9)
		digest_u64(d, u64(ev.host.idx))
		digest_u64(d, u64(ev.was))
	case Ev_Run_Ended:
		digest_u64(d, 10)
		digest_u64(d, u64(ev.state))
		digest_u64(d, u64(ev.at))
	case:
		digest_u64(d, 0) // a nil Event; still hashed, so it cannot hide
	}
}
