package sim

// The sim/render seam.
//
// The sim never calls into the UI and holds no callbacks. It appends facts to a
// ring buffer; the frontend drains that ring once per frame and decides what to
// draw. Three things fall out of this:
//
//   - The dependency graph stays acyclic (Odin enforces that anyway, but this
//     keeps it honest rather than accidental).
//   - Tests assert on an event *sequence*, which is a far better description of
//     "what happened" than poking at final state.
//   - Later, async job output interleaving into the terminal is already solved:
//     jobs emit events like everything else.

// Semantic, not visual. The sim says what a line *means*; the frontend decides
// what that looks like, which is what lets themes reskin everything at once.
Log_Level :: enum u8 {
	Plain, // ordinary tool output
	Info,  // system notice, background detail
	Cmd,   // a command the operator issued, echoed back
	Good,  // something worked
	Warn,  // getting noisy
	Bad,   // something failed, or you were noticed
}

Ev_Log :: struct {
	text:  string,
	level: Log_Level,
}

Ev_Host_Discovered :: struct {
	host: Handle(Host),
}

Ev_Service_Discovered :: struct {
	host:  Handle(Host),
	index: int, // into host.services
}

Ev_Access_Gained :: struct {
	host:  Handle(Host),
	level: Access,
}

Event :: union {
	Ev_Log,
	Ev_Host_Discovered,
	Ev_Service_Discovered,
	Ev_Access_Gained,
}

EVENT_RING_CAP :: 1024

// Single-producer/single-consumer, and deliberately lossy: if the frontend
// stalls, the sim must not block or grow unboundedly. Oldest events are dropped
// and counted, so loss is visible rather than silent.
Event_Ring :: struct {
	buf:     [EVENT_RING_CAP]Event,
	head:    u64, // total ever pushed
	tail:    u64, // total ever drained
	dropped: u64,
}

ring_push :: proc(r: ^Event_Ring, e: Event) {
	r.buf[r.head % EVENT_RING_CAP] = e
	r.head += 1
	if r.head - r.tail > EVENT_RING_CAP {
		r.tail = r.head - EVENT_RING_CAP
		r.dropped += 1
	}
}

ring_pop :: proc(r: ^Event_Ring) -> (Event, bool) {
	if r.tail >= r.head {
		return nil, false
	}
	e := r.buf[r.tail % EVENT_RING_CAP]
	r.tail += 1
	return e, true
}

ring_pending :: proc(r: ^Event_Ring) -> int {
	return int(r.head - r.tail)
}

ring_clear :: proc(r: ^Event_Ring) {
	r.head = 0
	r.tail = 0
	r.dropped = 0
}
