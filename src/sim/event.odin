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
	Plain,   // ordinary tool output
	Info,    // system notice, background detail
	Cmd,     // a command the operator issued, echoed back
	Trace,   // the defender noticing you, or acting on it
	Heading, // a finding worth the eye stopping on: a host, a section title
	Data,    // structured detail under a heading: ports, versions, fields
	Good,    // something worked
	Warn,    // getting noisy
	Bad,     // something failed, or you were noticed
}

Ev_Log :: struct {
	text:  string,
	level: Log_Level,

	// Which background job produced this line; 0 for foreground and for the
	// world's own output. Sim never interprets it -- it carries the value the
	// way Timer.tag already does -- but the frontend needs it to put a `[2] `
	// gutter in front of interleaved output.
	//
	// Stamped when the line is scheduled, not resolved when it is drained: a
	// job's last lines and its own completion notice are drained *after* the
	// job has been retired, so a drain-time lookup would lose the gutter on
	// exactly the lines that most need it.
	job: u16,
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

Ev_Cred_Obtained :: struct {
	index: int, // into World.keyring
}

Ev_Noise :: struct {
	subnet:  Handle(Subnet),
	units:   i32, // as charged by the tool
	applied: i32, // after monitoring scaling
	total:   i32, // the segment's suspicion afterwards
}

Ev_Trace_Alarm :: struct {
	subnet: Handle(Subnet),
	on:     bool,
}

Ev_Trace_Stage :: struct {
	stage: Trace_Stage,
}

Ev_Access_Lost :: struct {
	host: Handle(Host),
	was:  Access,
}

Ev_Run_Ended :: struct {
	state: Run_State,
	at:    Tick,
}

Event :: union {
	Ev_Log,
	Ev_Host_Discovered,
	Ev_Service_Discovered,
	Ev_Access_Gained,
	Ev_Cred_Obtained,
	Ev_Noise,
	Ev_Trace_Alarm,
	Ev_Trace_Stage,
	Ev_Access_Lost,
	Ev_Run_Ended,
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

	// A running digest of every event ever pushed, in push order.
	//
	// Folded on push rather than on drain, and that is the whole point. The ring
	// is deliberately lossy, and draining is a frame-timed concern -- a digest
	// accumulated by whoever happens to be reading would change if a frontend
	// stalled long enough to drop a line. Folded here it is a pure function of
	// what the simulation said, which is what a replay mark needs it to be.
	//
	// Zero on a bare Event_Ring rather than FNV_OFFSET; ring_clear seeds it, and
	// every World gets one through world_bind.
	digest: u64,
}

ring_push :: proc(r: ^Event_Ring, e: Event) {
	d := Digest{h = r.digest}
	digest_event(&d, e)
	r.digest = d.h

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
	r.digest = FNV_OFFSET
}

// The event digest as a replay mark carries it.
events_digest :: proc(w: ^World) -> u64 {
	return w.events.digest
}
