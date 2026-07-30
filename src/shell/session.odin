package shell

import "core:fmt"
import "core:strings"
import "../input"
import "../sim"

// The shell's own state: where you are standing and what is running.
//
// This is not in `sim` because the world does not care which directory you are
// in, or which of your jobs is in the foreground. What the world *does* own is
// everything that survives moving between hosts -- access levels, the keyring,
// discovery, the trace. The split is: sim knows what is true, shell knows where
// you are looking from.

Session :: struct {
	world: ^sim.World,
	line:  Line,

	host: sim.Handle(sim.Host), // the box the prompt is on
	user: string,
	cwd:  string,

	jobs:        [JOBS_MAX]Job,
	slots:       int, // concurrent background jobs allowed
	next_job_id: int,
	fg:          int, // job id holding the terminal; 0 == none
	cur:         int, // job id being dispatched into; 0 == outside dispatch

	// Noise the current dispatch has decided it owes, drained into sim once the
	// tool returns. Filed as slips rather than charged directly so a tool can
	// touch the same segment from several branches without paying twice.
	charges:      [CHARGES_MAX]Charge,
	charge_count: int,

	hinted_kill: bool, // the one-shot "killing does not refund noise" note
}

Move :: struct {
	host: sim.Handle(sim.Host),
	user: string,
}

session_init :: proc(s: ^Session, w: ^sim.World, host: sim.Handle(sim.Host), user: string) {
	s.world = w
	s.host = host
	s.user = strings.clone(user, w.allocator)
	s.cwd = strings.clone(home_dir(user, w.allocator), w.allocator)
	s.slots = SLOTS_DEFAULT
	s.next_job_id = 0
	s.fg = 0
	s.cur = 0
	s.jobs = {}
	s.charge_count = 0
	s.hinted_kill = false
	line_init(&s.line, w.allocator)
}

home_dir :: proc(user: string, allocator := context.allocator) -> string {
	if user == "root" {
		return strings.clone("/root", allocator)
	}
	return fmt.aprintf("/home/%s", user, allocator = allocator)
}

// True while a foreground job holds the terminal. A pure function of world
// state -- see job_live.
session_busy :: proc(s: ^Session) -> bool {
	j, ok := foreground(s)
	return ok && job_live(s, j)
}

// Call once per tick, after the world has advanced.
//
// Performs only the *side effects* of a job retiring -- it never gates anything,
// because everything that gates reads job_live directly. That separation is what
// keeps dispatch decisions independent of frame boundaries.
session_update :: proc(s: ^Session) {
	sweep_orphaned_jobs(s)
	evict_from_lost_host(s)

	// Ascending id, so retirement order does not depend on table layout.
	for {
		next: ^Job
		for &j in s.jobs {
			if j.state == .Free || job_live(s, &j) {
				continue
			}
			if next == nil || j.id < next.id {
				next = &j
			}
		}
		if next == nil {
			break
		}

		if move, ok := next.pending_move.?; ok {
			session_move_to(s, move.host, move.user)
		}
		job_free(s, next)
	}
}

// Kills jobs whose foothold has been taken away.
//
// This is the emergent moment the 75% hunt exists to produce: your scan dies
// because they killed the box you were running it through. Sim already refuses
// to apply findings over a severed route, but the *job* has to be reaped here --
// sim does not know what a prompt or a job is.
@(private)
sweep_orphaned_jobs :: proc(s: ^Session) {
	for &j in s.jobs {
		if j.state == .Free || !job_live(s, &j) {
			continue
		}
		if j.host == s.world.origin {
			continue // your own box cannot be taken from you
		}
		host, ok := sim.pool_get(&s.world.hosts, j.host)
		if !ok || host.access != .None {
			continue
		}

		id, label, name := j.id, j.label, host.hostname
		job_kill(s, &j)
		sim.log_line(
			s.world,
			fmt.aprintf("[%d]  terminated  %s -- connection to %s lost", id, label, name, allocator = s.world.allocator),
			.Bad,
		)
	}
}

// Bounces the prompt home when the box under it is taken away.
//
// Without this, a hunted player keeps a shell on a host they no longer hold:
// `id` reports access=None on the machine they are apparently standing on, and
// `cat /srv/backup/manifest.sql` still wins the run. The headline defender
// response would be purely cosmetic in exactly the case it exists to punish.
@(private)
evict_from_lost_host :: proc(s: ^Session) {
	if s.host == s.world.origin {
		return
	}
	host, ok := sim.pool_get(&s.world.hosts, s.host)
	if !ok {
		return
	}
	if host.access != .None {
		return
	}

	buf: [15]u8
	sim.log_line(
		s.world,
		fmt.aprintf(
			"Connection to %s closed by remote host.",
			sim.addr_write(buf[:], host.address),
			allocator = s.world.allocator,
		),
		.Bad,
	)
	session_move_to(s, s.world.origin, "operator")
}

// `user@host:cwd$` -- and `#` when running as root, which is the one piece of
// prompt syntax every operator reads without thinking.
prompt :: proc(s: ^Session, allocator := context.allocator) -> string {
	host_name := "?"
	sigil := "$"
	if h, ok := sim.pool_get(&s.world.hosts, s.host); ok {
		host_name = h.hostname
		if s.user == "root" {
			sigil = "#"
		}
	}

	shown := s.cwd
	home := home_dir(s.user, context.temp_allocator)
	if s.cwd == home {
		shown = "~"
	}

	return fmt.aprintf("%s@%s:%s%s ", s.user, host_name, shown, sigil, allocator = allocator)
}

// --- input ------------------------------------------------------------------

// Feeds one input event to the shell. Returns true if a command was submitted.
//
// The line editor is always live, even while a foreground job holds the
// terminal. M1 dropped keystrokes while busy; that was the right call when the
// only thing you could do was wait, but the entire point of background jobs is
// that the prompt keeps working. A foreground tool is still refused at
// *dispatch*, with a message naming `&` -- which teaches the mechanic, where a
// swallowed keystroke taught nothing.
session_input :: proc(s: ^Session, ev: input.Event) -> bool {
	#partial switch e in ev {
	case input.Rune_Typed:
		line_insert(&s.line, e.ch)

	case input.Key_Pressed:
		if e.key == .Ctrl_C {
			session_interrupt(s)
			return false
		}
		if e.key == .Enter {
			session_submit(s)
			return true
		}
		line_apply_key(&s.line, e.key, s.world.allocator)
	}
	return false
}

// ^C targets the foreground job only, exactly as bash does. Background jobs die
// by `kill`.
session_interrupt :: proc(s: ^Session) {
	if j, ok := foreground(s); ok && job_live(s, j) {
		label := j.label
		cancelled := job_kill(s, j)
		sim.log_line(
			s.world,
			fmt.aprintf("^C  %s interrupted (%d pending)", label, cancelled, allocator = s.world.allocator),
			.Warn,
		)
		return
	}

	// Nothing in the foreground: ^C abandons the current line, like a real shell.
	sim.log_line(
		s.world,
		fmt.aprintf(
			"%s%s^C",
			prompt(s, context.temp_allocator),
			line_text(&s.line, context.temp_allocator),
			allocator = s.world.allocator,
		),
		.Cmd,
	)
	line_clear(&s.line)
}

session_submit :: proc(s: ^Session) {
	text := line_text(&s.line, context.temp_allocator)

	// Echo the command into the scrollback exactly as a terminal does, so the
	// transcript reads back as a session rather than as bare output.
	sim.log_line(
		s.world,
		fmt.aprintf("%s%s", prompt(s, context.temp_allocator), text, allocator = s.world.allocator),
		.Cmd,
	)

	line_history_push(&s.line, text, s.world.allocator)
	line_clear(&s.line)

	if len(strings.trim_space(text)) == 0 {
		return
	}
	session_exec(s, text)
}

// Runs a command line. Exposed separately from submit so tests and `--exec` can
// drive the shell without synthesising keystrokes.
session_exec :: proc(s: ^Session, text: string) {
	// The run is over, and M2 has no restart -- that needs Session teardown that
	// world_reset cannot currently do safely, and is M4's. Say so rather than
	// swallowing the command: session_submit has already echoed it, so silence
	// here looks like the terminal has hung.
	if sim.run_over(s.world) {
		out(s, "the run is over. press ESC to quit.", .Info)
		return
	}

	// A trailing `&` backgrounds the command.
	//
	// Stripped here rather than made a lexer metacharacter, because `&` is a
	// perfectly ordinary character inside a URL: a general token boundary would
	// silently cut `curl 'http://h/x?a=1&b=2'` into three positionals. The
	// trailing-strip handles `nmap x &` and `nmap x&` identically and cannot
	// break any existing quoting.
	line := strings.trim_space(text)
	background := false
	if strings.has_suffix(line, "&") {
		background = true
		line = strings.trim_space(line[:len(line) - 1])
	}
	text := line

	tokens, lex_err := lex(text, context.temp_allocator)
	switch lex_err {
	case .Unterminated_Quote:
		out(s, "shell: unterminated quote", .Bad)
		return
	case .Too_Many_Tokens:
		out(s, "shell: too many arguments", .Bad)
		return
	case .None:
	}

	if len(tokens) == 0 {
		return
	}

	spec, found := lookup(tokens[0])
	if !found {
		out(s, fmt.tprintf("%s: command not found", tokens[0]), .Bad)
		return
	}

	cmd, parse_err := parse(tokens, spec.value_flags, context.temp_allocator)
	switch parse_err {
	case .Missing_Flag_Value:
		out(s, fmt.tprintf("%s: option requires an argument", spec.name), .Bad)
		return
	case .Empty:
		return
	case .None:
	}
	cmd.raw = text

	// Builtins are instant: they happen on a box you already hold, take no
	// terminal and schedule nothing. Running them outside the job machinery is
	// what will make the live prompt useful rather than merely non-blocking.
	if !spec.job {
		if background {
			out(s, fmt.tprintf("%s: builtins are instant; nothing to background", spec.name), .Bad)
			return
		}
		// Builtins run unconditionally, including while jobs are live. They take
		// no terminal and schedule nothing. This is what makes the live prompt
		// useful rather than merely non-blocking.
		s.cur = 0
		s.charge_count = 0
		spec.run(s, &cmd)
		drain_charges(s, text)
		return
	}

	// Refusals name the way out. A swallowed keystroke teaches nothing; a line
	// saying "use &" teaches the mechanic once and for good.
	if background && !spec.backgroundable {
		out(s, fmt.tprintf("%s: cannot be backgrounded -- it moves the prompt", spec.name), .Bad)
		return
	}
	if !background && session_busy(s) {
		out(s, fmt.tprintf("%s: %s is running -- wait, ^C it, or launch with &", spec.name, foreground_label(s)), .Bad)
		return
	}
	if background && slots_in_use(s) >= s.slots {
		out(
			s,
			fmt.tprintf("%s: all %d job slots busy -- see `jobs`, free one with `kill`", spec.name, s.slots),
			.Bad,
		)
		return
	}

	j, allocated := job_alloc(s)
	if !allocated {
		out(s, "shell: too many jobs", .Bad)
		return
	}

	s.next_job_id += 1
	job_capture(s, j, text, background)
	j.label = strings.clone(spec.name, s.world.allocator)
	if !background {
		s.fg = j.id
	}
	s.cur = j.id
	s.charge_count = 0

	spec.run(s, &cmd)
	drain_charges(s, text)

	// A tool that validated and bailed -- bad CIDR, unresolvable host, malformed
	// user@host -- never reached begin_work, so it never claimed any time. Free
	// the entry immediately. Leaving it allocated would leak the slot, and the
	// failure would only become visible several commands later.
	if j.ends_at == j.started_at {
		job_free(s, j)
	} else if background {
		// No `[N]` in the text: these lines carry the job stamp, and the
		// frontend renders the gutter from that. Formatting it here too would
		// print it twice.
		out(s, j.raw, .Info)
		// Scheduled rather than printed by session_update, so the notice is
		// tick-exact regardless of frame batching, dies with the job if it is
		// killed, and lands after the tool's own last line because ends_at is
		// final by now.
		sim.schedule_tagged(
			s.world,
			j.ends_at - s.world.now,
			sim.Act_Log {
				text = fmt.aprintf("done  %s", j.label, allocator = s.world.allocator),
				level = .Info,
				job = u16(j.id),
			},
			j.tag,
		)
	}

	s.cur = 0
}

// --- output helpers ---------------------------------------------------------

// Which background job's gutter this dispatch's output should carry. Zero for
// foreground work and for builtins, which is what leaves every M1 transcript
// assertion untouched.
@(private)
gutter :: proc(s: ^Session) -> u16 {
	if j, ok := current(s); ok && j.background {
		return u16(j.id)
	}
	return 0
}

// Immediate output. Text is cloned into the run arena by sim.log_line, so
// temp-allocated formatting is safe to pass here.
out :: proc(s: ^Session, text: string, level: sim.Log_Level = .Plain) {
	sim.log_line_as(s.world, text, level, gutter(s))
}

// Output scheduled `delay` into the future under the running job's tag, so
// killing the job takes it back. This is how a tool streams results while time
// passes.
out_at :: proc(s: ^Session, delay: sim.Tick, text: string, level: sim.Log_Level = .Plain) {
	j, ok := current(s)
	if !ok {
		return // scheduled outside a dispatch; nothing owns it, so drop it
	}
	sim.schedule_tagged(
		s.world,
		delay,
		sim.Act_Log{text = strings.clone(text, s.world.allocator), level = level, job = gutter(s)},
		j.tag,
	)
}

// Schedules a state change under the running job's tag.
act_at :: proc(s: ^Session, delay: sim.Tick, a: sim.Action) {
	j, ok := current(s)
	if !ok {
		return
	}
	sim.schedule_tagged(s.world, delay, a, j.tag)
}

// Claims the terminal for `duration`.
//
// The tag is minted at dispatch rather than here, so output scheduled before a
// tool calls this is still cancellable -- tag 0 is deliberately unmatched by
// cancel_tag, which would otherwise make such output impossible to take back.
begin_work :: proc(s: ^Session, duration: sim.Tick, label: string) {
	j, ok := current(s)
	if !ok {
		return
	}
	j.ends_at = s.world.now + duration
	j.label = strings.clone(label, s.world.allocator)
}

// Corrects how long the running job occupies the terminal.
//
// A tool that schedules output in a loop only knows its true end once the loop
// has run. Estimating up front and not correcting lets the prompt come back --
// and the summary line print -- while results are still arriving.
work_ends_at :: proc(s: ^Session, offset: sim.Tick) {
	j, ok := current(s)
	if !ok {
		return
	}
	j.ends_at = s.world.now + offset
}

// Records where the prompt should move when the running job finishes. Held on
// the job, so killing the job drops the move with it.
set_pending_move :: proc(s: ^Session, host: sim.Handle(sim.Host), user: string) {
	j, ok := current(s)
	if !ok {
		return
	}
	j.pending_move = Move {
		host = host,
		user = strings.clone(user, s.world.allocator),
	}
}
