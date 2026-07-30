package campaign

import "../sim"

// The combine level: everything the first four taught, in one engagement, with
// the detection system live for the first time.
//
// This is the network that was the whole game through M1 and M2. It arrives here
// unchanged, which is the argument for the block structure: the earlier levels
// each isolate one step of it, and this one asks you to do them all without
// being told which is next.

LEVEL_NORTHWIND := Level {
	id = "northwind",
	number = 5,
	title = "Northwind Logistics",
	kind = .Combine,
	techniques = {T1595_002, T1594, T1552_001, T1078_003, T1005},
	requires = {"lateral-reuse"},
	grants = {},
	tools = {"nmap", "curl", "ssh"},
	trace = true,
	brief = {
		"A full engagement. Nobody will tell you which step comes",
		"next.",
		"",
		"Recover /srv/backup/manifest.sql from their internal file",
		"server. You have root on a rented VPS with a route into",
		"their DMZ, and nothing else -- no credentials, no host",
		"list.",
		"",
		"New this level: they are watching. Everything you do costs",
		"attention in the segment you do it in, and enough of it",
		"ends the engagement. Run `trace` to see where you stand.",
		"",
		"Nothing here is a technique you have not already used.",
		"`hint` if you want a nudge anyway.",
	},
	objectives = {
		{text = "Map the DMZ", goal = Goal_Discover_Host{"web01"}},
		{text = "Find a credential", goal = Goal_Obtain_Credential{"svc"}},
		{text = "Take the jump box", goal = Goal_Access{"jump01", .Root}},
		{text = "Reach the internal segment", goal = Goal_Reach_Subnet{"CORP"}},
		{text = "Recover the manifest", goal = Goal_Read_File{"fs01", "/srv/backup/manifest.sql"}},
		{text = "Finish without tripping an alarm", goal = Goal_Reach_Subnet{"CORP"}, optional = true},
	},
	// The hint that matters most is the fourth step. Taking the jump box and
	// then having nowhere to go is exactly where this level stranded its first
	// player -- the clues are on jump01 now, but a hint should still point at
	// the habit rather than the file.
	hints = {
		{0, {"Start where you always start: what is on 10.0.4.0/24, and", "what is it running."}},
		{1, {"One of them serves web pages. You have read a page's", "source for a leaked path twice already."}},
		{1, {"curl http://10.0.4.11/ -- then fetch what it mentions."}},
		{2, {"The credential is reused, and the .env even names the", "host it was meant for."}},
		{2, {"ssh svc@10.0.4.19 -- that account is an admin there,", "which is what opens the route onward."}},
		{3, {"You are on a machine sitting in two networks. It was put", "there precisely to reach the one you cannot."}},
		{3, {"The first thing worth reading on a host you have taken", "is what it talks to: history, hosts file, interfaces."}},
		{3, {"cat /home/svc/.bash_history names the internal host."}},
		{4, {"The internal segment is 10.0.9.0/24. Scan it, then use", "the same credential again: ssh svc@10.0.9.10"}},
		{4, {"The manifest is at /srv/backup/manifest.sql -- cat it."}},
	},
	debrief = Debrief {
		what = {
			"A complete chain: reconnaissance, an exposed file, a",
			"reused credential, a pivot through a dual-homed host, and",
			"collection. T1595.002, T1594, T1552.001, T1078.003, T1005.",
		},
		why = {
			"Not one step of that was an exploit. Every link was a",
			"decision someone made for a good reason at the time --",
			"ship the config, reuse the service account, let the jump",
			"box reach both networks.",
			"",
			"Segmentation was the control that nearly worked. CORP was",
			"unreachable until you held jump01 at root, and would have",
			"become unreachable again the moment you lost it.",
		},
		defence = {
			"Any one of these breaks the chain: keep secrets out of the",
			"web root, use per-host service accounts, and require the",
			"jump box to be something more than a password away.",
			"",
			"Depth is the point. You do not need every control to hold",
			"-- you need the attacker to need all of them to fail.",
		},
	},
	build = build_northwind,
}

// The M1 network, moved here verbatim from main.build_scenario.
//
// The intended path is discoverable rather than guessable: scanning the DMZ
// finds web01, whose index page names a file that should not be in the document
// root; that file leaks a password reused on jump01, whose svc account is an
// admin, which opens the route to the objective. Every step is visible from the
// step before it.
build_northwind :: proc(w: ^sim.World) -> sim.Handle(sim.Host) {
	// Monitoring runs inversely to how interesting a segment is, which is the
	// recurring shape of the whole game: the boxes that are easy to be loud
	// around are the ones not worth reaching.
	wan := sim.add_subnet(w, "WAN", sim.addr(198, 51, 100, 0), 24, .None)
	dmz := sim.add_subnet(w, "DMZ", sim.addr(10, 0, 4, 0), 24, .Low)
	corp := sim.add_subnet(w, "CORP", sim.addr(10, 0, 9, 0), 24, .Medium)

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

	// A jump box's own history is what tells you where it jumps to.
	//
	// Without these, taking jump01 leaves you standing on a bare machine
	// expected to know an address range nothing has told you -- the CORP range
	// is stated only in the contract back on your own VPS, which you have just
	// left. That is the difference between a level being solvable and being
	// discoverable, and it is a real lesson in its own right: the first thing
	// worth reading on a host you have just taken is what it talks to.
	sim.add_file(
		w,
		jump,
		{
			path = "/home/svc/.bash_history",
			content = "ssh svc@10.0.9.10\nrsync -a /srv/exports/ svc@10.0.9.10:/srv/backup/\nsudo tcpdump -i eth1 -w /tmp/cap.pcap",
		},
	)
	sim.add_file(
		w,
		jump,
		{
			path = "/etc/hosts",
			content = "127.0.0.1 localhost\n10.0.4.19 jump01\n10.0.9.10 fs01.northwind.internal fs01\n10.0.9.20 dc01.northwind.internal",
		},
	)
	sim.add_file(
		w,
		jump,
		{
			path = "/etc/network/interfaces",
			content = "# dual-homed: DMZ and internal\nauto eth0\niface eth0 inet static\n  address 10.0.4.19/24\n\nauto eth1\niface eth1 inet static\n  address 10.0.9.19/24",
		},
	)

	// The reused password. `svc` exists on several boxes with the same
	// password, which is the entire lateral-movement mechanic and needs no
	// special case anywhere: ssh just compares strings.
	SVC_PASSWORD :: "Nw-deploy-2019!"

	sim.add_account(w, web, {username = "svc", password = SVC_PASSWORD})
	sim.add_account(w, jump, {username = "svc", password = SVC_PASSWORD, is_admin = true})

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

// The campaign, in order. Level numbers must be dense and unique; the validator
// enforces both, along with the prerequisite graph and tool availability.
LEVELS := []Level {
	LEVEL_RECON_SWEEP,
	LEVEL_RECON_VERSIONS,
	LEVEL_ACCESS_EXPOSURE,
	LEVEL_LATERAL_REUSE,
	LEVEL_NORTHWIND,
}
