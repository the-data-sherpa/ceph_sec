package shell

import "core:fmt"
import "../campaign"
import "../sim"

// Starting a level, and the one place it may happen.
//
// This used to live in main, which meant the headless replay driver would have
// needed its own copy -- and two procedures that both claim to start a level are
// two chances to start it slightly differently. A replay that transitioned into
// a level built in a subtly different order would diverge on the first mark
// after the transition, and the cause would be here rather than anywhere near
// the digest that reported it.
//
// The order below is not stylistic. sim.world_reset frees the arena the
// session's own strings live in, so nothing holding an arena pointer may survive
// across it un-rebound; ui.Term holds string references into it too, which is
// why main still clears the terminal itself before calling this.
//
// Doing this from inside a shell command would free the session mid-dispatch,
// which is why commands only record the intent in pending_transition and the
// frame loop carries it out between frames.
level_start :: proc(
	s: ^Session,
	w: ^sim.World,
	progress: ^campaign.Progress,
	level: ^campaign.Level,
	seed: u64,
) {
	sim.world_reset(w, seed)

	origin := level.build(w)
	session_init(s, w, origin, "operator")

	s.level = level
	s.progress = progress
	s.tools = level.tools
	s.slots = level.slots if level.slots > 0 else SLOTS_DEFAULT
	if progress != nil {
		progress.current = level.id
	}

	// Trace is per-level: the early levels teach one idea at a time, and a
	// beginner meeting a rising detection meter in level one learns neither.
	// Disabling it means leaving every segment unwatched, which is the same
	// mechanism as the player's own VPS being free.
	if !level.trace {
		it: int
		for sn in sim.pool_iter(&w.subnets, &it) {
			sn.monitoring = .None
		}
	}

	// Opened before the brief, so the segment covers every event of the level
	// including the words it opens with -- which a replay must reproduce, since
	// they are in the event digest like everything else.
	journal_open_segment(s.journal, level.id, seed)

	level_brief(w, level)
}

// The level's opening words.
//
// Logged into the world rather than pushed at the terminal, so they are part of
// the run's event stream: a replay reproduces them, a mark covers them, and a
// transcript read back from events is complete.
level_brief :: proc(w: ^sim.World, level: ^campaign.Level) {
	sim.log_line(w, fmt.aprintf("LEVEL %d  --  %s", level.number, level.title, allocator = w.allocator), .Heading)

	for tech in level.techniques {
		sim.log_line(w, fmt.aprintf("ATT&CK  %s  %s", tech.id, tech.name, allocator = w.allocator), .Info)
	}
	if len(level.techniques) > 0 {
		sim.log_line(
			w,
			fmt.aprintf("tactic  %s", campaign.tactic_name(level.techniques[0].tactic), allocator = w.allocator),
			.Info,
		)
	}

	sim.log_line(w, "", .Plain)
	for line in level.brief {
		sim.log_line(w, line, .Plain)
	}
	sim.log_line(w, "", .Plain)
	sim.log_line(w, "`objectives` to see your goals, `help` for what you can run.", .Info)
	sim.log_line(w, "", .Plain)
}
