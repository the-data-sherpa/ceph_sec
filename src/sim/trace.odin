package sim

import "core:fmt"
import "core:strings"

// Suspicion and trace: the cost of being loud.
//
// Two coupled numbers, and the coupling is the design.
//
// **Suspicion** is per-segment. It rises with the noise of actions taken inside
// that segment, scaled by how closely the segment is watched, and decays while
// you are quiet. It is local, so being loud in the DMZ does not endanger you in
// CORP -- which is what makes "which segment am I standing in" a real question.
//
// **Trace** is global and only ever rises. It advances only while some segment
// sits above a visible alarm line. That gate is what makes being caught
// *attributable*: the trace cannot move while everything is below the line, so
// a lost run always traces back to a specific segment that sat visibly hot for
// a recorded length of time. It is a property of the mechanism, not a promise.
//
// Every quantity here is an integer in hundredths. No float touches this path,
// so "byte-identical world from the same seed" stays true by construction
// rather than true-in-practice-on-this-compiler.

// How closely a segment is watched. Per docs/design.md section 4, monitoring is
// inversely correlated with how interesting the segment is -- the easiest boxes
// to break are the least worth breaking, and the segment holding what you want
// is the one that notices you.
Monitoring :: enum u8 {
	None,    // your own VPS: nobody is watching, and it is genuinely free
	Low,     // DMZ -- internet-facing, patched unevenly, loud is survivable
	Medium,  // CORP -- workstations and file shares, where the credentials live
	High,    // OT / clinical -- flat, ancient, unpatchable, and watched
	Extreme, // MGMT -- jump boxes, hypervisors, backups
}

// Procedures rather than a package-level table, deliberately.
//
// A `:=` array at package scope is mutable global state that `world_reset` does
// not touch -- and this is the one package whose entire value proposition is
// reproducibility. These constant-fold to the same thing.
monitoring_gain :: proc(m: Monitoring) -> i32 {
	switch m {
	case .None:
		return 0
	case .Low:
		return 60
	case .Medium:
		return 100
	case .High:
		return 160
	case .Extreme:
		return 240
	}
	return 100
}

monitoring_next :: proc(m: Monitoring) -> Monitoring {
	if m >= .Extreme {
		return .Extreme
	}
	return Monitoring(u8(m) + 1)
}

monitoring_label :: proc(m: Monitoring) -> string {
	switch m {
	case .None:
		return "none"
	case .Low:
		return "low"
	case .Medium:
		return "medium"
	case .High:
		return "high"
	case .Extreme:
		return "extreme"
	}
	return "?"
}

// How close they are to attributing the intrusion. Only ever rises: there is no
// decrement anywhere in this package, which makes design.md's "once it moves it
// does not come back" a structural fact rather than a discipline to remember.
Trace :: struct {
	level: i32, // hundredths, 0 ..= TRACE_MAX
	// Sub-divisor remainder carried between ticks, so integer division loses
	// nothing and the total is independent of how ticks were batched.
	accum:     i64,
	responses: bit_set[Trace_Stage],
}

Trace_Stage :: enum u8 {
	Review,     // 25% -- they start reading logs
	Alert,      // 50% -- credentials rotate
	Hunt,       // 75% -- someone walks the network killing footholds
	Attributed, // 100% -- run over
}

TRACE_MAX :: i32(10_000) // 100.00
TRACE_REVIEW :: i32(2_500)
TRACE_ALERT :: i32(5_000)
TRACE_HUNT :: i32(7_500)

NOISE_SCALE :: i32(100) // one point of suspicion, in hundredths

SUSPICION_MAX :: i32(15_000) // 150.00
SUSPICION_ALARM :: i32(6_000) // 60.00 -- the line above which trace advances
SUSPICION_GRACE :: Tick(5 * TICK_HZ) // quiet time before decay starts
SUSPICION_DECAY :: i32(2) // hundredths per tick == 1.20/s

// Charges `units` of noise against the segment `sn`, scaled by its monitoring.
//
// A mutator in the same mould as grant_access and harvest_file: it changes the
// world and emits its own event, so the two cannot drift apart.
noise :: proc(w: ^World, sn: Handle(Subnet), units: int, source: string) {
	if units <= 0 || run_over(w) {
		return
	}
	subnet, ok := pool_get(&w.subnets, sn)
	if !ok {
		return
	}

	gain := monitoring_gain(subnet.monitoring)
	if gain == 0 {
		return // unwatched: genuinely free, not merely cheap
	}

	applied := i32(units) * NOISE_SCALE * gain / 100
	subnet.suspicion = min(subnet.suspicion + applied, SUSPICION_MAX)
	// Resets the grace window, so a steady drip never gets to decay.
	subnet.last_charge_at = w.now

	noise_log_push(
		w,
		Noise_Record {
			at = w.now,
			subnet = sn,
			units = i32(units),
			applied = applied,
			source = strings.clone(source, w.allocator),
		},
	)
	ring_push(&w.events, Ev_Noise{subnet = sn, units = i32(units), applied = applied, total = subnet.suspicion})
}

// Per-tick decay.
//
// Arithmetic inside tick(), never scheduled actions: a decay timer per segment
// per tick would turn the flat timer list into a per-tick sweep of thousands of
// entries, and the list is scanned linearly.
//
// Charges are applied during dispatch, which happens before the next tick(), so
// charge-then-decay ordering within a tick is well defined and tested.
suspicion_tick :: proc(w: ^World) {
	it: int
	for subnet in pool_iter(&w.subnets, &it) {
		if subnet.suspicion <= 0 {
			continue
		}
		if w.now - subnet.last_charge_at < SUSPICION_GRACE {
			continue
		}
		subnet.suspicion = max(subnet.suspicion - SUSPICION_DECAY, 0)
	}
}

// How fast excess suspicion converts into trace. Chosen so a segment pinned at
// 80.00 burns a run in under three minutes, while one hovering just over the
// line at 62.00 takes nearly half an hour: forgiving of one loud action,
// brutal about sustained noise.
TRACE_DIVISOR :: i64(2048)

// Advances suspicion into trace, once per tick.
//
// Trace rises only while some segment is above the alarm line, and that gate is
// the mechanism behind "being caught is always attributable": with everything
// below the line the trace provably cannot move, so a lost run always traces
// back to a segment that sat visibly hot for a recorded length of time.
trace_tick :: proc(w: ^World) {
	if run_over(w) {
		return
	}

	excess: i64 = 0
	it: int
	for subnet, h in pool_iter(&w.subnets, &it) {
		if subnet.suspicion > SUSPICION_ALARM {
			subnet.hot_ticks += 1
			excess += i64(subnet.suspicion - SUSPICION_ALARM)
			if !subnet.alarmed {
				subnet.alarmed = true
				ring_push(&w.events, Ev_Trace_Alarm{subnet = h, on = true})
			}
		} else if subnet.alarmed {
			subnet.alarmed = false
			ring_push(&w.events, Ev_Trace_Alarm{subnet = h, on = false})
		}
	}

	if excess <= 0 {
		return
	}

	// The remainder is carried rather than discarded, so integer division loses
	// nothing and the total is identical however the ticks were batched.
	w.trace.accum += excess
	gained := i32(w.trace.accum / TRACE_DIVISOR)
	w.trace.accum %= TRACE_DIVISOR
	if gained > 0 {
		trace_advance(w, gained)
	}
}

// The only writer of trace.level, and it only ever increases. There is no
// decrement anywhere in this package, which is what makes design.md's "once it
// moves it does not come back" structural rather than a rule to remember. When
// `shred` arrives it will lower suspicion and be incapable of touching this.
trace_advance :: proc(w: ^World, amount: i32) {
	if amount <= 0 || run_over(w) {
		return
	}
	w.trace.level = min(w.trace.level + amount, TRACE_MAX)
	trace_respond(w)
}

// Fires each escalation exactly once, in order. Latched in a bit_set so a jump
// straight from 0 to 100 in a single tick still fires all four, in sequence,
// rather than skipping to the last.
@(private)
trace_respond :: proc(w: ^World) {
	if w.trace.level >= TRACE_REVIEW && .Review not_in w.trace.responses {
		w.trace.responses += {.Review}
		ring_push(&w.events, Ev_Trace_Stage{stage = .Review})
		respond_review(w)
	}
	if w.trace.level >= TRACE_ALERT && .Alert not_in w.trace.responses {
		w.trace.responses += {.Alert}
		ring_push(&w.events, Ev_Trace_Stage{stage = .Alert})
		respond_alert(w)
	}
	if w.trace.level >= TRACE_HUNT && .Hunt not_in w.trace.responses {
		w.trace.responses += {.Hunt}
		ring_push(&w.events, Ev_Trace_Stage{stage = .Hunt})
		respond_hunt(w)
	}
	if w.trace.level >= TRACE_MAX && .Attributed not_in w.trace.responses {
		w.trace.responses += {.Attributed}
		ring_push(&w.events, Ev_Trace_Stage{stage = .Attributed})
		end_run(w, .Caught)
	}
}

// 25% -- log review. Every segment you have made noise in gets watched more
// closely, so everything you do from here costs more. A positive feedback loop:
// being in trouble compounds. Nothing is taken away yet.
@(private)
respond_review :: proc(w: ^World) {
	log_line(w, "[!] their SOC is reviewing logs -- monitoring raised", .Trace)
	it: int
	for subnet in pool_iter(&w.subnets, &it) {
		if subnet.suspicion > 0 && subnet.monitoring != .None {
			subnet.monitoring = monitoring_next(subnet.monitoring)
		}
	}
}

// 50% -- alert. They kick you off one box and change its password.
//
// Carefully *not* "rotate the credential you are relying on". In the shipped
// scenario one password is reused across every host and is the entire attack
// path; invalidating the keyring entry would make the objective permanently
// unreachable, silently, with no Stranded outcome to detect it -- the player
// would grind to 100% on a run that was already over.
//
// Rewriting passwords on a box you already hold cannot brick anything: the
// credential still opens everything you have not reached yet, and you route
// around the loss. It is also the better story -- they noticed you on that host
// specifically, and shut that door.
@(private)
respond_alert :: proc(w: ^World) {
	target, found := hottest_held_host(w)
	if !found {
		log_line(w, "[!] credentials are being rotated", .Trace)
		return
	}

	host, _ := pool_get(&w.hosts, target)
	log_line(w, fmt_line(w, "[!] alert raised -- session on %s killed, password rotated", host.hostname), .Trace)

	revoke_access(w, target, .None)
	// Derived from the tick, not the RNG: keeping the generator's stream
	// independent of how the player played means a seed still determines the
	// world, and no future replay feature needs an input log.
	for &acct in host.accounts {
		acct.password = fmt_line(w, "rotated-%d", u64(w.now))
	}
}

// 75% -- active hunt. Someone walks the network pulling your footholds one at a
// time, newest first, every HUNT_INTERVAL until the run ends.
HUNT_INTERVAL :: Tick(20 * TICK_HZ)

@(private)
respond_hunt :: proc(w: ^World) {
	log_line(w, "[!] incident response is walking the network", .Trace)
	if w.hunt_tag == 0 {
		w.hunt_tag = next_tag(w) // never 0: cancel_tag refuses to match that
	}
	schedule_tagged(w, HUNT_INTERVAL, Act_Hunt_Step{}, w.hunt_tag)
}

// One step of the hunt: take the most recently gained foothold, then queue the
// next step under the same tag so the whole hunt cancels as a unit.
hunt_step :: proc(w: ^World) {
	if run_over(w) {
		return
	}

	newest: Handle(Host)
	newest_at: Tick
	found := false

	it: int
	for host, h in pool_iter(&w.hosts, &it) {
		if h == w.origin || host.access == .None {
			continue // your own box is yours; they cannot reach it
		}
		if !found || host.access_at > newest_at {
			newest, newest_at, found = h, host.access_at, true
		}
	}

	if found {
		host, _ := pool_get(&w.hosts, newest)
		log_line(w, fmt_line(w, "[!] your session on %s was terminated", host.hostname), .Trace)
		revoke_access(w, newest, .None)
	}

	schedule_tagged(w, HUNT_INTERVAL, Act_Hunt_Step{}, w.hunt_tag)
}

// The segment with the most suspicion in which you actually hold something.
@(private)
hottest_held_host :: proc(w: ^World) -> (Handle(Host), bool) {
	best: Handle(Host)
	best_suspicion: i32 = -1
	found := false

	it: int
	for host, h in pool_iter(&w.hosts, &it) {
		if h == w.origin || host.access == .None {
			continue
		}
		subnet, ok := pool_get(&w.subnets, host.subnet)
		if !ok {
			continue
		}
		// Ties break by pool slot order, which is deterministic.
		if !found || subnet.suspicion > best_suspicion {
			best, best_suspicion, found = h, subnet.suspicion, true
		}
	}
	return best, found
}

@(private)
fmt_line :: proc(w: ^World, format: string, args: ..any) -> string {
	return fmt.aprintf(format, ..args, allocator = w.allocator)
}

// Which segment a host sits in -- the unit noise is charged against.
subnet_of :: proc(w: ^World, h: Handle(Host)) -> (Handle(Subnet), bool) {
	host, ok := pool_get(&w.hosts, h)
	if !ok {
		return {}, false
	}
	return host.subnet, true
}
