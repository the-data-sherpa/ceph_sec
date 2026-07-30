package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "input"
import "shell"
import "sim"
import "ui"

GRID_W :: 100
GRID_H :: 38

SEED :: 0xCEF5EC

// M2: jobs run in the background and the network notices you.
//
// The spine is unchanged from M0 -- seed -> world -> fixed-tick scheduler ->
// event ring -> terminal -> grid -> CRT. M1 put a shell on top of it. M2 lets
// several commands occupy that scheduler at once, and gives the world an
// opinion about how loud you are being.
//
// Note what runs inside the tick loop rather than once per frame: advancing the
// world, retiring jobs, and feeding scripted commands. Every one of those is a
// decision about a particular tick, and running them per frame would make the
// result depend on the frame rate.

main :: proc() {
	opts := parse_args()

	w: sim.World
	if err := sim.world_init(&w, SEED); err != nil {
		fmt.eprintln("failed to allocate world arena:", err)
		return
	}
	defer sim.world_destroy(&w)

	origin := build_scenario(&w)

	sess: shell.Session
	shell.session_init(&sess, &w, origin, "operator")

	app: ui.App
	ui.app_init(&app, "Ceph.Sec", GRID_W, GRID_H, "assets/shaders/crt.fs")
	defer ui.app_shutdown(&app)

	if !app.crt.ok {
		fmt.eprintln("warning: crt.fs failed to load; rendering without the screen effect")
	}

	keys: ui.Input_State
	ui.input_init(&keys)
	defer ui.input_destroy(&keys)

	term: ui.Term
	greeting(&w)
	debriefed := false

	// Commands queued by --exec, fed in one at a time as the shell frees up.
	next_queued := 0

	accumulator: f64

	for !ui.app_should_close(&app) {
		dt := ui.app_frame_time(&app)
		ui.app_debug_keys(&app)

		// Clamp before accumulating. Without this, one long stall (a breakpoint,
		// a dragged window) queues thousands of ticks, which take longer to
		// simulate than the stall did, which queues more -- the spiral of death.
		accumulator += min(dt, 0.25)
		for accumulator >= sim.TICK_DT {
			sim.tick(&w)
			// Inside the loop, not after it. Both of these are decisions about
			// what happens at a particular tick; running them once per frame
			// made the tick they landed on depend on the frame rate, which is
			// exactly the frame-quantisation the determinism guarantee forbids.
			shell.session_update(&sess)
			if next_queued < len(opts.exec) && !shell.session_busy(&sess) && !sim.run_over(&w) {
				shell.session_exec(&sess, opts.exec[next_queued])
				next_queued += 1
			}
			accumulator -= sim.TICK_DT
		}

		for ev in ui.poll_input(&keys, dt) {
			if scroll, is_scroll := ev.(input.Scroll); is_scroll {
				ui.term_scroll_by(&term, scroll.lines, GRID_H - 7)
				continue
			}
			if key, is_key := ev.(input.Key_Pressed); is_key {
				#partial switch key.key {
				case .Page_Up:
					ui.term_scroll_by(&term, 10, GRID_H - 7)
					continue
				case .Page_Down:
					ui.term_scroll_by(&term, -10, GRID_H - 7)
					continue
				case .Ctrl_L:
					ui.term_clear(&term)
					continue
				}
			}
			if shell.session_input(&sess, ev) {
				ui.term_scroll_to_bottom(&term)
			}
		}

		drain_events(&w, &term)

		// After draining, so the run's own final lines land above the summary.
		if sim.run_over(&w) && !debriefed {
			debriefed = true
			debrief(&w, &term)
			ui.term_scroll_to_bottom(&term)
		}

		layout(&app, &w, &sess, &term)
		ui.app_render(&app, f32(sim.tick_seconds(w.now)))

		// Checked after draining and drawing, so a run's final output -- the
		// debrief especially -- is never left sitting unread in the event ring.
		// `exit` leaves at once; being caught or extracting holds the screen.
		if w.run.state == .Quit {
			break
		}

		if opts.shot.enabled && w.now >= opts.shot.at {
			ui.app_capture(&app, opts.shot.path)
			fmt.printfln("wrote %s at tick %d", opts.shot.path, u64(w.now))
			break
		}

		free_all(context.temp_allocator)
	}
}

// --- arguments --------------------------------------------------------------

Options :: struct {
	shot: Autoshot,
	exec: []string,
}

// `--shot <seconds> [path]` runs to a fixed point on the sim clock, writes a
// screenshot and exits. Because the sim is deterministic and the shader's time
// uniform is driven from the sim clock, the same seed and tick always produce
// the same image -- so this is a visual regression check, not a convenience.
Autoshot :: struct {
	enabled: bool,
	at:      sim.Tick,
	path:    cstring,
}

parse_args :: proc() -> Options {
	opts: Options
	args := os.args

	for i := 1; i < len(args); i += 1 {
		switch args[i] {
		case "--shot":
			secs := 6.0
			if i + 1 < len(args) {
				if v, ok := strconv.parse_f64(args[i + 1]); ok {
					secs = v
					i += 1
				}
			}
			path: cstring = "cephsec.png"
			if i + 1 < len(args) && len(args[i + 1]) > 0 && args[i + 1][0] != '-' {
				path = fmt.caprintf("%s", args[i + 1])
				i += 1
			}
			opts.shot = {
				enabled = true,
				at      = sim.seconds(secs),
				path    = path,
			}

		// `--exec "nmap -sV 10.0.4.0/24; cat /home/svc/deploy.env"` drives the
		// shell from the command line. Makes the whole loop scriptable, which is
		// what lets a screenshot capture a real session rather than a mock-up.
		case "--exec":
			if i + 1 < len(args) {
				i += 1
				parts := strings.split(args[i], ";")
				cleaned := make([dynamic]string, 0, len(parts))
				for p in parts {
					trimmed := strings.trim_space(p)
					if len(trimmed) > 0 {
						append(&cleaned, trimmed)
					}
				}
				opts.exec = cleaned[:]
			}
		}
	}
	return opts
}

// --- event drain ------------------------------------------------------------

// The one place sim vocabulary is translated into presentation vocabulary.
// Keeping it here is what lets `ui` stay a general text-mode toolkit that knows
// nothing about hosts, services or access levels.
level_color :: proc(l: sim.Log_Level) -> ui.Color_Id {
	switch l {
	case .Plain:
		return .Text
	case .Info:
		return .Dim
	case .Cmd:
		return .Bright
	case .Trace:
		// The one Color_Id declared in M0's theme and never used until now.
		return .Trace
	case .Heading:
		return .Bright
	case .Data:
		return .Accent
	case .Good:
		return .Good
	case .Warn:
		return .Warn
	case .Bad:
		return .Bad
	}
	return .Text
}

drain_events :: proc(w: ^sim.World, term: ^ui.Term) {
	for {
		e, ok := sim.ring_pop(&w.events)
		if !ok {
			break
		}
		#partial switch ev in e {
		case sim.Ev_Log:
			// `clear` reaches the frontend as a sentinel rather than an event
			// type: what the scrollback does is not something the world models.
			if ev.text == shell.CLEAR_SENTINEL {
				ui.term_clear(term)
				continue
			}
			// Background jobs get a `[N] ` gutter so interleaved output stays
			// attributable. Foreground work carries job 0 and is unprefixed.
			if ev.job != 0 {
				ui.term_push(
					term,
					fmt.aprintf("[%d] %s", ev.job, ev.text, allocator = w.allocator),
					level_color(ev.level),
				)
				continue
			}
			// Safe to store by reference: sim cloned this into the run arena.
			ui.term_push(term, ev.text, level_color(ev.level))

		case sim.Ev_Cred_Obtained:
			// Discovery events are narrated by the tool that caused them, so
			// they need no line here. Credentials get one, because acquiring
			// one is the most consequential thing that happens in a run.
			if ev.index < len(w.keyring) {
				c := w.keyring[ev.index]
				ui.term_push(
					term,
					fmt.aprintf("    %s / %s", c.username, c.password, allocator = w.allocator),
					.Good,
				)
			}
		}
	}
}

// --- the debrief ------------------------------------------------------------

// Rendered here rather than in `sim`, deliberately.
//
// Formatting would pass the purity gate -- core:fmt is allowed -- but column
// layout is presentation, and sorting inside sim with core:slice would make tie
// order an implementation detail of the pinned Odin release, which is the exact
// hazard that motivated hand-rolling PCG32. Sim owns the noise log; main owns
// how it reads.
debrief :: proc(w: ^sim.World, term: ^ui.Term) {
	push :: proc(w: ^sim.World, term: ^ui.Term, text: string, colour: ui.Color_Id) {
		ui.term_push(term, fmt.aprintf("%s", text, allocator = w.allocator), colour)
	}

	push(w, term, "", .Text)
	switch w.run.state {
	case .Extracted:
		push(w, term, "== OBJECTIVE RECOVERED ==", .Good)
	case .Caught:
		push(w, term, "== ATTRIBUTED ==", .Bad)
		push(w, term, "They know who you are. The contract is void.", .Bad)
	case .Quit:
		push(w, term, "== DISCONNECTED ==", .Dim)
	case .Running:
		return
	}

	elapsed := sim.tick_seconds(w.run.ended_at)
	push(w, term, fmt.aprintf("elapsed %d:%02d   trace %.1f%%   seed %08x", int(elapsed) / 60, int(elapsed) % 60, f32(w.trace.level) / 100, w.seed, allocator = w.allocator), .Dim)

	// Which segments sat visibly hot, and for how long. This is what makes
	// being caught explicable rather than arbitrary.
	any_hot := false
	it: int
	for sn in sim.pool_iter(&w.subnets, &it) {
		if sn.hot_ticks == 0 {
			continue
		}
		if !any_hot {
			push(w, term, "", .Text)
			any_hot = true
		}
		secs := sim.tick_seconds(sn.hot_ticks)
		push(
			w,
			term,
			fmt.aprintf("%s sat above the alarm line for %dm %02ds", sn.name, int(secs) / 60, int(secs) % 60, allocator = w.allocator),
			.Warn,
		)
	}

	// The loudest charges, with the command line responsible. Selection sort
	// over at most 32 records -- small, and stable in a way core:slice's sort
	// would not guarantee.
	if w.noise_log.count > 0 {
		push(w, term, "", .Text)
		push(w, term, "loudest actions:", .Dim)

		shown := min(w.noise_log.count, 5)
		used: [sim.NOISE_LOG_CAP]bool
		for _ in 0 ..< shown {
			best := -1
			var_best: i32 = -1
			for i in 0 ..< w.noise_log.count {
				if used[i] {
					continue
				}
				r, ok := sim.noise_log_at(w, i)
				if ok && r.applied > var_best {
					best, var_best = i, r.applied
				}
			}
			if best < 0 {
				break
			}
			used[best] = true

			r, _ := sim.noise_log_at(w, best)
			at := sim.tick_seconds(r.at)
			name := "?"
			if sn, ok := sim.pool_get(&w.subnets, r.subnet); ok {
				name = sn.name
			}
			push(
				w,
				term,
				fmt.aprintf("  T+%02d:%02d  %-6s %5.1f  %s", int(at) / 60, int(at) % 60, name, f32(r.applied) / 100, r.source, allocator = w.allocator),
				.Accent,
			)
		}
	}

	push(w, term, "", .Text)
	push(w, term, "ESC to quit.", .Dim)
}

// --- presentation -----------------------------------------------------------

layout :: proc(app: ^ui.App, w: ^sim.World, sess: ^shell.Session, term: ^ui.Term) {
	g := &app.grid
	ui.grid_clear(g)

	header(g, w, sess)

	body_h := GRID_H - 4
	term_w := 66

	ui.grid_panel(g, 0, 1, term_w, body_h, "term")

	// The input line takes the last row of the pane; scrollback gets the rest.
	scroll_h := body_h - 3
	ui.term_draw(term, g, 2, 2, term_w - 4, scroll_h)

	// ~1.6 Hz, driven off sim time so it stays deterministic for screenshots.
	blink := int(sim.tick_seconds(w.now) * 1.6) % 2 == 0
	ui.term_draw_input(
		g,
		2,
		2 + scroll_h,
		term_w - 4,
		shell.prompt(sess, context.temp_allocator),
		shell.line_text(&sess.line, context.temp_allocator),
		sess.line.cursor,
		shell.session_busy(sess),
		blink,
	)

	side_x := term_w
	side_w := GRID_W - term_w
	ui.grid_panel(g, side_x, 1, side_w, body_h, "session")
	session_panel(g, w, sess, side_x + 2, 3, side_w - 4)

	footer(g, app, term, w.events.dropped)
}

header :: proc(g: ^ui.Grid, w: ^sim.World, sess: ^shell.Session) {
	ui.grid_fill(g, 0, 0, GRID_W, 1, ' ', .Bright, .Bg_Panel)
	ui.grid_write(g, 1, 0, "CEPH.SEC", .Bright, .Bg_Panel, {.Bold})

	if sim.run_over(w) {
		ui.grid_write(g, 10, 0, run_headline(w.run.state), .Bad if w.run.state == .Caught else .Good, .Bg_Panel)
	} else if shell.session_busy(sess) {
		ui.grid_write(g, 10, 0, fmt.tprintf("running %s ...", shell.foreground_label(sess)), .Warn, .Bg_Panel)
	} else if jobs := shell.slots_in_use(sess); jobs > 0 {
		ui.grid_write(g, 10, 0, fmt.tprintf("%d job%s running", jobs, jobs == 1 ? "" : "s"), .Accent, .Bg_Panel)
	} else {
		ui.grid_write(g, 10, 0, "milestone 2 -- jobs and trace", .Dim, .Bg_Panel)
	}

	// Trace sits in the header rather than the panel: it is the run clock, and
	// it should be visible without looking for it.
	trace := fmt.tprintf("TRACE %5.1f%%", f32(w.trace.level) / 100)
	trace_x := GRID_W - len(trace) - 15
	ui.grid_write(g, trace_x, 0, trace, trace_color(w.trace.level), .Bg_Panel, w.trace.level > 0 ? Attrs_Bold : {})

	// Frozen once the run is over: the world keeps ticking so the debrief can
	// finish drawing, but a clock still counting up past the end contradicts
	// every timestamp in the summary underneath it.
	shown_at := sim.run_over(w) ? w.run.ended_at : w.now
	elapsed := sim.tick_seconds(shown_at)
	clock := fmt.tprintf("T+%02d:%02d.%02d", int(elapsed) / 60, int(elapsed) % 60, int(elapsed * 100) % 100)
	ui.grid_write(g, GRID_W - len(clock) - 1, 0, clock, sim.run_over(w) ? .Dim : .Accent, .Bg_Panel)
}

session_panel :: proc(g: ^ui.Grid, w: ^sim.World, sess: ^shell.Session, x, y, width: int) {
	row := y

	field :: proc(g: ^ui.Grid, x, y, width: int, label, value: string, vc: ui.Color_Id = .Bright) {
		ui.grid_write(g, x, y, label, .Dim, .Bg_Panel)
		ui.grid_write(g, x + width - len(value), y, value, vc, .Bg_Panel)
	}

	if h, ok := sim.pool_get(&w.hosts, sess.host); ok {
		buf: [15]u8
		ui.grid_write(g, x, row, "shell on", .Dim, .Bg_Panel)
		row += 1
		ui.grid_write(g, x, row, h.hostname, .Bright, .Bg_Panel, {.Bold})
		addr := sim.addr_write(buf[:], h.address)
		ui.grid_write(g, x + width - len(addr), row, addr, .Accent, .Bg_Panel)
		row += 1
		field(g, x, row, width, "access", fmt.tprintf("%v", h.access), h.access == .Root ? .Good : .Bright)
		row += 2
	}

	discovered, services, owned := survey(w)
	ui.grid_write(g, x, row, "recon", .Dim, .Bg_Panel)
	row += 1
	field(g, x, row, width, " hosts seen", fmt.tprintf("%d", discovered))
	row += 1
	field(g, x, row, width, " services", fmt.tprintf("%d", services))
	row += 1
	field(g, x, row, width, " footholds", fmt.tprintf("%d", owned), owned > 1 ? .Good : .Bright)
	row += 2

	// Jobs, when there are any. Costs a line only while it is telling you
	// something.
	if shell.slots_in_use(sess) > 0 || shell.session_busy(sess) {
		ui.grid_write(g, x, row, "jobs", .Dim, .Bg_Panel)
		row += 1
		for id in 1 ..= sess.next_job_id {
			j, ok := shell.job_by_id(sess, id)
			if !ok || !shell.job_live(sess, j) || row >= GRID_H - 14 {
				continue
			}
			left := fmt.tprintf("%.0fs", sim.tick_seconds(j.ends_at - w.now))
			ui.grid_write(g, x, row, fmt.tprintf(" [%d] %s", j.id, j.label), .Accent, .Bg_Panel)
			ui.grid_write(g, x + width - len(left), row, left, .Dim, .Bg_Panel)
			row += 1
		}
		row += 1
	}

	ui.grid_write(g, x, row, "keyring", .Dim, .Bg_Panel)
	row += 1
	if len(w.keyring) == 0 {
		ui.grid_write(g, x, row, " (empty)", .Dim, .Bg_Panel)
		row += 1
	} else {
		for c in w.keyring {
			if row >= GRID_H - 12 {
				break
			}
			ui.grid_write(g, x, row, fmt.tprintf(" %s", c.username), .Good, .Bg_Panel)
			row += 1
		}
	}
	row += 1

	// Segments, each with its own suspicion bar. This is where the player
	// learns the causal link between a noisy action and the consequence, so it
	// has to sit next to the terminal rather than behind a command.
	ui.grid_write(g, x, row, "segments", .Dim, .Bg_Panel)
	row += 1
	it: int
	for sn, h in sim.pool_iter(&w.subnets, &it) {
		if row >= GRID_H - 4 {
			break
		}
		reachable := sim.subnet_reachable(w, h)
		ui.grid_write(g, x, row, reachable ? "●" : "○", reachable ? .Good : .Dim, .Bg_Panel)
		ui.grid_write(g, x + 2, row, sn.name, reachable ? .Bright : .Dim, .Bg_Panel)

		if sn.monitoring == .None {
			ui.grid_write(g, x + width - 9, row, "unwatched", .Dim, .Bg_Panel)
			row += 1
			continue
		}

		// The bar is scaled to the alarm line, not to the segment maximum: what
		// matters is how close this is to making the trace move, and a bar that
		// looked nearly empty at the moment it started costing you would be
		// worse than no bar.
		//
		// Drawn with '#' and '-' rather than block characters: at ten cells the
		// shade block's alpha fill reads as one translucent slab rather than as
		// a meter.
		BAR_W :: 10
		frac := f32(sn.suspicion) / f32(sim.SUSPICION_ALARM)
		filled := clamp(int(frac * BAR_W + 0.5), 0, BAR_W)

		colour: ui.Color_Id = .Good
		if sn.alarmed {
			colour = .Bad
		} else if frac > 0.6 {
			colour = .Warn
		}

		bar := strings.builder_make(context.temp_allocator)
		for i in 0 ..< BAR_W {
			strings.write_byte(&bar, i < filled ? '#' : '-')
		}
		ui.grid_write(g, x + width - BAR_W, row, strings.to_string(bar), filled > 0 ? colour : .Dim, .Bg_Panel)
		row += 1
	}
}

Attrs_Bold :: ui.Attrs{.Bold}

trace_color :: proc(level: i32) -> ui.Color_Id {
	switch {
	case level >= sim.TRACE_HUNT:
		return .Bad
	case level >= sim.TRACE_ALERT:
		return .Trace
	case level >= sim.TRACE_REVIEW:
		return .Warn
	case level > 0:
		return .Trace
	}
	return .Dim
}

run_headline :: proc(state: sim.Run_State) -> string {
	switch state {
	case .Extracted:
		return "OBJECTIVE RECOVERED"
	case .Caught:
		return "ATTRIBUTED -- run over"
	case .Quit:
		return "disconnected"
	case .Running:
		return ""
	}
	return ""
}

survey :: proc(w: ^sim.World) -> (discovered, services, owned: int) {
	it: int
	for host in sim.pool_iter(&w.hosts, &it) {
		if host.discovered {
			discovered += 1
		}
		if host.access > .None {
			owned += 1
		}
		for s in host.services {
			if s.discovered {
				services += 1
			}
		}
	}
	return
}

footer :: proc(g: ^ui.Grid, app: ^ui.App, term: ^ui.Term, dropped: u64) {
	y := GRID_H - 2
	ui.grid_fill(g, 0, y, GRID_W, 1, ' ', .Dim, .Bg_Panel)

	hint := "`help` · ^C interrupt · PgUp/PgDn scroll · F1 crt · F3 theme · F12 shot"
	ui.grid_write(g, 1, y, hint, .Dim, .Bg_Panel)

	if term.scroll > 0 {
		tag := fmt.tprintf("scrolled %d", term.scroll)
		ui.grid_write(g, GRID_W - len(tag) - 1, y, tag, .Warn, .Bg_Panel)
	} else if dropped > 0 {
		// The ring is deliberately lossy so a stalled frontend cannot block the
		// sim. Loss that nobody can see is the part that would be a bug.
		tag := fmt.tprintf("%d lines dropped", dropped)
		ui.grid_write(g, GRID_W - len(tag) - 1, y, tag, .Bad, .Bg_Panel)
	}
}

// --- scenario ---------------------------------------------------------------

greeting :: proc(w: ^sim.World) {
	sim.log_line(w, "ceph.sec // operator console", .Info)
	sim.log_line(w, "", .Plain)
	sim.log_line(w, "CONTRACT: NORTHWIND LOGISTICS", .Heading)
	sim.log_line(w, "Recover /srv/backup/manifest.sql from their file server.", .Plain)
	sim.log_line(w, "You have root on a rented VPS with a route into their DMZ.", .Plain)
	sim.log_line(w, "", .Plain)
	sim.log_line(w, "`help` lists what you can run. Start by finding out what is there.", .Info)
	sim.log_line(w, "", .Plain)
}

// The M1 network.
//
// The intended path is meant to be *discoverable* rather than guessable:
// scanning the DMZ finds web01, whose deployment config leaks a service account
// password. That password is reused on jump01 -- the box bridging into CORP --
// and jump01's svc account is an admin, so taking it opens the route to the
// objective. Every step is visible from the step before it.
build_scenario :: proc(w: ^sim.World) -> sim.Handle(sim.Host) {
	// Monitoring runs inversely to how interesting a segment is, which is the
	// recurring shape of the whole game: the boxes that are easy to be loud
	// around are the ones not worth reaching.
	wan := sim.add_subnet(w, "WAN", sim.addr(198, 51, 100, 0), 24, .None)
	dmz := sim.add_subnet(w, "DMZ", sim.addr(10, 0, 4, 0), 24, .Low)
	corp := sim.add_subnet(w, "CORP", sim.addr(10, 0, 9, 0), 24, .Medium)

	// The operator's own box. Held at root from the start; it is the thing the
	// player stands on rather than a target.
	origin := sim.add_host(w, "ceph", sim.addr(198, 51, 100, 7), wan, "Debian 12")
	sim.grant_access(w, origin, .Root)
	w.origin = origin

	sim.add_file(
		w,
		origin,
		{
			path = "/root/contract.txt",
			content = "NORTHWIND LOGISTICS -- retrieval\n\ntarget:   /srv/backup/manifest.sql\nnetwork:  10.0.4.0/24 is routable from this host\nnote:     10.0.9.0/24 is not directly routable.\n          find something that bridges the two.\n\nno credentials supplied. start with what they expose.",
		},
	)
	sim.add_file(w, origin, {path = "/root/.ssh/known_hosts", content = "# nothing here yet"})

	// --- DMZ ---------------------------------------------------------------

	gw := sim.add_host(w, "gw-edge", sim.addr(10, 0, 4, 1), dmz, "VyOS 1.2")
	sim.add_service(w, gw, {port = 22, proto = .TCP, name = "ssh", product = "OpenSSH", version = "7.4"})

	web := sim.add_host(w, "web01", sim.addr(10, 0, 4, 11), dmz, "Ubuntu 18.04")
	sim.add_service(w, web, {port = 22, proto = .TCP, name = "ssh", product = "OpenSSH", version = "7.6p1"})
	sim.add_service(w, web, {port = 80, proto = .TCP, name = "http", product = "Apache httpd", version = "2.4.29"})
	sim.add_service(w, web, {port = 443, proto = .TCP, name = "https", product = "Apache httpd", version = "2.4.29"})

	jump := sim.add_host(w, "jump01", sim.addr(10, 0, 4, 19), dmz, "Ubuntu 20.04")
	sim.add_service(w, jump, {port = 22, proto = .TCP, name = "ssh", product = "OpenSSH", version = "8.2p1"})

	// The reused password. `svc` exists on several boxes with the same
	// password, which is the entire lateral-movement mechanic and needs no
	// special case anywhere: ssh just compares strings.
	SVC_PASSWORD :: "Nw-deploy-2019!"

	sim.add_account(w, web, {username = "svc", password = SVC_PASSWORD})
	sim.add_account(w, jump, {username = "svc", password = SVC_PASSWORD, is_admin = true})

	// The way in.
	//
	// The index page carries a leftover developer comment naming a file that
	// should never have been in the document root -- and that file is the
	// deployment .env. Both halves of this are among the most common real
	// findings there are, and together they make the entry point *discoverable*
	// rather than guessable: curl the site, read the source, follow the path.
	sim.add_file(
		w,
		web,
		{
			path = "/var/www/html/index.html",
			content = "<html>\n<body>\n  <h1>Northwind Logistics</h1>\n  <p>Consignment tracking portal.</p>\n  <!-- TODO(deploy): stop shipping .env into the web root -->\n</body>\n</html>",
		},
	)
	sim.add_file(
		w,
		web,
		{
			path = "/var/www/html/.env",
			content = "# deployment credentials -- do not commit\nDEPLOY_USER=svc\nDEPLOY_PASS=Nw-deploy-2019!\nDEPLOY_TARGET=jump01.northwind.internal",
			sensitive = true,
		},
		{{username = "svc", password = SVC_PASSWORD}},
	)

	sim.add_file(w, web, {path = "/etc/apache2/apache2.conf", content = "ServerName web01.northwind.internal\nListen 80\nListen 443"})
	// Confirms the pivot target once you have a shell here, for a player who
	// took the credential and did not stop to look around.
	sim.add_file(w, web, {path = "/home/svc/.bash_history", content = "ssh svc@jump01\nsudo systemctl restart nginx"})

	// --- CORP, behind the pivot --------------------------------------------

	fs := sim.add_host(w, "fs01", sim.addr(10, 0, 9, 10), corp, "Windows Server 2016")
	sim.add_service(w, fs, {port = 22, proto = .TCP, name = "ssh", product = "OpenSSH", version = "7.9"})
	sim.add_service(w, fs, {port = 445, proto = .TCP, name = "smb", product = "Samba", version = "4.5.9"})
	sim.add_account(w, fs, {username = "svc", password = SVC_PASSWORD})

	sim.add_file(
		w,
		fs,
		{
			path = "/srv/backup/manifest.sql",
			content = "-- northwind logistics :: consignment manifest\n-- 2026-07 export\nINSERT INTO consignments VALUES (88412,'ROTTERDAM','SEALED');\nINSERT INTO consignments VALUES (88413,'FELIXSTOWE','SEALED');",
			sensitive = true,
			objective = true,
		},
	)
	sim.add_file(w, fs, {path = "/srv/backup/README", content = "nightly dumps land here at 0200."})

	// --- routing ------------------------------------------------------------

	// The VPS has a route into the DMZ; that is what the contract bought.
	append(&w.links, sim.Link{from = wan, to = dmz, via = origin, min_access = .User})
	// CORP is reachable only through jump01, and only with root on it.
	append(&w.links, sim.Link{from = dmz, to = corp, via = jump, min_access = .Root})

	return origin
}
