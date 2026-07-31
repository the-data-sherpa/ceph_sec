package tests

import "core:testing"
import sim "../src/sim"

// --- generational handles ---------------------------------------------------

@(test)
test_pool_add_get :: proc(t: ^testing.T) {
	p: sim.Pool(int)
	sim.pool_init(&p)
	defer sim.pool_destroy(&p)

	a := sim.pool_add(&p, 10)
	b := sim.pool_add(&p, 20)

	va, ok_a := sim.pool_get(&p, a)
	testing.expect(t, ok_a, "handle a should resolve")
	testing.expect_value(t, va^, 10)

	vb, ok_b := sim.pool_get(&p, b)
	testing.expect(t, ok_b, "handle b should resolve")
	testing.expect_value(t, vb^, 20)

	testing.expect_value(t, sim.pool_len(&p), 2)
}

@(test)
test_zero_handle_is_never_valid :: proc(t: ^testing.T) {
	p: sim.Pool(int)
	sim.pool_init(&p)
	defer sim.pool_destroy(&p)
	sim.pool_add(&p, 99) // occupies index 0

	// A zero-valued handle is what an uninitialised struct field holds. It must
	// mean "nothing", not "the first thing in the pool".
	zero: sim.Handle(int)
	_, ok := sim.pool_get(&p, zero)
	testing.expect(t, !ok, "zero handle must not resolve to slot 0")
}

// The core safety property: a handle to a removed object must never resolve to
// whatever later occupies its slot.
@(test)
test_stale_handle_after_slot_reuse :: proc(t: ^testing.T) {
	p: sim.Pool(int)
	sim.pool_init(&p)
	defer sim.pool_destroy(&p)

	old := sim.pool_add(&p, 111)
	testing.expect(t, sim.pool_remove(&p, old), "remove should succeed")

	// Forces reuse of the slot `old` pointed at.
	fresh := sim.pool_add(&p, 222)
	testing.expect_value(t, old.idx, fresh.idx)

	_, ok := sim.pool_get(&p, old)
	testing.expect(t, !ok, "stale handle resolved to the slot's new tenant")

	v, ok_fresh := sim.pool_get(&p, fresh)
	testing.expect(t, ok_fresh, "fresh handle should resolve")
	testing.expect_value(t, v^, 222)
}

@(test)
test_double_remove_is_rejected :: proc(t: ^testing.T) {
	p: sim.Pool(int)
	sim.pool_init(&p)
	defer sim.pool_destroy(&p)
	h := sim.pool_add(&p, 5)

	testing.expect(t, sim.pool_remove(&p, h), "first remove succeeds")
	testing.expect(t, !sim.pool_remove(&p, h), "second remove must be rejected")
	testing.expect_value(t, sim.pool_len(&p), 0)
}

// Handles must survive the reallocation caused by growth past capacity -- the
// entire reason handles exist instead of pointers.
@(test)
test_handles_survive_growth :: proc(t: ^testing.T) {
	p: sim.Pool(int)
	sim.pool_init(&p, 2)
	defer sim.pool_destroy(&p)

	handles: [dynamic]sim.Handle(int)
	defer delete(handles)
	for i in 0 ..< 500 {
		append(&handles, sim.pool_add(&p, i))
	}

	for h, i in handles {
		v, ok := sim.pool_get(&p, h)
		testing.expectf(t, ok, "handle %d invalid after growth", i)
		if ok {
			testing.expect_value(t, v^, i)
		}
	}
}

@(test)
test_pool_iter_skips_removed :: proc(t: ^testing.T) {
	p: sim.Pool(int)
	sim.pool_init(&p)
	defer sim.pool_destroy(&p)

	h0 := sim.pool_add(&p, 0)
	sim.pool_add(&p, 1)
	h2 := sim.pool_add(&p, 2)
	sim.pool_remove(&p, h0)
	sim.pool_remove(&p, h2)

	seen := 0
	sum := 0
	it: int
	for v in sim.pool_iter(&p, &it) {
		seen += 1
		sum += v^
	}
	testing.expect_value(t, seen, 1)
	testing.expect_value(t, sum, 1)
}

// --- PCG32 ------------------------------------------------------------------

// Validated against the reference PCG32 implementation's own demo vector
// (state 42, stream 54), so this checks we match upstream PCG -- not merely
// that we match ourselves.
//
// If this fails, every previously shared seed now generates a different run,
// which is exactly the silent breakage that motivated hand-rolling the PRNG.
// Treat a failure here as a breaking change, never as a test to update.
@(test)
test_pcg32_matches_reference_vector :: proc(t: ^testing.T) {
	r := sim.rng_seed(42, 54)
	got: [6]u32
	for i in 0 ..< 6 {
		got[i] = sim.rng_u32(&r)
	}

	expect := [6]u32{0xa15c02b7, 0x7b47f409, 0xba1d3330, 0x83d2f293, 0xbfa4784b, 0xcbed606e}
	testing.expect_value(t, got, expect)
}

@(test)
test_rng_same_seed_same_stream :: proc(t: ^testing.T) {
	a := sim.rng_seed(1234)
	b := sim.rng_seed(1234)
	for _ in 0 ..< 128 {
		testing.expect_value(t, sim.rng_u32(&a), sim.rng_u32(&b))
	}
}

@(test)
test_rng_different_seeds_diverge :: proc(t: ^testing.T) {
	a := sim.rng_seed(1)
	b := sim.rng_seed(2)
	same := 0
	for _ in 0 ..< 64 {
		if sim.rng_u32(&a) == sim.rng_u32(&b) {
			same += 1
		}
	}
	testing.expect(t, same == 0, "distinct seeds produced identical streams")
}

@(test)
test_rng_below_respects_bound :: proc(t: ^testing.T) {
	r := sim.rng_seed(7)
	for _ in 0 ..< 5000 {
		v := sim.rng_below(&r, 10)
		testing.expect(t, v < 10, "rng_below exceeded its bound")
	}
	testing.expect_value(t, sim.rng_below(&r, 0), u32(0))
}

// Every outcome must be reachable -- a bounded generator that silently never
// returns its endpoints would quietly bias generation.
@(test)
test_rng_range_covers_endpoints :: proc(t: ^testing.T) {
	r := sim.rng_seed(99)
	hit_lo, hit_hi := false, false
	for _ in 0 ..< 2000 {
		v := sim.rng_range(&r, 3, 8)
		testing.expect(t, v >= 3 && v <= 8, "rng_range escaped its interval")
		if v == 3 {
			hit_lo = true
		}
		if v == 8 {
			hit_hi = true
		}
	}
	testing.expect(t, hit_lo && hit_hi, "rng_range never produced an endpoint")
}

@(test)
test_rng_f32_in_unit_interval :: proc(t: ^testing.T) {
	r := sim.rng_seed(5)
	for _ in 0 ..< 5000 {
		v := sim.rng_f32(&r)
		testing.expect(t, v >= 0 && v < 1, "rng_f32 left [0,1)")
	}
}

@(test)
test_rng_shuffle_is_a_permutation :: proc(t: ^testing.T) {
	r := sim.rng_seed(2024)
	items: [32]int
	for i in 0 ..< 32 {
		items[i] = i
	}
	sim.rng_shuffle(&r, items[:])

	seen: [32]bool
	for v in items {
		testing.expect(t, !seen[v], "shuffle duplicated an element")
		seen[v] = true
	}
}

// --- event ring -------------------------------------------------------------

// The event digest must cover WHEN, not only what and in what order.
//
// This is what a replay mark compares, and almost everything that can silently
// go wrong in this simulation is a function of elapsed ticks -- trace accrual,
// decay, the grace window, hunt escalation. A digest blind to timing would let
// the whole regression corpus pass through a retiming bug while reporting that
// the run reproduced exactly. It did: before the ring carried `now`, these two
// sequences hashed identically.
@(test)
test_the_event_digest_covers_timing :: proc(t: ^testing.T) {
	digest_at :: proc(ticks: [2]sim.Tick) -> u64 {
		r: sim.Event_Ring
		sim.ring_clear(&r)
		r.now = ticks[0]
		sim.ring_push(&r, sim.Ev_Log{text = "one"})
		r.now = ticks[1]
		sim.ring_push(&r, sim.Ev_Log{text = "two"})
		return r.digest
	}

	early := digest_at({10, 20})
	late := digest_at({100, 500})
	testing.expectf(
		t,
		early != late,
		"the same lines at different ticks hashed the same (0x%x) -- the digest is blind to pacing",
		early,
	)

	// And it is still a pure function of the run: same timing, same digest.
	testing.expect_value(t, digest_at({10, 20}), early)
}

@(test)
test_ring_fifo :: proc(t: ^testing.T) {
	r: sim.Event_Ring
	sim.ring_push(&r, sim.Ev_Log{text = "one"})
	sim.ring_push(&r, sim.Ev_Log{text = "two"})
	testing.expect_value(t, sim.ring_pending(&r), 2)

	e0, ok0 := sim.ring_pop(&r)
	testing.expect(t, ok0)
	log0 := e0.(sim.Ev_Log)
	testing.expect_value(t, log0.text, "one")

	e1, _ := sim.ring_pop(&r)
	log1 := e1.(sim.Ev_Log)
	testing.expect_value(t, log1.text, "two")

	_, ok2 := sim.ring_pop(&r)
	testing.expect(t, !ok2, "empty ring should report empty")
}

// Overflow must drop the oldest events and say so, never tear or wrap into
// garbage. A stalled frontend must not be able to corrupt the sim.
@(test)
test_ring_overflow_drops_oldest :: proc(t: ^testing.T) {
	r: sim.Event_Ring
	total := sim.EVENT_RING_CAP + 50
	for i in 0 ..< total {
		sim.ring_push(&r, sim.Ev_Service_Discovered{index = i})
	}

	testing.expect_value(t, sim.ring_pending(&r), sim.EVENT_RING_CAP)
	testing.expect_value(t, r.dropped, u64(50))

	// The surviving window must be the newest CAP events, in order.
	expect := total - sim.EVENT_RING_CAP
	for {
		e, ok := sim.ring_pop(&r)
		if !ok {
			break
		}
		ev := e.(sim.Ev_Service_Discovered)
		testing.expect_value(t, ev.index, expect)
		expect += 1
	}
	testing.expect_value(t, expect, total)
}

// --- clock ------------------------------------------------------------------

@(test)
test_tick_conversions :: proc(t: ^testing.T) {
	testing.expect_value(t, sim.seconds(1), sim.Tick(60))
	testing.expect_value(t, sim.seconds(0.5), sim.Tick(30))
	testing.expect_value(t, sim.minutes(2), sim.Tick(7200))
	testing.expect_value(t, sim.seconds(-1), sim.Tick(0))
	testing.expect_value(t, sim.tick_seconds(sim.Tick(120)), 2.0)
}

// --- addresses --------------------------------------------------------------

@(test)
test_addr_roundtrip :: proc(t: ^testing.T) {
	a := sim.addr(10, 0, 4, 19)
	buf: [15]u8
	testing.expect_value(t, sim.addr_write(buf[:], a), "10.0.4.19")

	testing.expect_value(t, sim.addr_octet(a, 0), u8(10))
	testing.expect_value(t, sim.addr_octet(a, 3), u8(19))

	// Exercises the 1-, 2- and 3-digit paths in the formatter.
	testing.expect_value(t, sim.addr_write(buf[:], sim.addr(255, 100, 9, 0)), "255.100.9.0")
}

@(test)
test_subnet_membership :: proc(t: ^testing.T) {
	sn := sim.Subnet {
		base      = sim.addr(10, 0, 4, 0),
		mask_bits = 24,
	}
	testing.expect(t, sim.subnet_contains(&sn, sim.addr(10, 0, 4, 200)))
	testing.expect(t, !sim.subnet_contains(&sn, sim.addr(10, 0, 5, 1)))
}

// --- world ------------------------------------------------------------------

@(test)
test_world_scheduling_order :: proc(t: ^testing.T) {
	w: sim.World
	sim.world_init(&w, 1)
	defer sim.world_destroy(&w)

	sim.log_at(&w, sim.seconds(2), "second")
	sim.log_at(&w, sim.seconds(1), "first")
	// Same tick as "second": must fire after it, since it was scheduled later.
	sim.log_at(&w, sim.seconds(2), "third")

	sim.tick_n(&w, 59)
	testing.expect_value(t, sim.ring_pending(&w.events), 0)

	sim.tick(&w) // t = 60
	testing.expect_value(t, sim.ring_pending(&w.events), 1)

	sim.tick_n(&w, 60) // t = 120
	testing.expect_value(t, sim.ring_pending(&w.events), 3)

	order := [3]string{"first", "second", "third"}
	for want in order {
		e, ok := sim.ring_pop(&w.events)
		testing.expect(t, ok)
		got := e.(sim.Ev_Log)
		testing.expect_value(t, got.text, want)
	}
}

// Timers carry actions, not events, so a scheduled change must not be visible
// in world state before its tick arrives.
//
// Regression test: an earlier version scheduled raw events, which forced the
// caller to pre-apply the state change at schedule time. The result was a UI
// that reported hosts as discovered and segments as reachable seconds before
// the terminal said so.
@(test)
test_scheduled_action_does_not_apply_early :: proc(t: ^testing.T) {
	w: sim.World
	sim.world_init(&w, 1)
	defer sim.world_destroy(&w)

	dmz := sim.add_subnet(&w, "DMZ", sim.addr(10, 0, 4, 0), 24)
	corp := sim.add_subnet(&w, "CORP", sim.addr(10, 0, 9, 0), 24)

	// A foothold in the DMZ, so the segment is reachable. Discovery requires
	// reachability -- results can only land for a host you can actually touch --
	// so without this nothing in the DMZ would ever be discoverable.
	foot := sim.add_host(&w, "foothold", sim.addr(10, 0, 4, 2), dmz)
	sim.grant_access(&w, foot, .Root)

	jump := sim.add_host(&w, "jump01", sim.addr(10, 0, 4, 19), dmz)
	sim.add_service(&w, jump, sim.Service{port = 22, name = "ssh"})
	append(&w.links, sim.Link{from = dmz, to = corp, via = jump, min_access = .Root})

	sim.schedule(&w, sim.seconds(3), sim.Act_Discover_Host{host = jump})
	sim.schedule(&w, sim.seconds(3), sim.Act_Discover_Service{host = jump, index = 0})
	sim.schedule(&w, sim.seconds(5), sim.Act_Grant_Access{host = jump, level = .Root})

	host, _ := sim.pool_get(&w.hosts, jump)

	sim.tick_n(&w, 60) // t = 1s: nothing has fired
	testing.expect(t, !host.discovered, "host discovered before its tick")
	testing.expect(t, !host.services[0].discovered, "service discovered before its tick")
	testing.expect_value(t, host.access, sim.Access.None)
	testing.expect(t, !sim.subnet_reachable(&w, corp), "CORP reachable before the pivot fired")
	testing.expect_value(t, sim.ring_pending(&w.events), 1) // the foothold grant

	sim.tick_n(&w, 120) // t = 3s: discovery lands, access has not
	testing.expect(t, host.discovered, "host should be discovered at its tick")
	testing.expect(t, host.services[0].discovered)
	testing.expect_value(t, host.access, sim.Access.None)
	testing.expect(t, !sim.subnet_reachable(&w, corp), "CORP opened early")

	sim.tick_n(&w, 120) // t = 5s: the pivot lands
	testing.expect_value(t, host.access, sim.Access.Root)
	testing.expect(t, sim.subnet_reachable(&w, corp), "CORP should open once jump01 is root")

	// Three actions, three events, and every one of them backed by a real
	// change to the world -- plus the foothold grant from setup.
	testing.expect_value(t, sim.ring_pending(&w.events), 4)
}

// --- tick re-entrancy -------------------------------------------------------

// tick lifts every due timer out before applying any of them, so an action is
// free to mutate the timer list mid-batch. Applying in place while scanning
// positionally -- which is what this did through M1 -- would step over timers
// due in the same tick once a removal shifted the list under the cursor.
//
// end_run is the action that makes this observable: it clears w.timers.
@(test)
test_action_clearing_timers_does_not_disturb_the_batch :: proc(t: ^testing.T) {
	w: sim.World
	sim.world_init(&w, 1)
	defer sim.world_destroy(&w)

	// All due on the same tick. The middle one ends the run, which clears the
	// pending list; the batch it belongs to must still be delivered in order,
	// minus whatever end_run explicitly cancels.
	sim.log_at(&w, sim.seconds(1), "before")
	sim.schedule(&w, sim.seconds(1), sim.Act_End_Run{state = .Quit})
	sim.log_at(&w, sim.seconds(1), "after")

	// Plus a later timer, which end_run must drop.
	sim.log_at(&w, sim.seconds(5), "never")

	sim.tick_n(&w, 60)

	testing.expect_value(t, w.run.state, sim.Run_State.Quit)
	testing.expect_value(t, len(w.timers), 0)

	// "before" fired; "after" was lifted in the same batch but stamped
	// cancelled by end_run; "never" was still pending and was dropped.
	saw_before, saw_after, saw_never, saw_ended := false, false, false, false
	for {
		e, ok := sim.ring_pop(&w.events)
		if !ok {
			break
		}
		#partial switch ev in e {
		case sim.Ev_Log:
			switch ev.text {
			case "before":
				saw_before = true
			case "after":
				saw_after = true
			case "never":
				saw_never = true
			}
		case sim.Ev_Run_Ended:
			saw_ended = true
		}
	}
	testing.expect(t, saw_before, "timer before the end should have fired")
	testing.expect(t, saw_ended, "run end should be announced")
	testing.expect(t, !saw_after, "same-tick timer after end_run should be cancelled")
	testing.expect(t, !saw_never, "later timer should have been dropped")
}

@(test)
test_end_run_is_idempotent :: proc(t: ^testing.T) {
	w: sim.World
	sim.world_init(&w, 1)
	defer sim.world_destroy(&w)

	sim.end_run(&w, .Extracted)
	first := w.run.ended_at
	sim.tick_n(&w, 60)
	sim.end_run(&w, .Caught) // must not overwrite how the run ended

	testing.expect_value(t, w.run.state, sim.Run_State.Extracted)
	testing.expect_value(t, w.run.ended_at, first)
	testing.expect(t, sim.run_over(&w))

	// Exactly one Ev_Run_Ended.
	ends := 0
	for {
		e, ok := sim.ring_pop(&w.events)
		if !ok {
			break
		}
		if _, is_end := e.(sim.Ev_Run_Ended); is_end {
			ends += 1
		}
	}
	testing.expect_value(t, ends, 1)
}

@(test)
test_run_state_resets :: proc(t: ^testing.T) {
	w: sim.World
	sim.world_init(&w, 1)
	defer sim.world_destroy(&w)

	sim.end_run(&w, .Caught)
	sim.world_reset(&w, 2)

	testing.expect_value(t, w.run.state, sim.Run_State.Running)
	testing.expect_value(t, w.run.ended_at, sim.Tick(0))
	testing.expect(t, !sim.run_over(&w))
	testing.expect_value(t, len(w.due), 0)
}

@(test)
test_discovery_is_idempotent :: proc(t: ^testing.T) {
	w: sim.World
	sim.world_init(&w, 1)
	defer sim.world_destroy(&w)

	sn := sim.add_subnet(&w, "DMZ", sim.addr(10, 0, 4, 0), 24)
	// Discovery requires the segment to be reachable, so hold something in it.
	foot := sim.add_host(&w, "foothold", sim.addr(10, 0, 4, 2), sn)
	sim.grant_access(&w, foot, .Root)

	h := sim.add_host(&w, "gw-edge", sim.addr(10, 0, 4, 1), sn, "Linux")
	sim.add_service(&w, h, sim.Service{port = 22, name = "ssh", product = "OpenSSH", version = "7.4"})

	sim.discover_host(&w, h)
	sim.discover_host(&w, h)
	sim.discover_service(&w, h, 0)
	sim.discover_service(&w, h, 0)
	sim.discover_service(&w, h, 99) // out of range, must be ignored

	// Two discoveries, plus the Ev_Access_Gained from establishing the foothold.
	testing.expect_value(t, sim.ring_pending(&w.events), 3)
}

@(test)
test_access_only_ratchets_up :: proc(t: ^testing.T) {
	w: sim.World
	sim.world_init(&w, 1)
	defer sim.world_destroy(&w)

	sn := sim.add_subnet(&w, "DMZ", sim.addr(10, 0, 4, 0), 24)
	h := sim.add_host(&w, "gw-edge", sim.addr(10, 0, 4, 1), sn)

	sim.grant_access(&w, h, .User)
	sim.grant_access(&w, h, .Root)
	sim.grant_access(&w, h, .User) // must not downgrade or emit

	host, _ := sim.pool_get(&w.hosts, h)
	testing.expect_value(t, host.access, sim.Access.Root)
	testing.expect_value(t, sim.ring_pending(&w.events), 2)
}

// Segmentation: an unheld segment is unreachable until you own the jump box
// that bridges into it, and it becomes unreachable again the moment you don't.
@(test)
test_pivot_gates_reachability :: proc(t: ^testing.T) {
	w: sim.World
	sim.world_init(&w, 1)
	defer sim.world_destroy(&w)

	dmz := sim.add_subnet(&w, "DMZ", sim.addr(10, 0, 4, 0), 24)
	corp := sim.add_subnet(&w, "CORP", sim.addr(10, 0, 9, 0), 24)

	jump := sim.add_host(&w, "jump01", sim.addr(10, 0, 4, 5), dmz)
	sim.add_host(&w, "fs01", sim.addr(10, 0, 9, 10), corp)

	append(&w.links, sim.Link{from = dmz, to = corp, via = jump, min_access = .Root})

	testing.expect(t, !sim.subnet_reachable(&w, corp), "CORP reachable with no foothold")

	sim.grant_access(&w, jump, .User)
	testing.expect(t, !sim.subnet_reachable(&w, corp), "user access should not satisfy a root pivot")

	sim.grant_access(&w, jump, .Root)
	testing.expect(t, sim.subnet_reachable(&w, corp), "root on the jump box should open CORP")

	// Holding a host inside a segment is reachability on its own.
	testing.expect(t, sim.subnet_reachable(&w, dmz))
}

@(test)
test_world_reset_clears_run :: proc(t: ^testing.T) {
	w: sim.World
	sim.world_init(&w, 1)
	defer sim.world_destroy(&w)

	sn := sim.add_subnet(&w, "DMZ", sim.addr(10, 0, 4, 0), 24)
	sim.add_host(&w, "gw-edge", sim.addr(10, 0, 4, 1), sn)
	sim.log_line(&w, "noise")
	sim.tick_n(&w, 120)

	sim.world_reset(&w, 2)

	testing.expect_value(t, sim.pool_len(&w.hosts), 0)
	testing.expect_value(t, sim.pool_len(&w.subnets), 0)
	testing.expect_value(t, len(w.links), 0)
	testing.expect_value(t, len(w.timers), 0)
	testing.expect_value(t, sim.ring_pending(&w.events), 0)
	testing.expect_value(t, w.now, sim.Tick(0))
	testing.expect_value(t, w.seed, u64(2))
}

// The headline guarantee: same seed, same ticks, same run. If this ever fails,
// seeds are not shareable and replays are not replays.
@(test)
test_same_seed_produces_identical_runs :: proc(t: ^testing.T) {
	build :: proc(w: ^sim.World) {
		sn := sim.add_subnet(w, "DMZ", sim.addr(10, 0, 4, 0), 24)
		for i in 0 ..< 8 {
			// Draw from the world RNG so any divergence in the generator shows up
			// as divergence in the world.
			octet := u8(sim.rng_range(&w.rng, 2, 250))
			h := sim.add_host(w, "host", sim.addr(10, 0, 4, octet), sn)
			sim.log_at(w, sim.seconds(f64(sim.rng_range(&w.rng, 1, 5))), "scan", .Info)
			if sim.rng_chance(&w.rng, 0.5) {
				sim.grant_access(w, h, .User)
			}
		}
	}

	a, b: sim.World
	sim.world_init(&a, 0xCEF5EC)
	sim.world_init(&b, 0xCEF5EC)
	defer sim.world_destroy(&a)
	defer sim.world_destroy(&b)

	build(&a)
	build(&b)
	sim.tick_n(&a, 600)
	sim.tick_n(&b, 600)

	testing.expect_value(t, sim.ring_pending(&a.events), sim.ring_pending(&b.events))
	testing.expect(t, sim.ring_pending(&a.events) > 0, "test built no events to compare")

	n := 0
	for {
		ea, ok_a := sim.ring_pop(&a.events)
		eb, ok_b := sim.ring_pop(&b.events)
		if !ok_a || !ok_b {
			testing.expect_value(t, ok_a, ok_b)
			break
		}
		// Compares the union tag and every payload field, addresses included.
		testing.expectf(t, ea == eb, "event %d diverged: %v vs %v", n, ea, eb)
		n += 1
	}

	testing.expect_value(t, a.now, b.now)
	testing.expect_value(t, a.rng, b.rng)
}
