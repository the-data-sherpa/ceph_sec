package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "sim"
import "ui"

GRID_W :: 100
GRID_H :: 38

SEED :: 0xCEF5EC

// Milestone 0 has no gameplay. What it does have is the full spine wired up
// end to end -- seed -> world -> fixed-tick scheduler -> event ring -> terminal
// -> character grid -> offscreen buffer -> CRT shader -> window. The boot
// sequence below exists to exercise every link in that chain so the foundation
// is visually verifiable and not merely compiling.

// `cephsec --shot <seconds> [path]` runs to a fixed point on the sim clock,
// writes a screenshot and exits. Because the sim is deterministic, the same
// seed and the same tick count always produce the same frame -- so this is a
// visual regression check, not just a convenience. For a game whose look is
// carried by a shader, that is worth having from the start.
Autoshot :: struct {
	enabled: bool,
	at:      sim.Tick,
	path:    cstring,
}

parse_autoshot :: proc() -> Autoshot {
	args := os.args
	for i in 1 ..< len(args) {
		if args[i] != "--shot" {
			continue
		}
		secs := 6.0
		if i + 1 < len(args) {
			if v, ok := strconv.parse_f64(args[i + 1]); ok {
				secs = v
			}
		}
		path: cstring = "cephsec.png"
		if i + 2 < len(args) && len(args[i + 2]) > 0 && args[i + 2][0] != '-' {
			path = fmt.caprintf("%s", args[i + 2])
		}
		return {enabled = true, at = sim.seconds(secs), path = path}
	}
	return {}
}

main :: proc() {
	shot := parse_autoshot()

	w: sim.World
	if err := sim.world_init(&w, SEED); err != nil {
		fmt.eprintln("failed to allocate world arena:", err)
		return
	}
	defer sim.world_destroy(&w)

	build_demo(&w)
	scheduled_total := len(w.timers)

	app: ui.App
	ui.app_init(&app, "Ceph.Sec", GRID_W, GRID_H, "assets/shaders/crt.fs")
	defer ui.app_shutdown(&app)

	if !app.crt.ok {
		fmt.eprintln("warning: crt.fs failed to load; rendering without the screen effect")
	}

	term: ui.Term
	ui.term_push(&term, "", .Dim)

	// Real-time is a property of the frontend: it converts wall-clock delta into
	// a whole number of fixed ticks. The sim never sees a clock, which is what
	// keeps a real-time game reproducible from its seed.
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
			accumulator -= sim.TICK_DT
		}

		drain_events(&w, &term)
		layout(&app, &w, &term, scheduled_total)
		// Sim time, not wall time -- see crt_set_time.
		ui.app_render(&app, f32(sim.tick_seconds(w.now)))

		if shot.enabled && w.now >= shot.at {
			ui.app_capture(&app, shot.path)
			fmt.printfln("wrote %s at tick %d", shot.path, u64(w.now))
			break
		}

		free_all(context.temp_allocator)
	}
}

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
		switch ev in e {
		case sim.Ev_Log:
			// Safe to store by reference: sim cloned this into the run arena.
			ui.term_push(term, ev.text, level_color(ev.level))

		case sim.Ev_Host_Discovered:
			if h, found := sim.pool_get(&w.hosts, ev.host); found {
				buf: [15]u8
				ui.term_push(
					term,
					fmt.aprintf(
						"  %-15s  %s",
						sim.addr_write(buf[:], h.address),
						h.hostname,
						allocator = w.allocator,
					),
					.Bright,
				)
			}

		case sim.Ev_Service_Discovered:
			if h, found := sim.pool_get(&w.hosts, ev.host); found {
				s := h.services[ev.index]
				ui.term_push(
					term,
					fmt.aprintf(
						"      %d/%s  %-8s  %s %s",
						s.port,
						"tcp" if s.proto == .TCP else "udp",
						s.name,
						s.product,
						s.version,
						allocator = w.allocator,
					),
					.Accent,
				)
			}

		case sim.Ev_Access_Gained:
			if h, found := sim.pool_get(&w.hosts, ev.host); found {
				ui.term_push(
					term,
					fmt.aprintf("  [+] %s -> %v", h.hostname, ev.level, allocator = w.allocator),
					.Good,
				)
			}
		}
	}
}

// --- presentation -----------------------------------------------------------

layout :: proc(app: ^ui.App, w: ^sim.World, term: ^ui.Term, scheduled_total: int) {
	g := &app.grid
	ui.grid_clear(g)

	header(g, w)

	body_h := GRID_H - 4
	term_w := 66

	ui.grid_panel(g, 0, 1, term_w, body_h, "term")
	ui.term_draw(term, g, 2, 2, term_w - 4, body_h - 2)

	side_x := term_w
	side_w := GRID_W - term_w
	ui.grid_panel(g, side_x, 1, side_w, body_h, "session")
	session_panel(g, w, side_x + 2, 3, side_w - 4, scheduled_total)

	footer(g, app)
}

header :: proc(g: ^ui.Grid, w: ^sim.World) {
	ui.grid_fill(g, 0, 0, GRID_W, 1, ' ', .Bright, .Bg_Panel)
	ui.grid_write(g, 1, 0, "CEPH.SEC", .Bright, .Bg_Panel, {.Bold})
	ui.grid_write(g, 10, 0, "milestone 0 -- engine foundation", .Dim, .Bg_Panel)

	elapsed := sim.tick_seconds(w.now)
	clock := fmt.tprintf("T+%02d:%02d.%02d", int(elapsed) / 60, int(elapsed) % 60, int(elapsed * 100) % 100)
	ui.grid_write(g, GRID_W - len(clock) - 1, 0, clock, .Accent, .Bg_Panel)
}

session_panel :: proc(g: ^ui.Grid, w: ^sim.World, x, y, width: int, scheduled_total: int) {
	row := y

	field :: proc(g: ^ui.Grid, x, y, width: int, label, value: string, vc: ui.Color_Id = .Bright) {
		ui.grid_write(g, x, y, label, .Dim, .Bg_Panel)
		ui.grid_write(g, x + width - len(value), y, value, vc, .Bg_Panel)
	}

	field(g, x, row, width, "seed", fmt.tprintf("%08x", w.seed), .Accent)
	row += 1
	field(g, x, row, width, "tick", fmt.tprintf("%d", u64(w.now)))
	row += 2

	// Real progress, read straight off the scheduler: how many of the boot
	// sequence's deferred events have fired.
	fired := scheduled_total - len(w.timers)
	frac := f32(fired) / f32(max(scheduled_total, 1))
	ui.grid_write(g, x, row, "boot sequence", .Dim, .Bg_Panel)
	row += 1
	ui.grid_meter(g, x, row, width, frac, .Good, .Bg_Panel)
	row += 1
	pct := fmt.tprintf("%d%%", int(frac * 100))
	ui.grid_write(g, x + width - len(pct), row, pct, .Good, .Bg_Panel)
	row += 2

	ui.grid_write(g, x, row, "world", .Dim, .Bg_Panel)
	row += 1
	field(g, x, row, width, " subnets", fmt.tprintf("%d", sim.pool_len(&w.subnets)))
	row += 1
	field(g, x, row, width, " hosts", fmt.tprintf("%d", sim.pool_len(&w.hosts)))
	row += 1

	discovered, services, owned := survey(w)
	field(g, x, row, width, " discovered", fmt.tprintf("%d", discovered))
	row += 1
	field(g, x, row, width, " services", fmt.tprintf("%d", services))
	row += 1
	field(g, x, row, width, " footholds", fmt.tprintf("%d", owned), .Good if owned > 0 else .Bright)
	row += 2

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
		state := reachable ? "reachable" : "no route"
		ui.grid_write(g, x + width - len(state), row, state, reachable ? .Good : .Dim, .Bg_Panel)
		row += 1
	}

	row += 1
	field(g, x, row, width, "events lost", fmt.tprintf("%d", w.events.dropped), w.events.dropped > 0 ? .Bad : .Dim)
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

footer :: proc(g: ^ui.Grid, app: ^ui.App) {
	y := GRID_H - 2
	ui.grid_fill(g, 0, y, GRID_W, 1, ' ', .Dim, .Bg_Panel)

	crt_state := "on" if app.crt_enabled else "off"
	curve_state := "flat" if app.flat_mode else "curved"
	hint := fmt.tprintf(
		"F1 crt:%s   F2 %s   F3 theme:%s   F12 screenshot   ESC quit",
		crt_state,
		curve_state,
		app.theme.name,
	)
	ui.grid_write(g, 1, y, hint, .Dim, .Bg_Panel)
}

// --- demo content -----------------------------------------------------------

// A hand-placed network and a scripted reveal. Procedural generation is M3;
// this exists purely to drive the engine.
build_demo :: proc(w: ^sim.World) {
	dmz := sim.add_subnet(w, "DMZ", sim.addr(10, 0, 4, 0), 24)
	corp := sim.add_subnet(w, "CORP", sim.addr(10, 0, 9, 0), 24)

	gw := sim.add_host(w, "gw-edge", sim.addr(10, 0, 4, 1), dmz, "Linux 4.15")
	web := sim.add_host(w, "web01", sim.addr(10, 0, 4, 11), dmz, "Linux 4.15")
	jump := sim.add_host(w, "jump01", sim.addr(10, 0, 4, 19), dmz, "Linux 5.4")
	fs := sim.add_host(w, "fs01", sim.addr(10, 0, 9, 10), corp, "Windows Server 2016")

	sim.add_service(w, gw, {port = 22, proto = .TCP, name = "ssh", product = "OpenSSH", version = "7.4"})
	sim.add_service(w, web, {port = 80, proto = .TCP, name = "http", product = "Apache httpd", version = "2.4.29"})
	sim.add_service(w, web, {port = 443, proto = .TCP, name = "https", product = "Apache httpd", version = "2.4.29"})
	sim.add_service(w, jump, {port = 22, proto = .TCP, name = "ssh", product = "OpenSSH", version = "8.2"})
	sim.add_service(w, fs, {port = 445, proto = .TCP, name = "smb", product = "Samba", version = "4.5.9"})

	// The pivot: CORP is unreachable until jump01 is held at root.
	append(&w.links, sim.Link{from = dmz, to = corp, via = jump, min_access = .Root})

	// Scripted reveal. Every line and every discovery is a scheduled timer, so
	// the pacing you see is the sim's tick loop driving it, not a render-side
	// animation.
	t := sim.seconds(0.4)
	step :: proc(t: ^sim.Tick, by: f64) -> sim.Tick {
		t^ += sim.seconds(by)
		return t^
	}

	sim.log_at(w, t, "ceph.sec bootstrap", .Info)
	sim.log_at(w, step(&t, 0.5), "  arena ....... ok", .Info)
	sim.log_at(w, step(&t, 0.25), "  scheduler ... ok  60 Hz fixed", .Info)
	sim.log_at(w, step(&t, 0.25), "  prng ........ ok  pcg32", .Info)
	sim.log_at(w, step(&t, 0.25), "  display ..... ok  crt composite", .Info)
	sim.log_at(w, step(&t, 0.6), "", .Info)
	sim.log_at(w, step(&t, 0.2), "operator@ceph:~$ nmap -sV 10.0.4.0/24", .Cmd)
	sim.log_at(w, step(&t, 0.9), "Starting Nmap 7.94 ( simulated )", .Plain)

	reveal(w, &t, gw, {0})
	reveal(w, &t, web, {0, 1})
	reveal(w, &t, jump, {0})

	sim.log_at(w, step(&t, 0.8), "Nmap done: 254 addresses, 3 hosts up", .Plain)
	sim.log_at(w, step(&t, 0.9), "", .Plain)
	sim.log_at(w, step(&t, 0.1), "operator@ceph:~$ ssh operator@10.0.4.19", .Cmd)
	sim.log_at(w, step(&t, 1.1), "  key accepted -- shell on jump01", .Good)

	sim.schedule(w, step(&t, 0.3), sim.Act_Grant_Access{host = jump, level = .Root})
	sim.log_at(w, step(&t, 0.9), "  route to CORP now viable via jump01", .Warn)
	sim.log_at(w, step(&t, 1.2), "", .Plain)
	sim.log_at(w, step(&t, 0.1), "-- milestone 0: engine foundation --", .Info)
	sim.log_at(w, step(&t, 0.4), "sim, scheduler, events and crt pipeline are live.", .Info)
	sim.log_at(w, step(&t, 0.3), "no command input yet -- that is milestone 1.", .Info)
}

// Schedules the discovery itself. The world stays undiscovered until the tick
// arrives, so the session panel and the terminal always agree about what is
// known -- which is exactly what scheduling actions instead of events buys.
@(private)
reveal :: proc(w: ^sim.World, t: ^sim.Tick, h: sim.Handle(sim.Host), service_indices: []int) {
	t^ += sim.seconds(0.7)
	sim.schedule(w, t^, sim.Act_Discover_Host{host = h})

	for idx in service_indices {
		t^ += sim.seconds(0.35)
		sim.schedule(w, t^, sim.Act_Discover_Service{host = h, index = idx})
	}
}
