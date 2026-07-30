package tests

import "core:strings"
import "core:testing"
import "../src/input"
import "../src/shell"
import "../src/sim"

// --- lexer ------------------------------------------------------------------

@(test)
test_lex_basic :: proc(t: ^testing.T) {
	toks, err := lex_ok(t, "nmap -sV 10.0.4.0/24")
	testing.expect_value(t, err, shell.Lex_Error.None)
	testing.expect_value(t, len(toks), 3)
	testing.expect_value(t, toks[0], "nmap")
	testing.expect_value(t, toks[1], "-sV")
	testing.expect_value(t, toks[2], "10.0.4.0/24")
}

@(test)
test_lex_collapses_whitespace :: proc(t: ^testing.T) {
	toks, _ := lex_ok(t, "   ls    -l   /etc   ")
	testing.expect_value(t, len(toks), 3)
	testing.expect_value(t, toks[0], "ls")
	testing.expect_value(t, toks[2], "/etc")
}

@(test)
test_lex_empty_input :: proc(t: ^testing.T) {
	toks, err := lex_ok(t, "     ")
	testing.expect_value(t, err, shell.Lex_Error.None)
	testing.expect_value(t, len(toks), 0)
}

@(test)
test_lex_quotes_group_spaces :: proc(t: ^testing.T) {
	toks, _ := lex_ok(t, `cat "/home/svc/my file.txt"`)
	testing.expect_value(t, len(toks), 2)
	testing.expect_value(t, toks[1], "/home/svc/my file.txt")

	single, _ := lex_ok(t, `echo 'a b c'`)
	testing.expect_value(t, len(single), 2)
	testing.expect_value(t, single[1], "a b c")
}

// An empty quoted string is a real, distinct argument -- it must not vanish.
@(test)
test_lex_empty_quoted_token_survives :: proc(t: ^testing.T) {
	toks, _ := lex_ok(t, `ssh "" host`)
	testing.expect_value(t, len(toks), 3)
	testing.expect_value(t, toks[1], "")
}

@(test)
test_lex_escapes :: proc(t: ^testing.T) {
	toks, _ := lex_ok(t, `cat my\ file`)
	testing.expect_value(t, len(toks), 2)
	testing.expect_value(t, toks[1], "my file")

	// Backslash is literal inside single quotes.
	lit, _ := lex_ok(t, `echo 'a\b'`)
	testing.expect_value(t, lit[1], `a\b`)
}

@(test)
test_lex_unterminated_quote_is_an_error :: proc(t: ^testing.T) {
	_, err := shell.lex(`cat "unfinished`, context.temp_allocator)
	testing.expect_value(t, err, shell.Lex_Error.Unterminated_Quote)
}

@(private)
lex_ok :: proc(t: ^testing.T, src: string) -> ([]string, shell.Lex_Error) {
	toks, err := shell.lex(src, context.temp_allocator)
	testing.expectf(t, err == .None, "lex(%q) errored: %v", src, err)
	return toks, err
}

// --- parser -----------------------------------------------------------------

@(test)
test_parse_separates_flags_and_positionals :: proc(t: ^testing.T) {
	toks, _ := shell.lex("nmap -sV 10.0.4.0/24", context.temp_allocator)
	cmd, err := shell.parse(toks, nil, context.temp_allocator)

	testing.expect_value(t, err, shell.Parse_Error.None)
	testing.expect_value(t, cmd.name, "nmap")
	testing.expect_value(t, len(cmd.positionals), 1)
	testing.expect_value(t, cmd.positionals[0], "10.0.4.0/24")
	testing.expect(t, shell.has_flag(&cmd, "sV"), "-sV should be present")
	testing.expect(t, !shell.has_flag(&cmd, "sn"), "-sn should not be present")
}

// nmap reads `-sV` as one flag named "sV", not as bundled `-s -V`. Getting this
// wrong would silently turn a version scan into something else.
@(test)
test_parse_does_not_bundle_short_flags :: proc(t: ^testing.T) {
	toks, _ := shell.lex("nmap -sV target", context.temp_allocator)
	cmd, _ := shell.parse(toks, nil, context.temp_allocator)

	testing.expect_value(t, len(cmd.flags), 1)
	testing.expect_value(t, cmd.flags[0].name, "sV")
	testing.expect(t, !shell.has_flag(&cmd, "s"), "must not split -sV into -s")
}

@(test)
test_parse_short_flag_with_value :: proc(t: ^testing.T) {
	toks, _ := shell.lex("ssh -p 2222 svc@web01", context.temp_allocator)
	cmd, err := shell.parse(toks, {"p"}, context.temp_allocator)

	testing.expect_value(t, err, shell.Parse_Error.None)
	port, has := shell.flag_value(&cmd, "p")
	testing.expect(t, has)
	testing.expect_value(t, port, "2222")
	// The value must not also land as a positional.
	testing.expect_value(t, len(cmd.positionals), 1)
	testing.expect_value(t, cmd.positionals[0], "svc@web01")
}

@(test)
test_parse_missing_flag_value_is_an_error :: proc(t: ^testing.T) {
	toks, _ := shell.lex("ssh -p", context.temp_allocator)
	_, err := shell.parse(toks, {"p"}, context.temp_allocator)
	testing.expect_value(t, err, shell.Parse_Error.Missing_Flag_Value)
}

@(test)
test_parse_long_flags :: proc(t: ^testing.T) {
	toks, _ := shell.lex("nmap --script=default --open target", context.temp_allocator)
	cmd, _ := shell.parse(toks, nil, context.temp_allocator)

	v, has := shell.flag_value(&cmd, "script")
	testing.expect(t, has)
	testing.expect_value(t, v, "default")
	testing.expect(t, shell.has_flag(&cmd, "open"))
	testing.expect_value(t, len(cmd.positionals), 1)
}

// Flags are positional-order-independent, as they are in every real tool.
@(test)
test_parse_flags_after_positionals :: proc(t: ^testing.T) {
	toks, _ := shell.lex("ls /etc -l", context.temp_allocator)
	cmd, _ := shell.parse(toks, nil, context.temp_allocator)
	testing.expect(t, shell.has_flag(&cmd, "l"))
	testing.expect_value(t, cmd.positionals[0], "/etc")
}

// --- line editor ------------------------------------------------------------

@(test)
test_line_insert_and_cursor :: proc(t: ^testing.T) {
	l: shell.Line
	shell.line_init(&l)
	defer shell.line_destroy(&l)

	for ch in "nmap" {
		shell.line_insert(&l, ch)
	}
	testing.expect_value(t, shell.line_text(&l, context.temp_allocator), "nmap")
	testing.expect_value(t, l.cursor, 4)

	// Insert in the middle: cursor arithmetic must be positional, not append-only.
	shell.line_left(&l)
	shell.line_insert(&l, 'X')
	testing.expect_value(t, shell.line_text(&l, context.temp_allocator), "nmaXp")
	testing.expect_value(t, l.cursor, 4)
}

@(test)
test_line_boundaries_are_safe :: proc(t: ^testing.T) {
	l: shell.Line
	shell.line_init(&l)
	defer shell.line_destroy(&l)

	// Backspace and Left on an empty line must be no-ops, not underflows.
	shell.line_backspace(&l)
	shell.line_left(&l)
	shell.line_delete(&l)
	testing.expect_value(t, l.cursor, 0)
	testing.expect_value(t, shell.line_text(&l, context.temp_allocator), "")

	shell.line_insert(&l, 'a')
	shell.line_right(&l)
	shell.line_right(&l)
	testing.expect_value(t, l.cursor, 1)
	shell.line_delete(&l) // at end: nothing to delete
	testing.expect_value(t, shell.line_text(&l, context.temp_allocator), "a")
}

@(test)
test_line_control_chars_are_rejected :: proc(t: ^testing.T) {
	l: shell.Line
	shell.line_init(&l)
	defer shell.line_destroy(&l)

	shell.line_insert(&l, 'a')
	shell.line_insert(&l, '\n')
	shell.line_insert(&l, rune(3)) // ^C as a codepoint
	shell.line_insert(&l, 'b')
	testing.expect_value(t, shell.line_text(&l, context.temp_allocator), "ab")
}

@(test)
test_line_kill_operations :: proc(t: ^testing.T) {
	l: shell.Line
	shell.line_init(&l)
	defer shell.line_destroy(&l)

	shell.line_set(&l, "nmap -sV target")
	shell.line_home(&l)
	shell.line_right(&l)
	shell.line_right(&l)
	shell.line_right(&l)
	shell.line_right(&l)
	shell.line_kill_to_end(&l)
	testing.expect_value(t, shell.line_text(&l, context.temp_allocator), "nmap")

	shell.line_set(&l, "nmap -sV target")
	shell.line_kill_to_start(&l)
	testing.expect_value(t, shell.line_text(&l, context.temp_allocator), "")
	testing.expect_value(t, l.cursor, 0)
}

// ^W must skip the trailing space before deciding what the "previous word" is,
// or it does nothing at exactly the moment you want it.
@(test)
test_line_kill_word_skips_trailing_space :: proc(t: ^testing.T) {
	l: shell.Line
	shell.line_init(&l)
	defer shell.line_destroy(&l)

	shell.line_set(&l, "nmap -sV ")
	shell.line_kill_word(&l)
	testing.expect_value(t, shell.line_text(&l, context.temp_allocator), "nmap ")

	shell.line_kill_word(&l)
	testing.expect_value(t, shell.line_text(&l, context.temp_allocator), "")
}

@(test)
test_line_history_walks_and_restores :: proc(t: ^testing.T) {
	l: shell.Line
	shell.line_init(&l)
	defer shell.line_destroy(&l)

	shell.line_history_push(&l, "first")
	shell.line_history_push(&l, "second")

	// A half-typed line must survive a trip into history and back.
	shell.line_set(&l, "in progress")
	shell.line_history_prev(&l)
	testing.expect_value(t, shell.line_text(&l, context.temp_allocator), "second")
	shell.line_history_prev(&l)
	testing.expect_value(t, shell.line_text(&l, context.temp_allocator), "first")

	// Past the oldest entry: stay put rather than wrap.
	shell.line_history_prev(&l)
	testing.expect_value(t, shell.line_text(&l, context.temp_allocator), "first")

	shell.line_history_next(&l)
	testing.expect_value(t, shell.line_text(&l, context.temp_allocator), "second")
	shell.line_history_next(&l)
	testing.expect_value(t, shell.line_text(&l, context.temp_allocator), "in progress")
}

@(test)
test_line_history_skips_blanks_and_repeats :: proc(t: ^testing.T) {
	l: shell.Line
	shell.line_init(&l)
	defer shell.line_destroy(&l)

	shell.line_history_push(&l, "ls")
	shell.line_history_push(&l, "ls")
	shell.line_history_push(&l, "   ")
	shell.line_history_push(&l, "")
	testing.expect_value(t, len(l.history), 1)
}

// --- path resolution --------------------------------------------------------

@(test)
test_resolve_path :: proc(t: ^testing.T) {
	Case :: struct {
		cwd, path, want: string,
	}
	cases := []Case {
		{"/home/svc", "deploy.env", "/home/svc/deploy.env"},
		{"/home/svc", "/etc/passwd", "/etc/passwd"},
		{"/home/svc", "..", "/home"},
		{"/home/svc", "../..", "/"},
		{"/home/svc", "./x", "/home/svc/x"},
		{"/home/svc", "", "/home/svc"},
		{"/", "etc", "/etc"},
		// `..` at the root stays at the root rather than escaping it.
		{"/", "..", "/"},
		{"/", "../../..", "/"},
		// A leading slash makes a path absolute no matter how many follow, so
		// this resolves against the root and not against cwd.
		{"/etc", "//nginx//", "/nginx"},
		// The relative form is where redundant separators collapse into cwd.
		{"/etc", "nginx//", "/etc/nginx"},
		{"/etc", "nginx//sites//default", "/etc/nginx/sites/default"},
		{"/etc/nginx", "../apache2/apache2.conf", "/etc/apache2/apache2.conf"},
		{"/home/svc", "a/./b/../c", "/home/svc/a/c"},
	}

	for c in cases {
		got := shell.resolve_path(c.cwd, c.path, context.temp_allocator)
		testing.expectf(t, got == c.want, "resolve(%q, %q) = %q, want %q", c.cwd, c.path, got, c.want)
	}
}

// --- vfs listing ------------------------------------------------------------

@(test)
test_list_dir_returns_direct_children_only :: proc(t: ^testing.T) {
	w: sim.World
	sim.world_init(&w, 1)
	defer sim.world_destroy(&w)

	sn := sim.add_subnet(&w, "S", sim.addr(10, 0, 0, 0), 24)
	h := sim.add_host(&w, "box", sim.addr(10, 0, 0, 1), sn)
	sim.add_file(&w, h, {path = "/etc/passwd", content = "x"})
	sim.add_file(&w, h, {path = "/etc/nginx/nginx.conf", content = "x"})
	sim.add_file(&w, h, {path = "/etc/nginx/sites/default", content = "x"})
	sim.add_file(&w, h, {path = "/home/svc/.env", content = "x"})

	host, _ := sim.pool_get(&w.hosts, h)

	etc := shell.list_dir(host, "/etc", context.temp_allocator)
	testing.expect_value(t, len(etc), 2)
	// Directories sort first, so nginx/ precedes passwd.
	testing.expect_value(t, etc[0].name, "nginx")
	testing.expect(t, etc[0].is_dir, "nginx should be a directory")
	testing.expect_value(t, etc[1].name, "passwd")
	testing.expect(t, !etc[1].is_dir)

	// The deeper file contributes a `sites/` entry here, not its own name.
	nginx := shell.list_dir(host, "/etc/nginx", context.temp_allocator)
	testing.expect_value(t, len(nginx), 2)
	testing.expect_value(t, nginx[0].name, "sites")
	testing.expect(t, nginx[0].is_dir)

	root := shell.list_dir(host, "/", context.temp_allocator)
	testing.expect_value(t, len(root), 2) // etc/ and home/
}

// A prefix match on "/etc" must not also match "/etcetera".
@(test)
test_list_dir_does_not_match_partial_names :: proc(t: ^testing.T) {
	w: sim.World
	sim.world_init(&w, 1)
	defer sim.world_destroy(&w)

	sn := sim.add_subnet(&w, "S", sim.addr(10, 0, 0, 0), 24)
	h := sim.add_host(&w, "box", sim.addr(10, 0, 0, 1), sn)
	sim.add_file(&w, h, {path = "/etc/passwd", content = "x"})
	sim.add_file(&w, h, {path = "/etcetera/other", content = "x"})

	host, _ := sim.pool_get(&w.hosts, h)
	etc := shell.list_dir(host, "/etc", context.temp_allocator)
	testing.expect_value(t, len(etc), 1)
	testing.expect_value(t, etc[0].name, "passwd")

	testing.expect(t, shell.dir_exists(host, "/etc"))
	testing.expect(t, !shell.dir_exists(host, "/et"))
	testing.expect(t, !shell.dir_exists(host, "/nope"))
}

// --- address parsing --------------------------------------------------------

@(test)
test_addr_parse_accepts_valid :: proc(t: ^testing.T) {
	a, ok := sim.addr_parse("10.0.4.19")
	testing.expect(t, ok)
	testing.expect_value(t, a, sim.addr(10, 0, 4, 19))

	z, z_ok := sim.addr_parse("0.0.0.0")
	testing.expect(t, z_ok)
	testing.expect_value(t, z, sim.addr(0, 0, 0, 0))

	m, m_ok := sim.addr_parse("255.255.255.255")
	testing.expect(t, m_ok)
	testing.expect_value(t, m, sim.addr(255, 255, 255, 255))
}

// Being liberal here would mean `nmap 10.0.4` silently scanning something the
// player did not name.
@(test)
test_addr_parse_rejects_malformed :: proc(t: ^testing.T) {
	bad := []string {
		"10.0.4",          // too few octets
		"10.0.4.19.7",     // too many
		"10.0.4.256",      // octet out of range
		"10.0.4.",         // trailing dot
		".10.0.4.1",       // leading dot
		"10.0..1",         // empty octet
		"10.0.4.19 ",      // trailing space
		"web01",           // a hostname
		"",                // empty
		"10.0.4.-1",       // negative
	}
	for s in bad {
		_, ok := sim.addr_parse(s)
		testing.expectf(t, !ok, "addr_parse(%q) should have failed", s)
	}
}

@(test)
test_cidr_parse :: proc(t: ^testing.T) {
	base, bits, ok := sim.cidr_parse("10.0.4.0/24")
	testing.expect(t, ok)
	testing.expect_value(t, base, sim.addr(10, 0, 4, 0))
	testing.expect_value(t, bits, u8(24))

	// A bare address is a /32, so one entry point takes a host or a range.
	_, host_bits, host_ok := sim.cidr_parse("10.0.4.19")
	testing.expect(t, host_ok)
	testing.expect_value(t, host_bits, u8(32))

	bad := []string{"10.0.4.0/33", "10.0.4.0/", "10.0.4.0/abc", "10.0.4.0/241"}
	for s in bad {
		_, _, bad_ok := sim.cidr_parse(s)
		testing.expectf(t, !bad_ok, "cidr_parse(%q) should have failed", s)
	}
}

// --- the mini-loop world ----------------------------------------------------

// A compact stand-in for the shipped scenario: VPS -> DMZ (web01 leaks a
// password reused on jump01) -> CORP (objective). Built here rather than
// imported so the tests describe exactly what they depend on.
Fixture :: struct {
	w:                     sim.World,
	sess:                  shell.Session,
	origin, web, jump, fs: sim.Handle(sim.Host),
	dmz, corp:             sim.Handle(sim.Subnet),
}

PASSWORD :: "Nw-deploy-2019!"

@(private)
fixture :: proc(f: ^Fixture) {
	sim.world_init(&f.w, 0xCEF5EC)

	wan := sim.add_subnet(&f.w, "WAN", sim.addr(198, 51, 100, 0), 24, .None)
	dmz := sim.add_subnet(&f.w, "DMZ", sim.addr(10, 0, 4, 0), 24, .Low)
	f.dmz = dmz
	f.corp = sim.add_subnet(&f.w, "CORP", sim.addr(10, 0, 9, 0), 24, .Medium)

	f.origin = sim.add_host(&f.w, "ceph", sim.addr(198, 51, 100, 7), wan, "Debian 12")
	sim.grant_access(&f.w, f.origin, .Root)
	f.w.origin = f.origin

	f.web = sim.add_host(&f.w, "web01", sim.addr(10, 0, 4, 11), dmz, "Ubuntu 18.04")
	sim.add_service(&f.w, f.web, {port = 80, name = "http", product = "Apache httpd", version = "2.4.29"})
	sim.add_account(&f.w, f.web, {username = "svc", password = PASSWORD})
	// The entry point: an .env exposed in the document root, named by a
	// leftover comment on the index page. No credential needed to reach it,
	// which is what makes the whole chain start from nothing.
	sim.add_file(
		&f.w,
		f.web,
		{path = "/var/www/html/index.html", content = "<h1>Northwind</h1>\n<!-- TODO(deploy): stop shipping .env into the web root -->"},
	)
	sim.add_file(
		&f.w,
		f.web,
		{path = "/var/www/html/.env", content = "DEPLOY_USER=svc\nDEPLOY_PASS=" + PASSWORD, sensitive = true},
		{{username = "svc", password = PASSWORD}},
	)
	sim.add_file(
		&f.w,
		f.web,
		{path = "/home/svc/deploy.env", content = "DEPLOY_USER=svc\nDEPLOY_PASS=" + PASSWORD, sensitive = true},
		{{username = "svc", password = PASSWORD}},
	)

	f.jump = sim.add_host(&f.w, "jump01", sim.addr(10, 0, 4, 19), dmz, "Ubuntu 20.04")
	sim.add_service(&f.w, f.jump, {port = 22, name = "ssh", product = "OpenSSH", version = "8.2p1"})
	sim.add_account(&f.w, f.jump, {username = "svc", password = PASSWORD, is_admin = true})

	f.fs = sim.add_host(&f.w, "fs01", sim.addr(10, 0, 9, 10), f.corp, "Windows Server 2016")
	sim.add_account(&f.w, f.fs, {username = "svc", password = PASSWORD})
	sim.add_file(
		&f.w,
		f.fs,
		{path = "/srv/backup/manifest.sql", content = "-- objective", sensitive = true, objective = true},
	)

	append(&f.w.links, sim.Link{from = wan, to = dmz, via = f.origin, min_access = .User})
	append(&f.w.links, sim.Link{from = dmz, to = f.corp, via = f.jump, min_access = .Root})

	shell.session_init(&f.sess, &f.w, f.origin, "operator")
}

@(private)
fixture_destroy :: proc(f: ^Fixture) {
	sim.world_destroy(&f.w)
}

// Runs a command and advances the clock until the shell is idle again, applying
// deferred session effects the way the real frame loop does.
@(private)
run :: proc(f: ^Fixture, line: string, max_ticks := 3000) {
	shell.session_exec(&f.sess, line)
	for _ in 0 ..< max_ticks {
		if !shell.session_busy(&f.sess) {
			break
		}
		sim.tick(&f.w)
		shell.session_update(&f.sess)
	}
	shell.session_update(&f.sess)
}

// Advances until nothing is running and nothing is queued, or the budget runs
// out. Unlike `run` this starts no command -- it lets background work finish.
@(private)
settle :: proc(f: ^Fixture, max_ticks := 3000) {
	for _ in 0 ..< max_ticks {
		if !shell.session_active(&f.sess) && len(f.w.timers) == 0 {
			return
		}
		sim.tick(&f.w)
		shell.session_update(&f.sess)
	}
}

// Drains the event ring into one string so tests can assert on what the player
// would actually have seen.
@(private)
transcript :: proc(f: ^Fixture) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for {
		e, ok := sim.ring_pop(&f.w.events)
		if !ok {
			break
		}
		if log, is_log := e.(sim.Ev_Log); is_log {
			strings.write_string(&sb, log.text)
			strings.write_byte(&sb, '\n')
		}
	}
	return strings.to_string(sb)
}

// --- nmap -------------------------------------------------------------------

@(test)
test_nmap_finds_reachable_hosts :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	run(&f, "nmap -sV 10.0.4.0/24")
	text := transcript(&f)

	testing.expect(t, strings.contains(text, "10.0.4.11"), "web01 should appear in the scan")
	testing.expect(t, strings.contains(text, "10.0.4.19"), "jump01 should appear in the scan")

	web, _ := sim.pool_get(&f.w.hosts, f.web)
	testing.expect(t, web.discovered, "scanning should mark the host discovered")
	testing.expect(t, web.services[0].discovered, "-sV should reveal the service")
}

// Segmentation is the map. A scan that ignored it would erase the game.
@(test)
test_nmap_cannot_see_unreachable_segments :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	testing.expect(t, !sim.subnet_reachable(&f.w, f.corp), "CORP must start unreachable")

	run(&f, "nmap -sV 10.0.9.0/24")
	text := transcript(&f)

	testing.expect(t, !strings.contains(text, "10.0.9.10"), "fs01 must not be visible without the pivot")
	testing.expect(t, strings.contains(text, "0 hosts up"), "scan should report nothing found")

	fs, _ := sim.pool_get(&f.w.hosts, f.fs)
	testing.expect(t, !fs.discovered, "unreachable host must not be marked discovered")
}

// -sV is the louder scan and the only one that learns versions; everything that
// keys on a version therefore depends on having paid for it.
@(test)
test_nmap_without_sv_does_not_learn_versions :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	run(&f, "nmap 10.0.4.0/24")

	web, _ := sim.pool_get(&f.w.hosts, f.web)
	testing.expect(t, web.discovered, "a plain scan still finds the host")
	testing.expect(t, !web.services[0].discovered, "a plain scan must not reveal service versions")
}

// Regression: the summary was scheduled from an up-front duration estimate
// while the per-host output advanced its own cursor, so "Nmap done" printed
// before the last host's ports. The prompt also came back early, mid-scan.
@(test)
test_nmap_summary_is_the_last_line :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	run(&f, "nmap -sV 10.0.4.0/24")
	text := transcript(&f)

	lines := strings.split_lines(text, context.temp_allocator)
	last := ""
	for l in lines {
		if len(strings.trim_space(l)) > 0 {
			last = l
		}
	}
	testing.expectf(t, strings.contains(last, "Nmap done"), "last line was %q, expected the summary", last)

	// And the terminal must stay held until everything has printed.
	done_at := strings.index(text, "Nmap done")
	final_port := strings.last_index(text, "8.2p1")
	testing.expect(t, done_at > final_port, "summary printed before the last service line")
}

@(test)
test_nmap_holds_the_prompt_until_output_finishes :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	shell.session_exec(&f.sess, "nmap -sV 10.0.4.0/24")

	// Step until the shell frees up, then confirm nothing is still queued to
	// print. A prompt that returns with timers outstanding is the bug.
	for _ in 0 ..< 3000 {
		if !shell.session_busy(&f.sess) {
			break
		}
		sim.tick(&f.w)
	}
	testing.expect(t, !shell.session_busy(&f.sess), "scan should have finished")
	testing.expect_value(t, len(f.w.timers), 0)
}

@(test)
test_nmap_rejects_bad_target :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	run(&f, "nmap not-an-address")
	testing.expect(t, strings.contains(transcript(&f), "failed to resolve"))
}

// --- curl -------------------------------------------------------------------

// The run's entry point: a credential obtained with no prior access at all.
@(test)
test_curl_serves_webroot_and_harvests :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	testing.expect_value(t, len(f.w.keyring), 0)

	run(&f, "curl http://10.0.4.11/")
	testing.expect(t, strings.contains(transcript(&f), "Northwind"), "/ should serve the index")

	run(&f, "curl http://10.0.4.11/.env")
	testing.expect(t, strings.contains(transcript(&f), "DEPLOY_PASS"))
	testing.expect_value(t, len(f.w.keyring), 1)

	// Provenance defaults to where it was found, which is what makes a keyring
	// of a dozen entries usable.
	testing.expect(t, strings.contains(f.w.keyring[0].note, "web01"), "note should record the source host")
}

@(test)
test_curl_url_forms :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	// Scheme and port are accepted and ignored; rejecting them would make
	// every URL a player naturally types wrong.
	forms := []string{"http://10.0.4.11/.env", "https://10.0.4.11/.env", "10.0.4.11/.env", "http://10.0.4.11:80/.env"}
	for form in forms {
		run(&f, strings.concatenate({"curl ", form}, context.temp_allocator))
		testing.expectf(t, strings.contains(transcript(&f), "DEPLOY_PASS"), "curl %s should have served the file", form)
	}
}

@(test)
test_curl_404_and_unreachable :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	run(&f, "curl http://10.0.4.11/nope")
	testing.expect(t, strings.contains(transcript(&f), "404"))

	// A path outside the document root is not reachable over http, even though
	// the file exists on the box.
	run(&f, "curl http://10.0.4.11/../../home/svc/deploy.env")
	testing.expect(t, strings.contains(transcript(&f), "404"), "webroot must not be escapable")

	run(&f, "curl http://10.0.9.10/")
	testing.expect(t, strings.contains(transcript(&f), "No route to host"))
}

// Reaching a host is not the same as it running a web server.
@(test)
test_curl_refuses_host_without_http :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	run(&f, "nmap -sn 10.0.4.0/24")
	transcript(&f)

	run(&f, "curl http://10.0.4.19/")
	testing.expect(t, strings.contains(transcript(&f), "Connection refused"))
}

// --- ssh --------------------------------------------------------------------

@(test)
test_ssh_denied_without_credential :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	run(&f, "nmap -sn 10.0.4.0/24")
	transcript(&f)

	run(&f, "ssh svc@10.0.4.19")
	testing.expect(t, strings.contains(transcript(&f), "Permission denied"))

	jump, _ := sim.pool_get(&f.w.hosts, f.jump)
	testing.expect_value(t, jump.access, sim.Access.None)
	testing.expect_value(t, f.sess.host, f.origin) // must not have moved
}

@(test)
test_ssh_refuses_unreachable_host :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	// Hold the credential, so the only thing standing in the way is routing.
	sim.keyring_add(&f.w, {username = "svc", password = PASSWORD, note = "test"})

	run(&f, "ssh svc@10.0.9.10")
	testing.expect(t, strings.contains(transcript(&f), "No route to host"))
	testing.expect_value(t, f.sess.host, f.origin)
}

@(test)
test_ssh_succeeds_with_reused_credential :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	// Harvested from web01, but never entered against jump01 before.
	sim.keyring_add(&f.w, {username = "svc", password = PASSWORD, note = "web01:/home/svc/deploy.env"})

	run(&f, "ssh svc@10.0.4.19")
	testing.expect(t, strings.contains(transcript(&f), "authenticated"))

	jump, _ := sim.pool_get(&f.w.hosts, f.jump)
	// svc is an admin on jump01, so the foothold is root -- which is what opens
	// the pivot into CORP.
	testing.expect_value(t, jump.access, sim.Access.Root)
	testing.expect_value(t, f.sess.host, f.jump)
	testing.expect_value(t, f.sess.user, "svc")
	testing.expect(t, sim.subnet_reachable(&f.w, f.corp), "root on jump01 should open CORP")
}

@(test)
test_ssh_rejects_malformed_target :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	run(&f, "ssh jump01")
	testing.expect(t, strings.contains(transcript(&f), "user@host"))

	run(&f, "ssh svc@nosuchbox")
	testing.expect(t, strings.contains(transcript(&f), "Could not resolve"))
}

// --- cat and credentials ----------------------------------------------------

@(test)
test_cat_harvests_credentials_once :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	sim.keyring_add(&f.w, {username = "svc", password = PASSWORD, note = "seed"})
	run(&f, "nmap -sn 10.0.4.0/24")
	run(&f, "ssh svc@10.0.4.11")
	transcript(&f)

	before := len(f.w.keyring)
	run(&f, "cat /home/svc/deploy.env")
	run(&f, "cat /home/svc/deploy.env")

	// The credential was already held, so re-reading must not stack duplicates.
	testing.expect_value(t, len(f.w.keyring), before)
}

// Regression: split_lines_iterator advances the string it is handed, and both
// cat and curl were passing a pointer to the stored File.content. Reading a
// file consumed it, so every later read printed nothing at all.
@(test)
test_reading_a_file_twice_is_idempotent :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	run(&f, "curl http://10.0.4.11/.env")
	first := strings.clone(transcript(&f), context.temp_allocator)
	run(&f, "curl http://10.0.4.11/.env")
	second := transcript(&f)

	testing.expect(t, strings.contains(first, "DEPLOY_PASS"), "first read should show content")
	testing.expectf(t, first == second, "second read differed:\nfirst:\n%s\nsecond:\n%s", first, second)

	// Same property through the other path onto the file.
	sim.keyring_add(&f.w, {username = "svc", password = PASSWORD, note = "seed"})
	run(&f, "nmap -sn 10.0.4.0/24")
	run(&f, "ssh svc@10.0.4.11")
	transcript(&f)

	run(&f, "cat /home/svc/deploy.env")
	cat_first := strings.clone(transcript(&f), context.temp_allocator)
	run(&f, "cat /home/svc/deploy.env")
	cat_second := transcript(&f)

	testing.expect(t, strings.contains(cat_first, "DEPLOY_PASS"))
	testing.expect_value(t, cat_first, cat_second)
}

@(test)
test_cat_reports_missing_and_directories :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	run(&f, "cat /nope")
	testing.expect(t, strings.contains(transcript(&f), "No such file or directory"))

	run(&f, "cat /root")
	// /root holds nothing on the fixture origin, so it is genuinely absent.
	testing.expect(t, strings.contains(transcript(&f), "No such file"))
}

@(test)
test_unknown_command :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	run(&f, "sudo rm -rf /")
	testing.expect(t, strings.contains(transcript(&f), "command not found"))
}

// --- interruption -----------------------------------------------------------

// ^C must take back the output the tool had already queued, and must not leave
// a half-finished ssh still landing you on the target.
@(test)
test_interrupt_cancels_pending_work :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	sim.keyring_add(&f.w, {username = "svc", password = PASSWORD, note = "seed"})
	run(&f, "nmap -sn 10.0.4.0/24")
	transcript(&f)

	shell.session_exec(&f.sess, "ssh svc@10.0.4.19")
	testing.expect(t, shell.session_busy(&f.sess), "ssh should hold the terminal")
	testing.expect(t, len(f.w.timers) > 0, "ssh should have queued output")

	sim.tick_n(&f.w, 30) // half a second in
	shell.session_interrupt(&f.sess)

	testing.expect(t, !shell.session_busy(&f.sess), "^C should free the terminal")
	testing.expect_value(t, len(f.w.timers), 0)

	// Let the clock run well past when the login would have completed.
	sim.tick_n(&f.w, 300)
	shell.session_update(&f.sess)

	jump, _ := sim.pool_get(&f.w.hosts, f.jump)
	testing.expect_value(t, jump.access, sim.Access.None)
	testing.expect_value(t, f.sess.host, f.origin)
	testing.expect(t, strings.contains(transcript(&f), "interrupted"))
}

@(test)
test_commands_take_time :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	shell.session_exec(&f.sess, "nmap -sV 10.0.4.0/24")
	testing.expect(t, shell.session_busy(&f.sess), "a scan must not resolve instantly")

	sim.tick_n(&f.w, 30)
	testing.expect(t, shell.session_busy(&f.sess), "still scanning half a second in")

	// Builtins are free: they happen on a box you already hold.
	sim.tick_n(&f.w, 3000)
	shell.session_update(&f.sess)
	shell.session_exec(&f.sess, "pwd")
	testing.expect(t, !shell.session_busy(&f.sess), "builtins must not consume time")
}

// --- help -------------------------------------------------------------------

// help is generated from the registry, so it cannot document a flag that does
// not exist -- but it can outgrow the pane, which is how the summaries ended up
// clipped mid-word. The terminal pane is 62 cells wide.
HELP_WIDTH :: 62

@(test)
test_help_fits_the_pane :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	run(&f, "help")
	for line in strings.split_lines(transcript(&f), context.temp_allocator) {
		testing.expectf(
			t,
			len(line) <= HELP_WIDTH,
			"help line is %d cells, over the %d-cell pane: %q",
			len(line),
			HELP_WIDTH,
			line,
		)
	}
}

// Every command in the table must be reachable and self-describing; a spec with
// no run proc would crash on dispatch.
@(test)
test_every_registered_command_is_dispatchable :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	for spec in shell.COMMANDS {
		found, ok := shell.lookup(spec.name)
		testing.expectf(t, ok, "%s is in the table but does not resolve", spec.name)
		testing.expectf(t, found.run != nil, "%s has no run proc", spec.name)
		testing.expectf(t, len(found.summary) > 0, "%s has no summary", spec.name)
		testing.expectf(t, strings.has_prefix(found.usage, spec.name), "%s usage should start with its name", spec.name)

		// `help <name>` must explain it rather than report it missing.
		run(&f, strings.concatenate({"help ", spec.name}, context.temp_allocator))
		text := transcript(&f)
		testing.expectf(t, !strings.contains(text, "no such command"), "help %s failed", spec.name)
	}
}

// --- keystroke path ---------------------------------------------------------

@(private)
type_text :: proc(s: ^shell.Session, text: string) {
	for ch in text {
		shell.session_input(s, input.Rune_Typed{ch = ch})
	}
}

@(private)
press :: proc(s: ^shell.Session, key: input.Key) -> bool {
	return shell.session_input(s, input.Key_Pressed{key = key})
}

// Everything above drives the shell through session_exec. This covers the path
// the player actually uses: characters and keys arriving one at a time.
@(test)
test_typing_submits_a_command :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	type_text(&f.sess, "whoami")
	testing.expect_value(t, shell.line_text(&f.sess.line, context.temp_allocator), "whoami")

	submitted := press(&f.sess, .Enter)
	testing.expect(t, submitted, "Enter should submit")
	testing.expect_value(t, shell.line_text(&f.sess.line, context.temp_allocator), "")

	text := transcript(&f)
	testing.expect(t, strings.contains(text, "operator"), "whoami should have run")
	// The command is echoed with its prompt, so the scrollback reads as a
	// session transcript rather than as bare output.
	testing.expect(t, strings.contains(text, "operator@ceph"), "the prompt should be echoed")
}

@(test)
test_editing_before_submit :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	type_text(&f.sess, "whoamix")
	press(&f.sess, .Backspace)
	press(&f.sess, .Home)
	type_text(&f.sess, " ")
	press(&f.sess, .Backspace) // remove the space we just typed
	press(&f.sess, .End)
	testing.expect_value(t, shell.line_text(&f.sess.line, context.temp_allocator), "whoami")

	press(&f.sess, .Enter)
	testing.expect(t, strings.contains(transcript(&f), "operator"))
}

// The prompt stays live while a foreground job runs: you can type, and builtins
// still work. What is refused is *dispatching a second tool*, and the refusal
// says so rather than silently eating the keystroke.
//
// Replaces M1's test_input_is_ignored_while_busy_except_interrupt, whose
// behaviour backgrounding deliberately removes.
@(test)
test_prompt_stays_live_while_a_job_runs :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	shell.session_exec(&f.sess, "nmap -sV 10.0.4.0/24")
	testing.expect(t, shell.session_busy(&f.sess))
	transcript(&f)

	// Typing is accepted.
	type_text(&f.sess, "whoami")
	testing.expect_value(t, shell.line_text(&f.sess.line, context.temp_allocator), "whoami")

	// And a builtin runs, mid-scan.
	press(&f.sess, .Enter)
	testing.expect(t, strings.contains(transcript(&f), "operator"), "builtins run while a job holds the terminal")
	testing.expect(t, shell.session_busy(&f.sess), "the scan should still be running")

	// A second *tool* is refused, and the message names the way out.
	shell.session_exec(&f.sess, "curl http://10.0.4.11/")
	refusal := transcript(&f)
	testing.expect(t, strings.contains(refusal, "&"), "the refusal should name backgrounding")

	// ^C always lands.
	press(&f.sess, .Ctrl_C)
	testing.expect(t, !shell.session_busy(&f.sess), "^C must free the terminal")
}

@(test)
test_history_recall_through_keys :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	type_text(&f.sess, "whoami")
	press(&f.sess, .Enter)
	type_text(&f.sess, "pwd")
	press(&f.sess, .Enter)

	press(&f.sess, .Up)
	testing.expect_value(t, shell.line_text(&f.sess.line, context.temp_allocator), "pwd")
	press(&f.sess, .Up)
	testing.expect_value(t, shell.line_text(&f.sess.line, context.temp_allocator), "whoami")
	press(&f.sess, .Down)
	testing.expect_value(t, shell.line_text(&f.sess.line, context.temp_allocator), "pwd")
}

// --- the milestone ----------------------------------------------------------

// The M1 acceptance criterion, end to end and headless: recon finds the DMZ,
// a leaked config yields a password, that password is reused on the box that
// bridges into CORP, and only then does the objective become readable.
@(test)
test_mini_loop_end_to_end :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	// 1. The objective is out of reach at the start, in every sense.
	testing.expect(t, !sim.subnet_reachable(&f.w, f.corp), "CORP must start unreachable")
	testing.expect_value(t, len(f.w.keyring), 0)

	// 2. Recon the segment we can reach.
	run(&f, "nmap -sV 10.0.4.0/24")
	scan := transcript(&f)
	testing.expect(t, strings.contains(scan, "10.0.4.11"), "recon should surface web01")

	// 3. The web server is the only thing answering without a credential. Its
	//    index page names a file that should not be in the document root.
	run(&f, "curl http://10.0.4.11/")
	index := transcript(&f)
	testing.expect(t, strings.contains(index, ".env"), "the index should disclose the path")

	// 4. Fetch it. This is where the run's first credential comes from -- with
	//    no prior access to anything.
	run(&f, "curl http://10.0.4.11/.env")
	leak := transcript(&f)
	testing.expect(t, strings.contains(leak, "DEPLOY_PASS"), "the .env should be served")
	testing.expect_value(t, len(f.w.keyring), 1)
	testing.expect_value(t, f.w.keyring[0].username, "svc")

	// 5. Reuse it on the jump box. This is the pivot.
	run(&f, "ssh svc@10.0.4.19")
	testing.expect_value(t, f.sess.host, f.jump)
	jump, _ := sim.pool_get(&f.w.hosts, f.jump)
	testing.expect_value(t, jump.access, sim.Access.Root)

	// 6. CORP is now routable -- and only now.
	testing.expect(t, sim.subnet_reachable(&f.w, f.corp), "the pivot should open CORP")

	run(&f, "nmap -sn 10.0.9.0/24")
	testing.expect(t, strings.contains(transcript(&f), "10.0.9.10"), "fs01 should now be visible")

	// 7. Take the objective.
	run(&f, "ssh svc@10.0.9.10")
	testing.expect_value(t, f.sess.host, f.fs)

	run(&f, "cat /srv/backup/manifest.sql")
	testing.expect(t, strings.contains(transcript(&f), "objective"), "the manifest should be readable")

	fs, _ := sim.pool_get(&f.w.hosts, f.fs)
	file, found := sim.host_file(fs, "/srv/backup/manifest.sql")
	testing.expect(t, found)
	testing.expect(t, file.found, "reading the objective should mark it recovered")
}
