package shell

import "core:fmt"
import "core:strings"
import "../input"
import "../sim"

// The shell's own state: where you are standing and what you are waiting on.
//
// This is not in `sim` because the world does not care which directory you are
// in. What the world *does* own is everything that survives moving between
// hosts -- access levels, the keyring, discovery. The split is: sim knows what
// is true, shell knows where you are looking from.

Session :: struct {
	world: ^sim.World,
	line:  Line,

	host: sim.Handle(sim.Host), // the box the prompt is on
	user: string,
	cwd:  string,

	// A foreground command occupies the terminal until `busy_until`. Its
	// scheduled output carries `busy_tag`, so ^C is one cancel_tag call.
	busy_until: sim.Tick,
	busy_tag:   u32,
	busy_label: string,

	// Shell-level effects that must land when the running command finishes.
	// World state can be scheduled as a sim.Action, but "the prompt is now on
	// another host" is not something the world models -- so it waits here and
	// is applied by session_update. Cancelled by ^C along with everything else.
	pending_move: Maybe(Move),

	should_quit: bool,
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
	line_init(&s.line, w.allocator)
}

home_dir :: proc(user: string, allocator := context.allocator) -> string {
	if user == "root" {
		return strings.clone("/root", allocator)
	}
	return fmt.aprintf("/home/%s", user, allocator = allocator)
}

session_busy :: proc(s: ^Session) -> bool {
	return s.world.now < s.busy_until
}

// Call once per tick, after the world has advanced. Retires the busy state and
// applies any shell-level effect the finished command left behind.
session_update :: proc(s: ^Session) {
	if session_busy(s) {
		return
	}
	if move, ok := s.pending_move.?; ok {
		session_move_to(s, move.host, move.user)
		s.pending_move = nil
	}
	s.busy_tag = 0
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
// While a foreground command is running, everything except ^C is dropped rather
// than buffered. Real terminals buffer, but dropping makes the "the terminal is
// busy" state unambiguous, and typing blindly into a scan you cannot see the
// end of is not an experience worth reproducing.
session_input :: proc(s: ^Session, ev: input.Event) -> bool {
	#partial switch e in ev {
	case input.Rune_Typed:
		if session_busy(s) {
			return false
		}
		line_insert(&s.line, e.ch)

	case input.Key_Pressed:
		if e.key == .Ctrl_C {
			session_interrupt(s)
			return false
		}
		if session_busy(s) {
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

session_interrupt :: proc(s: ^Session) {
	if session_busy(s) {
		cancelled := sim.cancel_tag(s.world, s.busy_tag)
		sim.log_line(
			s.world,
			fmt.aprintf(
				"^C  %s interrupted (%d pending)",
				s.busy_label,
				cancelled,
				allocator = s.world.allocator,
			),
			.Warn,
		)
		s.busy_until = s.world.now
		s.busy_tag = 0
		// An interrupted ssh must not still land you on the target.
		s.pending_move = nil
		return
	}

	// Not busy: ^C abandons the current line, like a real shell.
	sim.log_line(
		s.world,
		fmt.aprintf("%s%s^C", prompt(s, context.temp_allocator), line_text(&s.line, context.temp_allocator), allocator = s.world.allocator),
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

	spec.run(s, &cmd)
}

// --- output helpers ---------------------------------------------------------

// Immediate output. Text is cloned into the run arena by sim.log_line, so
// temp-allocated formatting is safe to pass here.
out :: proc(s: ^Session, text: string, level: sim.Log_Level = .Plain) {
	sim.log_line(s.world, text, level)
}

// Output scheduled `delay` into the future under the running command's tag, so
// ^C can take it back. This is how a tool streams results while time passes.
out_at :: proc(s: ^Session, delay: sim.Tick, text: string, level: sim.Log_Level = .Plain) {
	sim.schedule_tagged(
		s.world,
		delay,
		sim.Act_Log{text = strings.clone(text, s.world.allocator), level = level},
		s.busy_tag,
	)
}

// Claims the terminal for `duration` and opens a fresh cancellation tag.
// Everything a tool schedules afterwards belongs to that tag.
begin_work :: proc(s: ^Session, duration: sim.Tick, label: string) {
	s.busy_tag = sim.next_tag(s.world)
	s.busy_until = s.world.now + duration
	s.busy_label = strings.clone(label, s.world.allocator)
}

// Corrects how long the running command occupies the terminal.
//
// A tool that schedules output in a loop only knows its true end once the loop
// has run. Estimating up front and not correcting lets the prompt come back --
// and the summary line print -- while results are still arriving.
work_ends_at :: proc(s: ^Session, offset: sim.Tick) {
	s.busy_until = s.world.now + offset
}

// Schedules a state change under the running command's tag.
act_at :: proc(s: ^Session, delay: sim.Tick, a: sim.Action) {
	sim.schedule_tagged(s.world, delay, a, s.busy_tag)
}
