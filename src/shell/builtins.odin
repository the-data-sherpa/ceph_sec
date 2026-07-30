package shell

import "core:fmt"
import "core:strings"
import "../sim"

// Built-in commands. These are instant -- they represent things happening on a
// box you already hold, which costs no time and, once trace exists, no noise.
// Anything that touches the network is a tool and lives in tools.odin.

cmd_help :: proc(s: ^Session, cmd: ^Command) {
	if name, ok := positional(cmd, 0); ok {
		spec, found := lookup(name)
		if !found {
			out(s, fmt.tprintf("help: no such command: %s", name), .Bad)
			return
		}
		out(s, spec.usage, .Heading)
		out(s, fmt.tprintf("    %s", spec.summary))
		return
	}

	out(s, "commands:", .Info)
	current := Category(255)
	for spec in COMMANDS {
		if spec.category != current {
			current = spec.category
			out(s, fmt.tprintf("  [%s]", category_label(current)), .Info)
		}
		out(s, fmt.tprintf("    %-24s %s", spec.usage, spec.summary))
	}
	out(s, "", .Plain)
	out(s, "^C interrupts a running command.", .Info)
}

cmd_clear :: proc(s: ^Session, cmd: ^Command) {
	// The scrollback lives in the frontend, so the sim asks for a clear rather
	// than reaching into it. Kept as a log line with a reserved level so the
	// terminal can act on it without the sim knowing what a terminal is.
	sim.log_line(s.world, CLEAR_SENTINEL, .Info)
}

// Recognised by the frontend when draining events. A sentinel rather than a new
// event type because clearing is a display concern that the world has no
// opinion about.
CLEAR_SENTINEL :: "\x00clear"

cmd_history :: proc(s: ^Session, cmd: ^Command) {
	for h, i in s.line.history {
		out(s, fmt.tprintf("  %3d  %s", i + 1, h))
	}
}

cmd_whoami :: proc(s: ^Session, cmd: ^Command) {
	out(s, s.user)
}

cmd_hostname :: proc(s: ^Session, cmd: ^Command) {
	if h, ok := sim.pool_get(&s.world.hosts, s.host); ok {
		out(s, h.hostname)
	}
}

cmd_id :: proc(s: ^Session, cmd: ^Command) {
	h, ok := sim.pool_get(&s.world.hosts, s.host)
	if !ok {
		return
	}
	buf: [15]u8
	out(
		s,
		fmt.tprintf(
			"user=%s host=%s (%s) access=%v",
			s.user,
			h.hostname,
			sim.addr_write(buf[:], h.address),
			h.access,
		),
	)
}

cmd_creds :: proc(s: ^Session, cmd: ^Command) {
	if len(s.world.keyring) == 0 {
		out(s, "no credentials held", .Info)
		return
	}
	for c, i in s.world.keyring {
		out(s, fmt.tprintf("  [%d] %s:%s", i + 1, c.username, c.password), .Good)
		if len(c.note) > 0 {
			out(s, fmt.tprintf("      from %s", c.note), .Info)
		}
	}
}

// Free, and offline in the strict sense: it reports what you have already
// caused. Nothing here touches a target.
cmd_trace :: proc(s: ^Session, cmd: ^Command) {
	w := s.world

	out(s, fmt.tprintf("trace  %.1f%%", f32(w.trace.level) / 100), w.trace.level > 0 ? .Trace : .Info)
	out(s, "", .Plain)
	out(s, "segment      watch    suspicion", .Info)

	it: int
	for sn, h in sim.pool_iter(&w.subnets, &it) {
		// Segments you have never reached are not information you have.
		if !sim.subnet_reachable(w, h) && sn.suspicion == 0 {
			continue
		}

		bar := meter(sn.suspicion, sim.SUSPICION_MAX, 12)
		level: sim.Log_Level = .Data
		flag := ""
		if sn.suspicion > sim.SUSPICION_ALARM {
			level = .Bad
			flag = "  ALARM"
		} else if sn.suspicion > sim.SUSPICION_ALARM / 2 {
			level = .Warn
		}

		out(
			s,
			fmt.tprintf(
				"%-12s %-8s %s %5.1f%s",
				sn.name,
				sim.monitoring_label(sn.monitoring),
				bar,
				f32(sn.suspicion) / 100,
				flag,
			),
			level,
		)
	}

	out(s, "", .Plain)
	out(
		s,
		fmt.tprintf("the trace advances only while a segment is above %.0f.", f32(sim.SUSPICION_ALARM) / 100),
		.Info,
	)
}

@(private)
meter :: proc(value, max_value: i32, width: int) -> string {
	filled := int(i64(value) * i64(width) / i64(max(max_value, 1)))
	filled = clamp(filled, 0, width)
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< width {
		strings.write_string(&sb, i < filled ? "#" : ".")
	}
	return strings.to_string(sb)
}

cmd_exit :: proc(s: ^Session, cmd: ^Command) {
	// Leaving a pivoted shell drops you back to the box you came from; leaving
	// the origin ends the run. Tracking the full shell chain is still M4 work --
	// for now, exiting anywhere but origin returns to origin.
	if s.host == s.world.origin {
		jobs_kill_all(s)
		sim.end_run(s.world, .Quit)
		return
	}
	session_move_to(s, s.world.origin, "operator")
	out(s, "logout", .Info)
}

// --- filesystem -------------------------------------------------------------

// True if the prompt is standing somewhere it no longer has any right to be.
// session_update normally evicts you first; this is the second lock on the door,
// because reading the objective off a box they have already kicked you from
// would make the hunt cosmetic.
@(private)
lost_the_host :: proc(s: ^Session) -> bool {
	if s.host == s.world.origin {
		return false
	}
	host, ok := sim.pool_get(&s.world.hosts, s.host)
	if !ok {
		return true
	}
	if host.access == .None {
		out(s, "Connection closed by remote host.", .Bad)
		return true
	}
	return false
}

cmd_pwd :: proc(s: ^Session, cmd: ^Command) {
	out(s, s.cwd)
}

cmd_cd :: proc(s: ^Session, cmd: ^Command) {
	if lost_the_host(s) {
		return
	}
	h, ok := sim.pool_get(&s.world.hosts, s.host)
	if !ok {
		return
	}

	target, given := positional(cmd, 0)
	if !given {
		target = home_dir(s.user, context.temp_allocator)
	}

	resolved := resolve_path(s.cwd, target, context.temp_allocator)

	// A path holding a file is not a directory, and saying so is more useful
	// than a bare "no such file".
	if _, is_file := sim.host_file(h, resolved); is_file {
		out(s, fmt.tprintf("cd: not a directory: %s", target), .Bad)
		return
	}
	if !dir_exists(h, resolved) {
		out(s, fmt.tprintf("cd: no such file or directory: %s", target), .Bad)
		return
	}

	s.cwd = strings.clone(resolved, s.world.allocator)
}

cmd_ls :: proc(s: ^Session, cmd: ^Command) {
	if lost_the_host(s) {
		return
	}
	h, ok := sim.pool_get(&s.world.hosts, s.host)
	if !ok {
		return
	}

	target, _ := positional(cmd, 0)
	resolved := resolve_path(s.cwd, target, context.temp_allocator)

	// `ls` on a single file lists that file, as it does everywhere.
	if f, is_file := sim.host_file(h, resolved); is_file {
		out(s, entry_line(f.path, f.size, has_flag(cmd, "l")))
		return
	}
	if !dir_exists(h, resolved) {
		out(s, fmt.tprintf("ls: cannot access '%s': No such file or directory", target), .Bad)
		return
	}

	entries := list_dir(h, resolved, context.temp_allocator)
	long := has_flag(cmd, "l")

	if long {
		for e in entries {
			name := e.is_dir ? fmt.tprintf("%s/", e.name) : e.name
			out(s, entry_line(name, e.size, true), e.is_dir ? .Info : .Plain)
		}
		return
	}

	// Short form: pack names onto lines, directories marked with a trailing
	// slash. Columns are not aligned into a grid -- the terminal is only 60-odd
	// cells wide and a simple flow reads better than ragged columns.
	sb := strings.builder_make(context.temp_allocator)
	width := 0
	for e in entries {
		name := e.is_dir ? fmt.tprintf("%s/", e.name) : e.name
		if width > 0 && width + len(name) + 2 > 56 {
			out(s, strings.to_string(sb))
			strings.builder_reset(&sb)
			width = 0
		}
		if width > 0 {
			strings.write_string(&sb, "  ")
			width += 2
		}
		strings.write_string(&sb, name)
		width += len(name)
	}
	if width > 0 {
		out(s, strings.to_string(sb))
	}
}

@(private)
entry_line :: proc(name: string, size: int, long: bool) -> string {
	if long {
		return fmt.tprintf("  %8d  %s", size, name)
	}
	return fmt.tprintf("  %s", name)
}

cmd_cat :: proc(s: ^Session, cmd: ^Command) {
	if lost_the_host(s) {
		return
	}
	h, ok := sim.pool_get(&s.world.hosts, s.host)
	if !ok {
		return
	}

	target, given := positional(cmd, 0)
	if !given {
		out(s, "usage: cat <file>", .Bad)
		return
	}

	resolved := resolve_path(s.cwd, target, context.temp_allocator)
	f, found := sim.host_file(h, resolved)
	if !found {
		if dir_exists(h, resolved) {
			out(s, fmt.tprintf("cat: %s: Is a directory", target), .Bad)
		} else {
			out(s, fmt.tprintf("cat: %s: No such file or directory", target), .Bad)
		}
		return
	}

	// Iterate a local copy: split_lines_iterator advances the string it is
	// given, so passing the stored field would consume the file and leave every
	// later read of it empty.
	body := f.content
	for line in strings.split_lines_iterator(&body) {
		out(s, line)
	}

	// The one place a builtin costs attention. Reading the material that
	// actually matters trips file auditing -- and without it the last third of
	// a run, including taking the objective, would be completely silent.
	if f.sensitive {
		touched(s, s.host, NOISE_READ_SENSITIVE)
	}

	// Reading a config file is how credentials enter play. Harvesting happens
	// in sim so that `cat` and `curl` have identical consequences -- a file
	// that leaks a password should leak it however you got at it.
	if index, ok := sim.host_file_index(h, resolved); ok {
		sim.harvest_file(s.world, s.host, index)
	}
}

// Moves the prompt to another host. Used by `ssh` and `exit`.
session_move_to :: proc(s: ^Session, host: sim.Handle(sim.Host), user: string) {
	s.host = host
	s.user = strings.clone(user, s.world.allocator)
	s.cwd = strings.clone(home_dir(user, context.temp_allocator), s.world.allocator)
}
