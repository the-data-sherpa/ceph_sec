package shell

import "core:fmt"
import "core:strconv"
import "core:strings"
import "../sim"

// Jobs.
//
// A job is one slow operation: something that takes sim time and streams output
// while it runs. Its identity is `tag` -- the same u32 the timer scheduler has
// grouped output under since M0 -- so killing one is a single cancel_tag call
// and nothing else. That promise was written into world.odin in M0; this is it
// being cashed.
//
// The table is a fixed array with a Free state and no compaction. Compacting
// while `fg` and `cur` refer to entries would be a use-after-free waiting to
// happen -- `kill %1` runs *inside* a dispatch whose cursor points at the kill
// command itself. Nothing is ever addressed by table index: the player says
// `%N`, which is `Job.id`, monotonic and never reused within a run.

JOBS_MAX :: 8 // table capacity; `slots` is the limit actually enforced
SLOTS_DEFAULT :: 2

Job_State :: enum u8 {
	Free,
	Running,
}

Job :: struct {
	id:         int, // %N as the player types it
	tag:        u32, // cancellation tag; nonzero from dispatch onward
	state:      Job_State,
	background: bool,
	label:      string, // "nmap"
	raw:        string, // the whole command line, for `jobs`
	started_at: sim.Tick,
	ends_at:    sim.Tick,

	// Captured at dispatch and never re-read from the Session. A scan launched
	// on web01 must not silently retarget when the prompt moves to jump01, and
	// it is what the orphan sweep checks when a foothold is taken away.
	host: sim.Handle(sim.Host),

	// Owned by the job rather than the session. With several jobs live there is
	// no quiescent moment for a single shared Maybe(Move) to land in, and a
	// killed job must take its deferred move to the grave with it.
	pending_move: Maybe(Move),
}

// Liveness is a pure function of world state, never a latched flag.
//
// This is the constraint the whole job model is built to satisfy. If the shell
// latched "running" and cleared it in session_update, then whether the prompt
// is free at tick T would depend on where the frame boundaries fell -- and that
// determines the tick at which the next command dispatches. The determinism
// guarantee would die silently, visible only as a screenshot that no longer
// reproduces.
job_live :: proc(s: ^Session, j: ^Job) -> bool {
	return j.state == .Running && s.world.now < j.ends_at
}

job_by_id :: proc(s: ^Session, id: int) -> (^Job, bool) {
	if id <= 0 {
		return nil, false
	}
	for &j in s.jobs {
		if j.state != .Free && j.id == id {
			return &j, true
		}
	}
	return nil, false
}

// Lowest free index, so allocation order is deterministic.
@(private)
job_alloc :: proc(s: ^Session) -> (^Job, bool) {
	for &j in s.jobs {
		if j.state == .Free {
			return &j, true
		}
	}
	return nil, false
}

job_free :: proc(s: ^Session, j: ^Job) {
	if s.fg == j.id {
		s.fg = 0
	}
	j^ = {}
}

// Cancels a job's pending work and frees its entry. The pending move dies with
// it: an interrupted ssh must not still land you on a host whose access grant
// was cancelled.
job_kill :: proc(s: ^Session, j: ^Job) -> int {
	cancelled := sim.cancel_tag(s.world, j.tag)
	j.pending_move = nil
	job_free(s, j)
	return cancelled
}

// Background jobs currently occupying a slot.
//
// A foreground command does not count. The alternative -- foreground consuming
// a slot -- means two background scans lock you out of every network tool,
// which is precisely the M1 behaviour backgrounding exists to remove.
slots_in_use :: proc(s: ^Session) -> int {
	n := 0
	for &j in s.jobs {
		if j.background && job_live(s, &j) {
			n += 1
		}
	}
	return n
}

// Any job at all, foreground or background, still running.
session_active :: proc(s: ^Session) -> bool {
	for &j in s.jobs {
		if job_live(s, &j) {
			return true
		}
	}
	return false
}

// The job holding the terminal, if one is.
foreground :: proc(s: ^Session) -> (^Job, bool) {
	return job_by_id(s, s.fg)
}

// What the foreground job is called, for the status line. Empty when idle.
foreground_label :: proc(s: ^Session) -> string {
	if j, ok := foreground(s); ok && job_live(s, j) {
		return j.label
	}
	return ""
}

// The job currently being dispatched into. Tools reach this through out_at and
// act_at rather than directly.
current :: proc(s: ^Session) -> (^Job, bool) {
	return job_by_id(s, s.cur)
}

// --- commands ---------------------------------------------------------------

cmd_jobs :: proc(s: ^Session, cmd: ^Command) {
	shown := 0
	// Ascending id, so the listing order is stable and matches what the player
	// launched rather than where the table happened to place things.
	for id in 1 ..= s.next_job_id {
		j, ok := job_by_id(s, id)
		if !ok || !job_live(s, j) {
			continue
		}
		shown += 1

		remaining := sim.tick_seconds(j.ends_at - s.world.now)
		marker := j.id == s.fg ? "+" : " "
		out(
			s,
			fmt.tprintf("[%d]%s %-6s %4.1fs left  %s", j.id, marker, j.label, remaining, j.raw),
			.Data,
		)
	}

	if shown == 0 {
		out(s, "no jobs running", .Info)
		return
	}
	out(s, fmt.tprintf("%d of %d slots in use", slots_in_use(s), s.slots), .Info)
}

// Parses `%2` or `2`. Bare `fg`/`kill` with no argument take the most recently
// launched live job, which is what makes the common case one word.
@(private)
job_argument :: proc(s: ^Session, cmd: ^Command) -> (^Job, bool) {
	arg, given := positional(cmd, 0)
	if !given {
		newest: ^Job
		for &j in s.jobs {
			if job_live(s, &j) && (newest == nil || j.id > newest.id) {
				newest = &j
			}
		}
		return newest, newest != nil
	}

	spec := arg
	if strings.has_prefix(spec, "%") {
		spec = spec[1:]
	}
	id, parsed := strconv.parse_int(spec)
	if !parsed {
		return nil, false
	}
	j, ok := job_by_id(s, id)
	if !ok || !job_live(s, j) {
		return nil, false
	}
	return j, true
}

cmd_fg :: proc(s: ^Session, cmd: ^Command) {
	j, ok := job_argument(s, cmd)
	if !ok {
		out(s, "fg: no such job", .Bad)
		return
	}
	if session_busy(s) && s.fg != j.id {
		out(s, fmt.tprintf("fg: %s already holds the terminal", foreground_label(s)), .Bad)
		return
	}
	j.background = false
	s.fg = j.id
	out(s, j.raw, .Cmd)
}

cmd_kill :: proc(s: ^Session, cmd: ^Command) {
	j, ok := job_argument(s, cmd)
	if !ok {
		out(s, "kill: no such job", .Bad)
		return
	}

	id, label := j.id, j.label
	cancelled := job_kill(s, j)
	out(s, fmt.tprintf("[%d]  terminated  %s (%d pending)", id, label, cancelled), .Warn)

	// Said once per run, the first time it could matter. Noise is charged when a
	// command is dispatched -- the packets left when you pressed Enter -- so
	// killing buys back time and a slot, never attention. Players will assume
	// otherwise unless told.
	if !s.hinted_kill {
		s.hinted_kill = true
		out(s, "note: noise was already charged -- killing saves time, not attention.", .Info)
	}
}

// Kills every live job. Used by `exit`.
jobs_kill_all :: proc(s: ^Session) {
	for &j in s.jobs {
		if j.state != .Free {
			job_kill(s, &j)
		}
	}
	s.fg = 0
}

@(private)
job_capture :: proc(s: ^Session, j: ^Job, raw: string, background: bool) {
	w := s.world
	j.state = .Running
	j.background = background
	j.id = s.next_job_id
	j.tag = sim.next_tag(w)
	j.started_at = w.now
	// Zero-length until begin_work. A tool that validates and bails never calls
	// it, which is how dispatch detects the early return and frees the entry.
	j.ends_at = w.now

	// Cloned into the run arena, not borrowed. The command line arrives from
	// session_submit on the temp allocator, which main.odin frees at the end of
	// every frame -- holding the slice would render freed memory in `jobs` one
	// frame later, and only in interactive play, since --exec strings are heap
	// allocated and would look fine in every test.
	j.raw = strings.clone(raw, w.allocator)
	j.host = s.host
	j.pending_move = nil
}
