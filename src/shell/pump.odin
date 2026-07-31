package shell

import "../campaign"
import "../sim"

// The frame loop's inner loop.
//
// This lives here rather than in main for one reason: it is the definition of
// what a tick *is* for the game as a whole, and there are now three callers --
// the real frame loop, the headless replay driver, and the tests. Three copies
// of a loop whose whole job is to be reproducible would be three chances for one
// of them to be reproducible differently.
//
// THE STOPPING RULE IS THE POINT.
//
// `play` and `retry` are builtins, so they run inside a dispatch and can only
// record their intent -- performing the transition frees the arena the session's
// strings live in. Main performs it between frames. Before this loop existed,
// the accumulator went right on ticking the world in between: one extra tick at
// 60fps, about two at 30, and up to fifteen after a stall long enough to hit the
// clamp. Each of those ticks ran suspicion_tick and trace_tick and fired any
// timer that came due, against a world that was already condemned.
//
// That is exactly the frame quantisation the determinism guarantee forbids, and
// it was live in a comment-documented "everything that decides a tick runs
// inside the loop" frame loop. The fix is one line -- stop the instant a
// transition is pending -- and it is here so that it cannot be fixed in one
// caller and not the others.

// The longest single frame the accumulator will honour, in seconds.
//
// Without a clamp, one long stall -- a breakpoint, a dragged window -- queues
// thousands of ticks, which take longer to simulate than the stall did, which
// queues more: the spiral of death.
MAX_FRAME_DT :: 0.25

Pump :: struct {
	accumulator: f64,

	// Set by the frame just run, and read by the caller before the next one.
	completed:  bool, // the level's last required objective fell this frame
	recorded:   bool, // ...and Progress had not already recorded it
	transition: bool, // a level change is pending; ticking stopped for it
	ticks:      int,  // how many ticks the frame actually ran
}

// Something to do at the end of every tick, at the point in the loop where a
// dispatch decision belongs: after the world has advanced and after completion
// has been noticed, so a feeder can see both.
//
// A proc pointer with a user pointer rather than a closure, because Odin has no
// capturing closures and because the alternative -- a union of every kind of
// feeder there might be -- would put main's `--exec` and the replay driver's
// entry list into this file for no gain.
Tick_Hook :: struct {
	fn:   proc(user: rawptr, s: ^Session),
	user: rawptr,
}

// Advances a session by however many whole ticks `dt` seconds buys.
//
// Everything inside the loop is a decision about a particular tick. Running any
// of it once per frame instead would make the tick it landed on depend on the
// frame rate, which is the one thing the simulation promises it does not.
pump_frame :: proc(p: ^Pump, s: ^Session, dt: f64, hook := Tick_Hook{}) {
	p.completed, p.recorded, p.transition, p.ticks = false, false, false, 0

	// A transition already pending at the top of a frame means the caller has not
	// performed it yet. Ticking anyway would be the same bug from the other end.
	if _, waiting := s.pending_transition.?; waiting {
		p.transition = true
		p.accumulator = 0
		return
	}

	p.accumulator += min(dt, MAX_FRAME_DT)
	for p.accumulator >= sim.TICK_DT {
		p.accumulator -= sim.TICK_DT
		pump_tick(p, s, hook)
		p.ticks += 1

		if p.transition {
			// The rest of the budget was accrued against the world that is about
			// to be replaced. Carrying it over would spend it on a level the
			// player has not seen a frame of yet.
			p.accumulator = 0
			return
		}
	}
}

// Exactly one tick, and everything that belongs to one.
pump_tick :: proc(p: ^Pump, s: ^Session, hook := Tick_Hook{}) {
	w := s.world

	sim.tick(w)
	session_update(s)
	journal_tick(s)

	// Completion is detected here, inside the tick loop, because whether a level
	// is finished at tick T must not depend on where the frame boundary fell --
	// and because anything deciding what to do next (a feeder, a player typing
	// `play`) has to see it immediately.
	//
	// Held until everything has settled: the last objective often falls part-way
	// through a tool's output, and a debrief landing mid-scan reads as though the
	// game interrupted itself.
	settled := !session_active(s) && len(w.timers) == 0
	if settled && !s.level_done && s.level != nil && campaign.level_complete(w, s.level) {
		s.level_done = true
		p.completed = true
		if s.progress != nil {
			p.recorded = campaign.mark_complete(s.progress, s.level.id)
		}
	}

	if hook.fn != nil {
		hook.fn(hook.user, s)
	}

	if _, changing := s.pending_transition.?; changing {
		p.transition = true
	}
}
