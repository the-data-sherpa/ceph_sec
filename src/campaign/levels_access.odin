package campaign

import "../sim"

// Getting a credential, and then getting a second host with it. These two
// levels are the heart of what the campaign teaches early: almost no real
// intrusion begins with an exploit, and almost none stays on one machine.

// --- 3. exposure ------------------------------------------------------------

LEVEL_ACCESS_EXPOSURE := Level {
	id = "access-exposure",
	number = 3,
	title = "Left in the open",
	kind = .Teach,
	techniques = {T1594, T1552_001},
	requires = {"recon-versions"},
	grants = {"curl"},
	tools = {"nmap", "curl"},
	trace = false,
	brief = {
		"No exploit here. A deployment script copied a",
		"configuration file into a directory the web server",
		"publishes, and nobody noticed.",
		"",
		"This is not a rare mistake. It is one of the most common",
		"ways a stranger acquires a working password.",
		"",
		"Scan 10.0.5.0/24, then read what the web server will hand",
		"you. Look at the page source before you guess at",
		"filenames.",
	},
	objectives = {
		{text = "Find the web server", goal = Goal_Discover_Host{"portal"}},
		{text = "Read the published page", goal = Goal_Read_File{"portal", "/var/www/html/index.html"}},
		{text = "Obtain a credential", goal = Goal_Obtain_Credential{"deploy"}},
	},
	hints = {
		{0, {"Start the same way as always: find out what is there and", "what it is running. One host serves web pages."}},
		{1, {"curl fetches a URL. The page itself is at the root:", "curl http://10.0.5.12/"}},
		{2, {"Read the page source, not just the words on it. The", "developer left a note about a file they meant to move."}},
		{2, {"That file is served like any other. Fetch it directly:", "curl http://10.0.5.12/.env"}},
	},
	debrief = Debrief {
		what = {
			"You read a credential straight out of a published file:",
			"T1552.001, Unsecured Credentials In Files, reached through",
			"T1594, Search Victim-Owned Websites.",
		},
		why = {
			"Deployment tooling copies a directory. If secrets live",
			"inside that directory, they are published along with",
			"everything else. The web server is doing exactly its job.",
			"",
			"The comment in the page source is the other half:",
			"developers leave notes about paths they mean to clean up,",
			"and forget.",
		},
		defence = {
			"Keep secrets out of anything the deployment copies --",
			"environment variables or a secret manager, never a file in",
			"the tree. Block dotfiles at the web server. Scan your own",
			"published surface for things that look like credentials;",
			"attackers certainly do.",
		},
	},
	build = build_access_exposure,
}

build_access_exposure :: proc(w: ^sim.World) -> sim.Handle(sim.Host) {
	wan := sim.add_subnet(w, "WAN", sim.addr(198, 51, 100, 0), 24, .None)
	dmz := sim.add_subnet(w, "DMZ", sim.addr(10, 0, 5, 0), 24, .Low)

	origin := sim.add_host(w, "ceph", sim.addr(198, 51, 100, 7), wan, "Debian 12")
	sim.grant_access(w, origin, .Root)
	w.origin = origin

	gw := sim.add_host(w, "edge", sim.addr(10, 0, 5, 1), dmz, "VyOS 1.2")
	sim.add_service(w, gw, {port = 22, proto = .TCP, name = "ssh", product = "OpenSSH", version = "7.4"})

	portal := sim.add_host(w, "portal", sim.addr(10, 0, 5, 12), dmz, "Ubuntu 18.04")
	sim.add_service(w, portal, {port = 80, proto = .TCP, name = "http", product = "Apache httpd", version = "2.4.29"})
	sim.add_service(w, portal, {port = 22, proto = .TCP, name = "ssh", product = "OpenSSH", version = "7.6p1"})
	sim.add_account(w, portal, {username = "deploy", password = "Rel3ase-2021#"})

	// The comment is the lead. Without it the .env is a guess, and a level that
	// requires guessing teaches nothing.
	sim.add_file(
		w,
		portal,
		{
			path = "/var/www/html/index.html",
			content = "<html>\n<body>\n  <h1>Orient Haulage</h1>\n  <p>Customer portal.</p>\n  <!-- deploy: .env is still being copied into the web root, fix in Q3 -->\n</body>\n</html>",
		},
	)
	sim.add_file(
		w,
		portal,
		{
			path = "/var/www/html/.env",
			content = "APP_ENV=production\nDEPLOY_USER=deploy\nDEPLOY_PASS=Rel3ase-2021#\nDB_HOST=10.0.5.30",
			sensitive = true,
		},
		{{username = "deploy", password = "Rel3ase-2021#"}},
	)

	append(&w.links, sim.Link{from = wan, to = dmz, via = origin, min_access = .User})
	return origin
}

// --- 4. reuse ---------------------------------------------------------------

LEVEL_LATERAL_REUSE := Level {
	id = "lateral-reuse",
	number = 4,
	title = "The same password, twice",
	kind = .Teach,
	techniques = {T1078_003, T1021_004},
	requires = {"access-exposure"},
	grants = {"ssh"},
	tools = {"nmap", "curl", "ssh"},
	trace = false,
	brief = {
		"You have a credential for one machine. The question every",
		"attacker asks next is whether anyone else accepts it.",
		"",
		"Find the hosts on 10.0.6.0/24, take the credential the",
		"portal is leaking, and see how far it goes.",
		"",
		"ssh logs in with a credential you hold. `help ssh` for the",
		"syntax.",
	},
	objectives = {
		{text = "Obtain the service credential", goal = Goal_Obtain_Credential{"svc-backup"}},
		{text = "Log in to the host it belongs to", goal = Goal_Access{"portal", .User}},
		{text = "Reuse it on the backup server", goal = Goal_Access{"backup01", .User}},
	},
	hints = {
		{0, {"Same shape as the last level: scan, read the page, and", "follow what its source mentions."}},
		{0, {"The page names a config file. Fetch it:", "curl http://10.0.6.12/backup.conf"}},
		{1, {"You have a username and a password -- `creds` shows what", "you hold. ssh takes them as user@host."}},
		{1, {"Run: ssh svc-backup@10.0.6.12"}},
		{2, {"That is the machine the credential belongs to. The", "question is whether anything else accepts it."}},
		{2, {"The config named where the backups go. Try that host:", "ssh svc-backup@10.0.6.40"}},
	},
	debrief = Debrief {
		what = {
			"You moved laterally with a reused credential: T1078.003,",
			"Valid Accounts, over T1021.004, Remote Services: SSH.",
		},
		why = {
			"Nothing was exploited. From the target's point of view a",
			"valid account logged in successfully -- which is precisely",
			"why this is hard to detect and why it is how real",
			"intrusions spread.",
			"",
			"A single service account shared across hosts turns one",
			"exposed file into access to everything that accepts it.",
		},
		defence = {
			"Unique credentials per host, per service. If a human has",
			"to type it, it will be reused, so machines should hold",
			"machine secrets. Alert on one account authenticating to",
			"hosts it has never touched before -- the login succeeds,",
			"so the anomaly is the pattern.",
		},
	},
	build = build_lateral_reuse,
}

build_lateral_reuse :: proc(w: ^sim.World) -> sim.Handle(sim.Host) {
	wan := sim.add_subnet(w, "WAN", sim.addr(198, 51, 100, 0), 24, .None)
	dmz := sim.add_subnet(w, "DMZ", sim.addr(10, 0, 6, 0), 24, .Low)

	origin := sim.add_host(w, "ceph", sim.addr(198, 51, 100, 7), wan, "Debian 12")
	sim.grant_access(w, origin, .Root)
	w.origin = origin

	REUSED :: "b4ckup-svc-2020"

	portal := sim.add_host(w, "portal", sim.addr(10, 0, 6, 12), dmz, "Ubuntu 18.04")
	sim.add_service(w, portal, {port = 80, proto = .TCP, name = "http", product = "Apache httpd", version = "2.4.29"})
	sim.add_service(w, portal, {port = 22, proto = .TCP, name = "ssh", product = "OpenSSH", version = "7.6p1"})
	sim.add_account(w, portal, {username = "svc-backup", password = REUSED})
	sim.add_file(
		w,
		portal,
		{
			path = "/var/www/html/index.html",
			content = "<html><body><h1>Orient Haulage</h1>\n<!-- backup job config is in backup.conf, move it out of here -->\n</body></html>",
		},
	)
	sim.add_file(
		w,
		portal,
		{
			path = "/var/www/html/backup.conf",
			content = "# nightly offsite job\nBACKUP_USER=svc-backup\nBACKUP_PASS=b4ckup-svc-2020\nBACKUP_HOST=backup01",
			sensitive = true,
		},
		{{username = "svc-backup", password = REUSED}},
	)

	// The same account, the same password, a different machine. No special
	// mechanic -- ssh simply compares strings, which is the point.
	backup := sim.add_host(w, "backup01", sim.addr(10, 0, 6, 40), dmz, "Debian 10")
	sim.add_service(w, backup, {port = 22, proto = .TCP, name = "ssh", product = "OpenSSH", version = "7.9p1"})
	sim.add_account(w, backup, {username = "svc-backup", password = REUSED})
	sim.add_file(
		w,
		backup,
		{path = "/srv/backups/README", content = "nightly dumps land here at 0200.\nretention 30 days."},
	)

	append(&w.links, sim.Link{from = wan, to = dmz, via = origin, min_access = .User})
	return origin
}
