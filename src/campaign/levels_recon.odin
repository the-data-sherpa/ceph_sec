package campaign

import "../sim"

// Reconnaissance: the first block.
//
// Level 1 hands the player a terminal and exactly one tool. That is the entire
// argument for staged progression -- a beginner who meets six tools, background
// jobs and a rising trace meter in the same minute learns none of them.

// --- 1. sweep ---------------------------------------------------------------

LEVEL_RECON_SWEEP := Level {
	id = "recon-sweep",
	number = 1,
	title = "Knock and see who answers",
	kind = .Teach,
	techniques = {T1595_001},
	requires = {},
	grants = {"nmap"},
	tools = {"nmap"},
	trace = false,
	brief = {
		"A client wants to know what they have exposed. They gave",
		"you a network range and nothing else -- not even a host",
		"list, which is itself worth noticing.",
		"",
		"Find out which addresses in 10.0.4.0/24 are actually live.",
		"",
		"Try: nmap -sn 10.0.4.0/24",
	},
	objectives = {
		{text = "Find the gateway", goal = Goal_Discover_Host{"gw-edge"}},
		{text = "Find the web server", goal = Goal_Discover_Host{"web01"}},
		{text = "Find the mail server", goal = Goal_Discover_Host{"mail01"}},
	},
	debrief = Debrief {
		what = {
			"You performed a host sweep: T1595.001, Scanning IP Blocks.",
			"A /24 is 256 addresses. Three answered.",
		},
		why = {
			"Every engagement starts here, because you cannot attack",
			"what you have not found. -sn asks only 'is anything",
			"there', which is the quietest question you can ask.",
		},
		defence = {
			"You cannot stop a sweep of addresses you have published.",
			"What you can do is know your own inventory better than the",
			"person scanning it -- most organisations are surprised by",
			"their own results.",
		},
	},
	build = build_recon_sweep,
}

build_recon_sweep :: proc(w: ^sim.World) -> sim.Handle(sim.Host) {
	wan := sim.add_subnet(w, "WAN", sim.addr(198, 51, 100, 0), 24, .None)
	dmz := sim.add_subnet(w, "DMZ", sim.addr(10, 0, 4, 0), 24, .Low)

	origin := sim.add_host(w, "ceph", sim.addr(198, 51, 100, 7), wan, "Debian 12")
	sim.grant_access(w, origin, .Root)
	w.origin = origin
	sim.add_file(
		w,
		origin,
		{
			path = "/root/brief.txt",
			content = "client: ORIENT HAULAGE\nscope:  10.0.4.0/24\n\nthey do not have an asset inventory.\nfind out what answers.",
		},
	)

	gw := sim.add_host(w, "gw-edge", sim.addr(10, 0, 4, 1), dmz, "VyOS 1.2")
	sim.add_service(w, gw, {port = 22, proto = .TCP, name = "ssh", product = "OpenSSH", version = "7.4"})

	web := sim.add_host(w, "web01", sim.addr(10, 0, 4, 11), dmz, "Ubuntu 18.04")
	sim.add_service(w, web, {port = 80, proto = .TCP, name = "http", product = "nginx", version = "1.14.0"})

	mail := sim.add_host(w, "mail01", sim.addr(10, 0, 4, 25), dmz, "Debian 10")
	sim.add_service(w, mail, {port = 25, proto = .TCP, name = "smtp", product = "Postfix", version = "3.4.14"})

	append(&w.links, sim.Link{from = wan, to = dmz, via = origin, min_access = .User})
	return origin
}

// --- 2. versions ------------------------------------------------------------

LEVEL_RECON_VERSIONS := Level {
	id = "recon-versions",
	number = 2,
	title = "What is it running?",
	kind = .Teach,
	techniques = {T1595_002, T1592_002},
	requires = {"recon-sweep"},
	grants = {},
	tools = {"nmap"},
	trace = false,
	brief = {
		"Knowing a host is up tells you almost nothing. Knowing it",
		"runs Apache 2.4.29 tells you which published flaws might",
		"apply to it.",
		"",
		"The same client, a different segment. Find out what is",
		"actually listening on 10.0.7.0/24 -- software and version,",
		"not just ports.",
		"",
		"Try: nmap -sV 10.0.7.0/24",
	},
	objectives = {
		{text = "Identify the web service on app01", goal = Goal_Discover_Service{"app01", 8080}},
		{text = "Identify the database on db01", goal = Goal_Discover_Service{"db01", 5432}},
		{text = "Identify the file share on files01", goal = Goal_Discover_Service{"files01", 445}},
	},
	debrief = Debrief {
		what = {
			"You fingerprinted services: T1595.002, Vulnerability",
			"Scanning, and T1592.002, gathering host software",
			"information.",
		},
		why = {
			"A version string is the hinge everything else hangs on.",
			"Exploit selection, published-advisory lookups, and knowing",
			"whether a box is five years behind all start from that",
			"pair of strings.",
			"",
			"It costs more attention than -sn, because asking what",
			"something is means talking to it properly rather than just",
			"pinging it.",
		},
		defence = {
			"Suppress version banners where you can, but do not mistake",
			"that for a fix -- it buys minutes. Knowing your own",
			"versions, and how far behind they are, is the control that",
			"actually matters.",
		},
	},
	build = build_recon_versions,
}

build_recon_versions :: proc(w: ^sim.World) -> sim.Handle(sim.Host) {
	wan := sim.add_subnet(w, "WAN", sim.addr(198, 51, 100, 0), 24, .None)
	app := sim.add_subnet(w, "APP", sim.addr(10, 0, 7, 0), 24, .Low)

	origin := sim.add_host(w, "ceph", sim.addr(198, 51, 100, 7), wan, "Debian 12")
	sim.grant_access(w, origin, .Root)
	w.origin = origin

	a := sim.add_host(w, "app01", sim.addr(10, 0, 7, 20), app, "Ubuntu 20.04")
	sim.add_service(w, a, {port = 22, proto = .TCP, name = "ssh", product = "OpenSSH", version = "8.2p1"})
	sim.add_service(w, a, {port = 8080, proto = .TCP, name = "http", product = "Apache Tomcat", version = "9.0.31"})

	d := sim.add_host(w, "db01", sim.addr(10, 0, 7, 30), app, "CentOS 7")
	sim.add_service(w, d, {port = 5432, proto = .TCP, name = "postgresql", product = "PostgreSQL", version = "9.6.10"})

	fsv := sim.add_host(w, "files01", sim.addr(10, 0, 7, 40), app, "Windows Server 2012 R2")
	sim.add_service(w, fsv, {port = 445, proto = .TCP, name = "smb", product = "Samba", version = "4.3.11"})

	append(&w.links, sim.Link{from = wan, to = app, via = origin, min_access = .User})
	return origin
}
