package sim

import "core:strings"

// How a run ends.
//
// Owned by the world rather than the shell, for three reasons: it must survive
// `world_reset`, tests must be able to assert on it without reaching through a
// Session, and the frontend needs to draw a debrief for a run the shell no
// longer has any say over.
Run_State :: enum u8 {
	Running,
	Extracted, // the objective was recovered
	Caught,    // the trace reached 100%
	Quit,      // the operator walked away

	// `Stranded` -- "no path to the objective remains" -- is deliberately
	// absent. Deciding that correctly *is* M3's attack-graph prover, and a
	// heuristic would lie at the worst possible moment: telling a player their
	// run is over when it isn't, or letting them grind on one that is. Until
	// the prover exists, the defender responses are designed so that M2 cannot
	// manufacture the state (see trace.odin, the 50% response).
}

Run_Status :: struct {
	state:    Run_State,
	ended_at: Tick,
}

run_over :: proc(w: ^World) -> bool {
	return w.run.state != .Running
}

// --- the bill ---------------------------------------------------------------

// One charge of noise, kept so the end-of-run debrief can show the player what
// actually cost them rather than just telling them they lost. `source` is the
// command line responsible.
Noise_Record :: struct {
	at:      Tick,
	subnet:  Handle(Subnet),
	units:   i32,
	applied: i32, // after monitoring scaling
	source:  string,
}

NOISE_LOG_CAP :: 32

// Bounded and lossy: a long run makes hundreds of charges and only the recent
// and the large are worth showing. Oldest are dropped.
Noise_Log :: struct {
	buf:   [NOISE_LOG_CAP]Noise_Record,
	head:  int,
	count: int,
}

noise_log_push :: proc(w: ^World, r: Noise_Record) {
	l := &w.noise_log
	l.buf[l.head] = r
	l.head = (l.head + 1) % NOISE_LOG_CAP
	if l.count < NOISE_LOG_CAP {
		l.count += 1
	}
}

// Index 0 is the oldest retained charge.
noise_log_at :: proc(w: ^World, i: int) -> (Noise_Record, bool) {
	l := &w.noise_log
	if i < 0 || i >= l.count {
		return {}, false
	}
	idx := (l.head - l.count + i + 2 * NOISE_LOG_CAP) % NOISE_LOG_CAP
	return l.buf[idx], true
}

// Ends the run. Idempotent -- the first call wins, so a job completing on the
// same tick the trace lands cannot overwrite how the run ended.
//
// Clears both the pending timer list and the batch currently being applied, so
// nothing scheduled before the end can still fire afterwards. The shell sweeps
// its own job table on the next update.
end_run :: proc(w: ^World, state: Run_State) {
	if w.run.state != .Running || state == .Running {
		return
	}
	w.run.state = state
	w.run.ended_at = w.now

	cancel_tag(w, w.hunt_tag)
	clear(&w.timers)
	// Entries already lifted this tick are stamped rather than dropped: the
	// apply loop is iterating this exact slice.
	for &t in w.due {
		t.tag = TAG_CANCELLED
	}

	ring_push(&w.events, Ev_Run_Ended{state = state, at = w.now})
}
