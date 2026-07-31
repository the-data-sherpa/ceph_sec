package shell

import "core:strings"
import "../replay"
import "../sim"

// Recording a session as it happens.
//
// A journal is the write side of the replay format: what the player did, at the
// tick they did it, plus periodic marks. The marks are what make this different
// from `--exec` and from every other "script of commands" idea. A script says
// what to run. A journal also says what was true afterwards, so playing it back
// either reproduces the run or names the tick it stopped reproducing it.
//
// Marks are emitted from inside the tick loop, in session_update's position --
// after the world has advanced and after jobs have retired -- because that is
// the one point in a frame where "the state at tick N" is unambiguous. Emitting
// them per frame would sample at whatever rate the display happens to run at,
// which is precisely the frame quantisation the determinism guarantee forbids,
// and would make a replay recorded at 144Hz unverifiable at 60.
//
// Everything here is allocated from the journal's own allocator, never from the
// run arena. A level transition frees that arena, and a recording spans
// transitions.

// Five seconds. Frequent enough that a divergence is located to within a few
// hundred ticks, rare enough that an hour-long recording is a few hundred lines.
MARK_INTERVAL_DEFAULT :: sim.Tick(300)

Journal :: struct {
	rep:       replay.Replay,
	segment:   int, // index into rep.segments; -1 before the first level starts
	mark_every: sim.Tick,
	next_mark: sim.Tick,
	enabled:   bool,
}

journal_init :: proc(
	j: ^Journal,
	game: string,
	catalogue: u64,
	progress: []string,
	mark_every := MARK_INTERVAL_DEFAULT,
	allocator := context.allocator,
) {
	replay.init(&j.rep, allocator)
	replay.set_game(&j.rep, game)
	j.rep.catalogue = catalogue
	for id in progress {
		replay.add_progress(&j.rep, id)
	}
	j.segment = -1
	j.mark_every = mark_every if mark_every > 0 else MARK_INTERVAL_DEFAULT
	j.next_mark = j.mark_every
	j.enabled = true
}

journal_destroy :: proc(j: ^Journal) {
	replay.destroy(&j.rep)
	j^ = {}
}

// Opens a segment. Called by level_start, so every route into a level -- boot,
// `play`, `retry` -- produces exactly one, and the segment boundary is the same
// event as the world clock resetting to zero.
journal_open_segment :: proc(j: ^Journal, level_id: string, seed: u64) {
	if j == nil || !j.enabled {
		return
	}
	if len(j.rep.segments) >= replay.MAX_SEGMENTS {
		// A recording that has outgrown the format stops recording rather than
		// growing without bound or writing a file that cannot be read back.
		j.enabled = false
		return
	}
	replay.add_segment(&j.rep, level_id, seed)
	j.segment = len(j.rep.segments) - 1
	j.next_mark = j.mark_every
}

@(private)
journal_append :: proc(j: ^Journal, e: replay.Entry) {
	if j == nil || !j.enabled || j.segment < 0 {
		return
	}
	if replay.entry_count(&j.rep) >= replay.MAX_ENTRIES {
		j.enabled = false
		return
	}
	entry := e
	if entry.kind == .Cmd {
		if !replay.text_representable(entry.text) {
			// Unwritable text means an unreplayable recording, and a recording
			// that quietly drops a command is worse than one that stops. Nothing
			// the line editor produces can reach here -- it accepts printable
			// runes only -- so this is the belt to session_submit_text's braces.
			j.enabled = false
			return
		}
		entry.text = clone_text(j, entry.text)
	}
	append(&j.rep.segments[j.segment].entries, entry)
}

@(private)
clone_text :: proc(j: ^Journal, s: string) -> string {
	return strings.clone(s, j.rep.allocator)
}

// Records something the player did. A no-op when not recording, which is why
// every call site can be unconditional.
journal_record :: proc(s: ^Session, kind: replay.Kind, text: string) {
	if s.journal == nil {
		return
	}
	journal_append(s.journal, replay.Entry{tick = s.world.now, kind = kind, text = text})
}

// One tick's worth of marking. Called from the tick loop, after the world has
// advanced and jobs have retired.
journal_tick :: proc(s: ^Session) {
	j := s.journal
	if j == nil || !j.enabled || j.segment < 0 {
		return
	}
	if s.world.now < j.next_mark {
		return
	}
	journal_mark(s)
	// Advanced from the threshold rather than from now, so a mark is emitted on
	// the same tick regardless of how the caller batched its ticks.
	for j.next_mark <= s.world.now {
		j.next_mark += j.mark_every
	}
}

// Marks the current tick unconditionally. Used at the end of a segment, so the
// last thing a level did is always checked even if it fell between intervals.
journal_mark :: proc(s: ^Session) {
	j := s.journal
	if j == nil || !j.enabled || j.segment < 0 {
		return
	}
	e := replay.Entry {
		tick   = s.world.now,
		kind   = .Mark,
		events = sim.events_digest(s.world),
		world  = sim.world_digest(s.world),
	}

	// A closing mark can land on a tick the interval already marked -- a level
	// that ends on a multiple of five seconds, say. Two identical lines verify
	// exactly as well as one and read like a bug in the recorder, so drop it.
	entries := j.rep.segments[j.segment].entries
	if len(entries) > 0 {
		last := entries[len(entries) - 1]
		if last.kind == .Mark && last.tick == e.tick && last.events == e.events && last.world == e.world {
			return
		}
	}
	journal_append(j, e)
}

// The recording so far, ready to be formatted and written by whoever owns a
// filesystem. Never a copy: the caller reads it and does not keep it.
journal_replay :: proc(j: ^Journal) -> ^replay.Replay {
	return &j.rep
}

// False once a recording has hit a limit and stopped taking entries. The file it
// produces is still valid and still verifies -- it is simply short, and whoever
// asked for it deserves to be told rather than to find out by replaying a
// session that ends in the middle.
journal_ok :: proc(j: ^Journal) -> bool {
	return j.enabled
}
