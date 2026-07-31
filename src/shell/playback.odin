package shell

import "../campaign"
import "../replay"
import "../sim"

// Playing a replay back, headlessly.
//
// This is the read side of the format, and it is what turns determinism from a
// claim into something a machine checks. It drives the real shell against a real
// world through the real tick loop -- pump_tick, the same procedure the frame
// loop calls -- and at every mark compares the two digests the recording
// carried. The first difference stops it, with the tick and which digest moved.
//
// It lives in `shell` because it needs exactly what shell already has: sim to
// tick, campaign to resolve a level id, and the session itself to submit lines
// into. Putting it in main would have put it out of reach of the tests, which
// are the whole reason for it.
//
// The same procedure records. In Record mode the entries are a script -- what to
// type and when -- and the marks come out rather than going in, which is how the
// committed corpus under tests/replays is generated: by the code that verifies
// it, so a corpus file can never describe a run the player cannot reproduce.

Playback_Mode :: enum u8 {
	Verify, // check every mark in the replay
	Record, // play the entries and write what happened into a Journal
}

Divergence :: enum u8 {
	None,
	Unknown_Level,      // a level id in the replay is not in this catalogue
	Level_Mismatch,     // the transition went somewhere the replay did not
	Missing_Transition, // a segment ended without the level change it implies
	Entries_Unplayed,   // a transition left entries behind; nothing may be skipped
	Events_Digest,      // what was said diverged
	World_Digest,       // what is true diverged
	Ran_Too_Long,       // a guard against a file that describes an endless run
	Not_Recording,      // Record mode without a journal to record into
}

divergence_text :: proc(d: Divergence) -> string {
	switch d {
	case .None:
		return "ok"
	case .Unknown_Level:
		return "this build has no such level"
	case .Level_Mismatch:
		return "the level change went somewhere the replay did not"
	case .Missing_Transition:
		return "the segment ended without the level change it implies"
	case .Entries_Unplayed:
		return "a level change left entries unplayed"
	case .Events_Digest:
		return "the event digest differs -- the run said something else"
	case .World_Digest:
		return "the world digest differs -- the run reached a different state"
	case .Ran_Too_Long:
		return "the replay did not finish within its tick budget"
	case .Not_Recording:
		return "record mode needs a journal"
	}
	return "?"
}

// One hour of simulated time per segment. Not a tuning knob -- a guard, so a
// file describing a run that never ends cannot make this process never end.
MAX_SEGMENT_TICKS :: 60 * 60 * 60

// How long Record mode waits for a level to go quiet before taking its closing
// mark. Twenty seconds is longer than any tool takes; a run still busy after
// that is one whose tail is not worth recording.
RECORD_TAIL_TICKS :: 1200

Playback :: struct {
	mode:    Playback_Mode,
	journal: ^Journal, // Record mode: where the observed run is written

	// Results.
	ok:              bool,
	why:             Divergence,
	segment:         int,       // which segment it stopped in
	level:           string,    // and which level that was
	tick:            sim.Tick,  // and when
	want, got:       u64,       // the digests, when why is one of the two
	marks_checked:   int,
	segments_played: int,
	entries_played:  int,
}

// Plays `rep` against a freshly-initialised world.
//
// The caller owns the world, the session and the progress -- the world because
// it owns an arena, the progress so the caller can inspect what the run
// unlocked. Progress must be initialised and empty: this fills it from the
// replay, because what is unlocked changes what commands do.
replay_run :: proc(
	w: ^sim.World,
	sess: ^Session,
	progress: ^campaign.Progress,
	rep: ^replay.Replay,
	pb: ^Playback,
) {
	pb.ok = false
	pb.why = .None

	if pb.mode == .Record && pb.journal == nil {
		pb.why = .Not_Recording
		return
	}
	sess.journal = pb.journal

	// The progress the recording started from. Ids are resolved against this
	// build's catalogue rather than trusted: an id that no longer exists means
	// the replay is from a different campaign, and playing it anyway would
	// silently change what is unlocked.
	for id in rep.progress {
		if _, exists := campaign.level_by_id(id); !exists {
			pb.why, pb.level = .Unknown_Level, id
			return
		}
		campaign.mark_complete(progress, id)
	}

	for seg_index in 0 ..< len(rep.segments) {
		seg := &rep.segments[seg_index]
		pb.segment, pb.level = seg_index, seg.level

		level, found := campaign.level_by_id(seg.level)
		if !found {
			pb.why = .Unknown_Level
			return
		}

		// The first segment is entered directly; every later one is entered by
		// the transition the previous segment's last command asked for, and was
		// already checked against this segment's level id down below.
		if seg_index == 0 {
			level_start(sess, w, progress, level, seg.seed)
		}

		ctx := Playback_Ctx {
			pb  = pb,
			seg = seg,
		}
		hook := Tick_Hook {
			fn   = playback_hook,
			user = &ctx,
		}

		// Entries recorded before the first tick of the segment. A player can
		// type into the prompt during the frame that opened the level, and the
		// tick loop has not run yet when they do.
		playback_due(&ctx, sess)
		if pb.why != .None {
			pb.tick = w.now
			return
		}

		p: Pump
		ticks := 0
		for {
			if _, changing := sess.pending_transition.?; changing {
				break
			}
			if ctx.index >= len(seg.entries) {
				break
			}
			pump_tick(&p, sess, hook)
			if pb.why != .None {
				pb.tick = w.now
				return
			}
			ticks += 1
			if ticks > MAX_SEGMENT_TICKS {
				pb.why, pb.tick = .Ran_Too_Long, w.now
				return
			}
		}

		// Record mode lets the level settle and marks it, so the last thing that
		// happened is covered even though nothing scheduled a mark there.
		if pb.mode == .Record {
			for _ in 0 ..< RECORD_TAIL_TICKS {
				if _, changing := sess.pending_transition.?; changing {
					break
				}
				if !session_active(sess) && len(w.timers) == 0 {
					break
				}
				pump_tick(&p, sess, hook)
				if pb.why != .None {
					pb.tick = w.now
					return
				}
			}
			journal_mark(sess)
		}

		pb.segments_played += 1

		last := seg_index == len(rep.segments) - 1
		t, changing := sess.pending_transition.?

		if changing {
			// Nothing may be skipped. A transition with entries left behind means
			// the file describes something this cannot do, and playing the part it
			// can would report success for a replay that was never finished.
			if ctx.index < len(seg.entries) {
				pb.why, pb.tick = .Entries_Unplayed, w.now
				return
			}
			if last {
				// A trailing transition with nowhere to go. Harmless: the recording
				// simply stopped at the moment the player asked for another level.
				break
			}

			next := &rep.segments[seg_index + 1]
			if t.level != next.level {
				pb.why, pb.tick = .Level_Mismatch, w.now
				pb.level = t.level
				return
			}
			target, ok := campaign.level_by_id(t.level)
			if !ok {
				pb.why, pb.tick, pb.level = .Unknown_Level, w.now, t.level
				return
			}
			sess.pending_transition = nil
			level_start(sess, w, progress, target, next.seed)
			continue
		}

		if !last {
			pb.why, pb.tick = .Missing_Transition, w.now
			return
		}
	}

	pb.ok = pb.why == .None
}

// --- the hook ---------------------------------------------------------------

@(private)
Playback_Ctx :: struct {
	pb:    ^Playback,
	seg:   ^replay.Segment,
	index: int,
}

// Called at the end of every tick, in the same position main's `--exec` feeder
// occupies: after the world has advanced and after completion has been noticed.
//
// That position is what makes a recorded tick and a played tick the same tick. A
// command typed during input polling lands after the frame's last tick, which is
// the tick the recorder stamps it with -- and this is the point in that tick
// after which nothing else happens.
@(private)
playback_hook :: proc(user: rawptr, s: ^Session) {
	ctx := (^Playback_Ctx)(user)
	playback_due(ctx, s)
}

// Applies every entry stamped with the current tick, in file order.
//
// File order matters and is not an implementation detail: a mark recorded before
// a command on the same tick describes the state before that command ran, and
// applying them in the other order would compare the right digest at the wrong
// moment.
@(private)
playback_due :: proc(ctx: ^Playback_Ctx, s: ^Session) {
	pb := ctx.pb
	for ctx.index < len(ctx.seg.entries) {
		e := ctx.seg.entries[ctx.index]
		if e.tick != s.world.now {
			return
		}

		// A command has already asked for a level change. The mark the recorder
		// takes on its way out still belongs to this world and is still checked;
		// another command does not, because the frame loop performs the transition
		// before it polls for input again and therefore could never have recorded
		// one. Leaving it unconsumed is what makes the segment loop report it,
		// rather than running it against a world that is already condemned.
		if _, changing := s.pending_transition.?; changing && e.kind != .Mark {
			return
		}

		ctx.index += 1
		pb.entries_played += 1

		switch e.kind {
		case .Cmd:
			session_submit_text(s, e.text)

		case .Intr:
			session_interrupt(s)

		case .Mark:
			if pb.mode != .Verify {
				continue // Record mode writes its own marks; the script's are ignored
			}
			if got := sim.events_digest(s.world); got != e.events {
				pb.why, pb.want, pb.got = .Events_Digest, e.events, got
				return
			}
			if got := sim.world_digest(s.world); got != e.world {
				pb.why, pb.want, pb.got = .World_Digest, e.world, got
				return
			}
			// Counted after both checks, so on a failure the count is the number
			// of marks that *matched* -- which is what locates the divergence.
			pb.marks_checked += 1
		}

		if pb.why != .None {
			return
		}
	}
}
