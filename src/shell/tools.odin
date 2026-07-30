package shell

import "core:fmt"
import "core:strings"
import "../sim"

// Tools: the commands that reach across the network.
//
// Unlike builtins these consume sim time, because that is where the game lives.
// Each one claims the terminal with begin_work, streams its output through
// tagged timers, and is interruptible. Once M2 lands, backgrounding these is a
// change to who owns the tag -- not a rewrite of the tools.
//
// Everything they touch is simulated. `nmap` walks an in-memory host list;
// `ssh` compares strings. No socket exists anywhere in this package, and the
// build gate enforces that.

// --- nmap -------------------------------------------------------------------

Scan_Depth :: enum {
	Ping,    // -sn: hosts only
	Ports,   // default: open ports, no version detection
	Version, // -sV: ports and product/version
}

cmd_nmap :: proc(s: ^Session, cmd: ^Command) {
	target, given := positional(cmd, 0)
	if !given {
		out(s, "usage: nmap [-sn|-sV] <host|cidr>", .Bad)
		return
	}

	base, mask, ok := sim.cidr_parse(target)
	if !ok {
		out(s, fmt.tprintf("nmap: failed to resolve \"%s\"", target), .Bad)
		return
	}

	depth := Scan_Depth.Ports
	if has_flag(cmd, "sn") {
		depth = .Ping
	}
	if has_flag(cmd, "sV", "sv") {
		depth = .Version
	}

	// -T2 is the loud-fast/quiet-slow choice in one flag: roughly three and a
	// half times as long for a third of the attention. It is what makes
	// backgrounding a scan worth doing.
	slow := has_flag(cmd, "T2", "t2")

	// Gather targets first so the whole scan can be scheduled up front. Only
	// hosts in segments we can actually reach respond -- segmentation is the
	// map, so a scan that ignored it would erase the game's central constraint.
	probe := sim.Subnet {
		base      = base,
		mask_bits = mask,
	}
	hits := make([dynamic]sim.Handle(sim.Host), 0, 8, context.temp_allocator)
	it: int
	for host, h in sim.pool_iter(&s.world.hosts, &it) {
		if !sim.subnet_contains(&probe, host.address) {
			continue
		}
		if !sim.subnet_reachable(s.world, host.subnet) {
			continue
		}
		append(&hits, h)
	}

	per_host := sim.seconds(depth == .Ping ? 0.45 : (depth == .Ports ? 0.75 : 1.05))
	if slow {
		per_host = scale_time(per_host)
	}

	// Charged once per segment, not once per host: a sweep of a /24 pays for
	// one scan of that segment. Filed for every segment the scan actually
	// reached, so a scan spanning two reachable segments pays in both.
	units := depth == .Ping ? NOISE_NMAP_PING : (depth == .Ports ? NOISE_NMAP_PORTS : NOISE_NMAP_VERSION)
	if slow {
		units = max(units / T2_NOISE_DIV, 1)
	}
	// A scan that reached nothing is free: you have no route, so nothing of
	// theirs saw a packet. There is also no segment to bill.
	for h in hits {
		touched(s, h, units)
	}

	// Provisional: the real end is only known once the per-host output has been
	// laid out below, and is set with work_ends_at afterwards.
	begin_work(s, sim.seconds(1.1) + per_host * sim.Tick(max(len(hits), 1)), "nmap")
	out(s, "Starting Nmap 7.94 ( simulated )", .Plain)

	t := slow ? scale_time(sim.seconds(0.9)) : sim.seconds(0.9)
	for h in hits {
		host, _ := sim.pool_get(&s.world.hosts, h)
		buf: [15]u8
		addr_str := strings.clone(sim.addr_write(buf[:], host.address), context.temp_allocator)

		out_at(s, t, fmt.tprintf("Nmap scan report for %s", addr_str), .Heading)
		act_at(s, t, sim.Act_Discover_Host{host = h})
		t += slow ? scale_time(sim.seconds(0.2)) : sim.seconds(0.2)

		if depth == .Ping {
			out_at(s, t, "Host is up.", .Plain)
			t += per_host - (slow ? scale_time(sim.seconds(0.2)) : sim.seconds(0.2))
			continue
		}

		if len(host.services) == 0 {
			out_at(s, t, "All 1000 scanned ports are closed", .Info)
			t += per_host - (slow ? scale_time(sim.seconds(0.2)) : sim.seconds(0.2))
			continue
		}

		header := depth == .Version ? "PORT     STATE SERVICE  VERSION" : "PORT     STATE SERVICE"
		out_at(s, t, header, .Info)

		step := per_host / sim.Tick(max(len(host.services), 1))
		for svc, idx in host.services {
			t += step
			port_field := fmt.tprintf("%d/%s", svc.port, svc.proto == .TCP ? "tcp" : "udp")
			line :=
				depth == .Version \
				? fmt.tprintf("%-8s open  %-8s %s %s", port_field, svc.name, svc.product, svc.version) \
				: fmt.tprintf("%-8s open  %s", port_field, svc.name)
			out_at(s, t, line, .Data)

			// Only -sV actually learns the product and version. Everything
			// downstream that keys on a version -- searchsploit, exploit
			// matching -- therefore depends on having paid for the louder scan.
			if depth == .Version {
				act_at(s, t, sim.Act_Discover_Service{host = h, index = idx})
			}
		}
		t += slow ? scale_time(sim.seconds(0.15)) : sim.seconds(0.15)
	}

	// The summary must land after the last result, so it is scheduled from the
	// cursor the loop actually reached rather than from the estimate.
	t += slow ? scale_time(sim.seconds(0.25)) : sim.seconds(0.25)
	summary := fmt.tprintf(
		"Nmap done: %d IP address%s scanned, %d host%s up",
		addresses_in(mask),
		addresses_in(mask) == 1 ? "" : "es",
		len(hits),
		len(hits) == 1 ? "" : "s",
	)
	out_at(s, t, summary, .Plain)
	work_ends_at(s, t)
}

// Every cursor step in cmd_nmap's scheduling body goes through this, not just
// the up-front estimate: work_ends_at overwrites the estimate with the real
// cursor, so scaling only begin_work would have had no effect at all.
@(private)
scale_time :: proc(t: sim.Tick) -> sim.Tick {
	return t * sim.Tick(T2_TIME_NUM) / sim.Tick(T2_TIME_DEN)
}

@(private)
addresses_in :: proc(mask_bits: u8) -> int {
	if mask_bits >= 32 {
		return 1
	}
	return 1 << uint(32 - mask_bits)
}

// --- curl -------------------------------------------------------------------

// Everything a web server serves comes from here. A single hard-coded root is
// enough while every generated host runs the same stack; per-host document
// roots become necessary the moment that stops being true.
WEBROOT :: "/var/www/html"

cmd_curl :: proc(s: ^Session, cmd: ^Command) {
	url, given := positional(cmd, 0)
	if !given {
		out(s, "usage: curl <url>", .Bad)
		return
	}

	target, path, ok := split_url(url)
	if !ok {
		out(s, fmt.tprintf("curl: (3) URL rejected: %s", url), .Bad)
		return
	}

	h, resolved := resolve_host(s, target)
	if !resolved {
		out(s, fmt.tprintf("curl: (6) Could not resolve host: %s", target), .Bad)
		return
	}

	host, _ := sim.pool_get(&s.world.hosts, h)
	if !sim.subnet_reachable(s.world, host.subnet) {
		out(s, fmt.tprintf("curl: (7) Failed to connect to %s: No route to host", target), .Bad)
		return
	}

	// Only hosts actually running a web server answer. Reaching a box is not
	// the same as it having something listening on 80.
	serving := false
	for svc in host.services {
		if svc.name == "http" || svc.name == "https" {
			serving = true
			break
		}
	}
	if !serving {
		// You reached the box and it refused you -- that is a line in someone's
		// log, and louder than a request that worked.
		touched(s, h, NOISE_CURL_FAILED)
		out(s, fmt.tprintf("curl: (7) Failed to connect to %s port 80: Connection refused", target), .Bad)
		return
	}

	// A bare "/" serves the index, as any web server does.
	full := path == "/" \
		? strings.concatenate({WEBROOT, "/index.html"}, context.temp_allocator) \
		: strings.concatenate({WEBROOT, path}, context.temp_allocator)

	begin_work(s, sim.seconds(1.1), "curl")

	index, found := sim.host_file_index(host, full)
	if !found {
		touched(s, h, NOISE_CURL_FAILED) // a 404 in their access log
		out_at(s, sim.seconds(0.9), fmt.tprintf("curl: (22) The requested URL returned error: 404"), .Bad)
		return
	}
	touched(s, h, NOISE_CURL)

	// Iterate a local copy: split_lines_iterator advances the string it is
	// given, so passing the stored field would consume the file and leave every
	// later read of it empty.
	body := host.files[index].content

	// Scheduled rather than immediate so the body and any credential it
	// discloses arrive together, after the request has "taken" its time.
	for line in strings.split_lines_iterator(&body) {
		out_at(s, sim.seconds(0.9), line)
	}
	act_at(s, sim.seconds(1.0), sim.Act_Harvest_File{host = h, index = index})
}

// Splits `[scheme://]host[:port][/path]`. The scheme and port are accepted and
// ignored -- they carry no meaning in the simulation, but rejecting them would
// make every URL a player naturally types wrong.
@(private)
split_url :: proc(url: string) -> (host: string, path: string, ok: bool) {
	rest := url
	if strings.has_prefix(rest, "http://") {
		rest = rest[7:]
	} else if strings.has_prefix(rest, "https://") {
		rest = rest[8:]
	}
	if len(rest) == 0 {
		return "", "", false
	}

	path = "/"
	if slash := strings.index_byte(rest, '/'); slash >= 0 {
		if slash + 1 < len(rest) {
			path = rest[slash:]
		}
		rest = rest[:slash]
	}
	if colon := strings.index_byte(rest, ':'); colon >= 0 {
		rest = rest[:colon]
	}
	if len(rest) == 0 {
		return "", "", false
	}
	return rest, path, true
}

// --- ssh --------------------------------------------------------------------

cmd_ssh :: proc(s: ^Session, cmd: ^Command) {
	spec, given := positional(cmd, 0)
	if !given {
		out(s, "usage: ssh <user@host>", .Bad)
		return
	}

	at := strings.index_byte(spec, '@')
	if at <= 0 || at == len(spec) - 1 {
		out(s, "ssh: target must be user@host", .Bad)
		return
	}
	user := spec[:at]
	target := spec[at + 1:]

	h, resolved := resolve_host(s, target)
	if !resolved {
		out(s, fmt.tprintf("ssh: Could not resolve hostname %s", target), .Bad)
		return
	}

	host, _ := sim.pool_get(&s.world.hosts, h)
	if !sim.subnet_reachable(s.world, host.subnet) {
		// Distinct from "no such host": knowing a box exists but cannot be
		// reached is information, and it is the prompt to go find a pivot.
		out(s, fmt.tprintf("ssh: connect to host %s: No route to host", target), .Bad)
		return
	}

	// Password reuse, doing its work. No cross-host bookkeeping: a credential
	// is a string pair, and it opens anything that happens to accept it.
	account, cred, matched := find_credential(s, host, user)

	begin_work(s, sim.seconds(matched ? 1.6 : 2.4), "ssh")

	if !matched {
		// A failed login is a line in their auth log; a successful one is just a
		// login. Four times the noise, and slower too -- the delay is the target
		// deciding you are wrong.
		touched(s, h, NOISE_SSH_FAILED)
		out_at(s, sim.seconds(2.2), fmt.tprintf("%s@%s: Permission denied (publickey,password).", user, target), .Bad)
		return
	}

	touched(s, h, NOISE_SSH)

	level := account.is_admin ? sim.Access.Root : sim.Access.User
	out_at(s, sim.seconds(0.8), fmt.tprintf("%s@%s's password: ", user, target), .Info)
	out_at(s, sim.seconds(1.4), fmt.tprintf("[+] authenticated as %s (%s)", user, cred.note), .Good)
	act_at(s, sim.seconds(1.5), sim.Act_Grant_Access{host = h, level = level})
	out_at(s, sim.seconds(1.6), fmt.tprintf("Last login: never  --  %s", host.os_name), .Info)

	// The prompt moves once the job completes; see session_update. Held on the
	// job, so interrupting the login drops the move with it.
	set_pending_move(s, h, user)
}

// Accepts an address or a hostname. Hostnames only resolve for hosts already
// discovered -- you cannot ssh to a name you have not seen, which keeps recon
// load-bearing rather than optional.
@(private)
resolve_host :: proc(s: ^Session, target: string) -> (sim.Handle(sim.Host), bool) {
	if a, ok := sim.addr_parse(target); ok {
		return sim.host_by_address(s.world, a)
	}
	it: int
	for host, h in sim.pool_iter(&s.world.hosts, &it) {
		if host.discovered && host.hostname == target {
			return h, true
		}
	}
	return {}, false
}

@(private)
find_credential :: proc(
	s: ^Session,
	host: ^sim.Host,
	user: string,
) -> (
	account: ^sim.Account,
	cred: sim.Cred,
	ok: bool,
) {
	for &acct in host.accounts {
		if acct.username != user {
			continue
		}
		for c in s.world.keyring {
			if c.username == user && c.password == acct.password {
				return &acct, c, true
			}
		}
	}
	return nil, {}, false
}
