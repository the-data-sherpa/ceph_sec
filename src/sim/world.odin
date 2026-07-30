package sim

import "core:mem"
import "core:mem/virtual"
import "core:strings"

// A state change waiting for its tick.
//
// Timers deliberately carry an *action*, not an event. Scheduling raw events
// would let a timer announce something the world never actually did -- "host
// discovered" arriving in the terminal while `host.discovered` stays false, or
// worse, the reverse. Routing everything through the same mutators means the
// event is a consequence of the change rather than a parallel claim about it,
// and the two cannot drift.
Action :: union {
	Act_Log,
	Act_Discover_Host,
	Act_Discover_Service,
	Act_Grant_Access,
	Act_Harvest_File,
}

Act_Log :: struct {
	text:  string,
	level: Log_Level,
}

Act_Discover_Host :: struct {
	host: Handle(Host),
}

Act_Discover_Service :: struct {
	host:  Handle(Host),
	index: int,
}

Act_Grant_Access :: struct {
	host:  Handle(Host),
	level: Access,
}

Act_Harvest_File :: struct {
	host:  Handle(Host),
	index: int,
}

// This is the seed of the job system: "nmap finishes in 8 seconds" is a timer,
// and so is "the trace advances a notch". Scheduling against tick counts rather
// than wall-clock is what keeps a real-time game deterministic.
//
// `tag` groups the timers belonging to one operation so they can be cancelled
// together. A running tool schedules all of its output under a single tag;
// interrupting it is one cancel_tag call. M2's `kill %1` is the same mechanism.
Timer :: struct {
	fire_at: Tick,
	action:  Action,
	tag:     u32, // 0 = untagged, never matched by cancel_tag
}

apply :: proc(w: ^World, a: Action) {
	switch act in a {
	case Act_Log:
		ring_push(&w.events, Ev_Log{text = act.text, level = act.level})
	case Act_Discover_Host:
		discover_host(w, act.host)
	case Act_Discover_Service:
		discover_service(w, act.host, act.index)
	case Act_Grant_Access:
		grant_access(w, act.host, act.level)
	case Act_Harvest_File:
		harvest_file(w, act.host, act.index)
	}
}

// One run's entire state.
//
// Every allocation belongs to the arena, so ending a run is a single
// arena_free_all -- no per-object teardown to get wrong, no way for a new run
// to inherit a stale pointer, and no leak surface as the world model grows.
// Roguelike runs are exactly the lifetime an arena wants.
World :: struct {
	arena:     virtual.Arena,
	allocator: mem.Allocator,

	seed: u64,
	rng:  Rng,
	now:  Tick,

	hosts:   Pool(Host),
	subnets: Pool(Subnet),
	links:   [dynamic]Link,

	timers:      [dynamic]Timer,
	events:      Event_Ring,
	tag_counter: u32,

	// Credentials the player has obtained, from any source. Run state rather
	// than shell state: it is part of what a save or a replay would need, and
	// it survives moving between hosts.
	keyring: [dynamic]Cred,

	// The machine the player operates from; always held at root.
	origin: Handle(Host),
}

world_init :: proc(w: ^World, seed: u64) -> mem.Allocator_Error {
	virtual.arena_init_growing(&w.arena) or_return
	w.allocator = virtual.arena_allocator(&w.arena)
	world_bind(w, seed)
	return nil
}

// Wipe the run and start another in the same arena. The allocator handle stays
// valid, so callers holding ^World need no fixups.
world_reset :: proc(w: ^World, seed: u64) {
	virtual.arena_free_all(&w.arena)
	world_bind(w, seed)
}

world_destroy :: proc(w: ^World) {
	virtual.arena_destroy(&w.arena)
	w^ = {}
}

@(private)
world_bind :: proc(w: ^World, seed: u64) {
	w.seed = seed
	w.rng = rng_seed(seed)
	w.now = 0
	w.origin = {}
	w.tag_counter = 0
	ring_clear(&w.events)

	pool_init(&w.hosts, 32, w.allocator)
	pool_init(&w.subnets, 8, w.allocator)
	w.links = make([dynamic]Link, 0, 8, w.allocator)
	w.timers = make([dynamic]Timer, 0, 32, w.allocator)
	w.keyring = make([dynamic]Cred, 0, 8, w.allocator)
}

// Advance exactly one tick. The only way the world changes with time.
tick :: proc(w: ^World) {
	w.now += 1

	// Ordered removal so timers scheduled for the same tick fire in the order
	// they were scheduled -- log lines must not arrive shuffled.
	i := 0
	for i < len(w.timers) {
		if w.timers[i].fire_at <= w.now {
			action := w.timers[i].action
			ordered_remove(&w.timers, i)
			// Removed before applying: an action is free to schedule further
			// timers without disturbing this scan.
			apply(w, action)
		} else {
			i += 1
		}
	}
}

tick_n :: proc(w: ^World, n: int) {
	for _ in 0 ..< n {
		tick(w)
	}
}

schedule :: proc(w: ^World, delay: Tick, a: Action) {
	append(&w.timers, Timer{fire_at = w.now + delay, action = a})
}

schedule_tagged :: proc(w: ^World, delay: Tick, a: Action, tag: u32) {
	append(&w.timers, Timer{fire_at = w.now + delay, action = a, tag = tag})
}

// Drops every pending timer carrying `tag` and reports how many went. Tag 0 is
// never matched, so untagged timers cannot be cancelled by accident.
cancel_tag :: proc(w: ^World, tag: u32) -> int {
	if tag == 0 {
		return 0
	}
	removed := 0
	i := 0
	for i < len(w.timers) {
		if w.timers[i].tag == tag {
			ordered_remove(&w.timers, i)
			removed += 1
		} else {
			i += 1
		}
	}
	return removed
}

// Monotonic per run, so a tag is never reused while its timers are still
// pending. Starts at 1 because 0 means "untagged".
next_tag :: proc(w: ^World) -> u32 {
	w.tag_counter += 1
	return w.tag_counter
}

// Emit a line now. The text is cloned into the arena, so callers may pass
// temporaries freely and the frontend may hold the string for the rest of the
// run.
log_line :: proc(w: ^World, text: string, level: Log_Level = .Plain) {
	ring_push(&w.events, Ev_Log{text = strings.clone(text, w.allocator), level = level})
}

log_at :: proc(w: ^World, delay: Tick, text: string, level: Log_Level = .Plain) {
	schedule(w, delay, Act_Log{text = strings.clone(text, w.allocator), level = level})
}

// --- state transitions ------------------------------------------------------
// Mutation and its event are emitted together so the two can never drift, and
// each is idempotent so repeated discovery is harmless.

discover_host :: proc(w: ^World, h: Handle(Host)) {
	host, ok := pool_get(&w.hosts, h)
	if !ok || host.discovered {
		return
	}
	host.discovered = true
	ring_push(&w.events, Ev_Host_Discovered{host = h})
}

discover_service :: proc(w: ^World, h: Handle(Host), index: int) {
	host, ok := pool_get(&w.hosts, h)
	if !ok || index < 0 || index >= len(host.services) {
		return
	}
	if host.services[index].discovered {
		return
	}
	host.services[index].discovered = true
	ring_push(&w.events, Ev_Service_Discovered{host = h, index = index})
}

// Access only ever ratchets upward; re-exploiting a box you already own is not
// a downgrade.
grant_access :: proc(w: ^World, h: Handle(Host), level: Access) {
	host, ok := pool_get(&w.hosts, h)
	if !ok || level <= host.access {
		return
	}
	host.access = level
	ring_push(&w.events, Ev_Access_Gained{host = h, level = level})
}

// --- construction -----------------------------------------------------------

add_subnet :: proc(w: ^World, name: string, base: Addr, mask_bits: u8) -> Handle(Subnet) {
	return pool_add(
		&w.subnets,
		Subnet {
			name = strings.clone(name, w.allocator),
			base = base,
			mask_bits = mask_bits,
			hosts = make([dynamic]Handle(Host), 0, 8, w.allocator),
		},
	)
}

add_host :: proc(
	w: ^World,
	hostname: string,
	address: Addr,
	subnet: Handle(Subnet),
	os_name: string = "",
) -> Handle(Host) {
	h := pool_add(
		&w.hosts,
		Host {
			hostname = strings.clone(hostname, w.allocator),
			address = address,
			subnet = subnet,
			os_name = strings.clone(os_name, w.allocator),
			services = make([dynamic]Service, 0, 4, w.allocator),
			accounts = make([dynamic]Account, 0, 4, w.allocator),
			files = make([dynamic]File, 0, 4, w.allocator),
		},
	)
	if sn, ok := pool_get(&w.subnets, subnet); ok {
		append(&sn.hosts, h)
	}
	return h
}

// Marks a file as read and takes anything it discloses.
//
// Single entry point so every way of reading a file -- `cat` on a shell,
// `curl` over http, and whatever later tools do -- has identical consequences.
// A file that leaks a password should leak it however you got at it.
harvest_file :: proc(w: ^World, h: Handle(Host), index: int) {
	host, ok := pool_get(&w.hosts, h)
	if !ok || index < 0 || index >= len(host.files) {
		return
	}
	f := &host.files[index]
	f.found = true
	for c in f.creds {
		keyring_add(w, Cred{username = c.username, password = c.password, note = c.note})
	}
}

// Adds a credential to the keyring, ignoring exact duplicates. Re-reading the
// same config file must not stack up identical entries.
//
// Deduplication is on username+password, not on `note`: the same credential
// found in two places is one credential, and the first place you found it is
// the one worth remembering.
keyring_add :: proc(w: ^World, c: Cred) -> bool {
	for existing in w.keyring {
		if existing.username == c.username && existing.password == c.password {
			return false
		}
	}
	append(
		&w.keyring,
		Cred {
			username = strings.clone(c.username, w.allocator),
			password = strings.clone(c.password, w.allocator),
			note = strings.clone(c.note, w.allocator),
		},
	)
	ring_push(&w.events, Ev_Cred_Obtained{index = len(w.keyring) - 1})
	return true
}

// Every credential the player holds that matches an account on `h`. This is
// password reuse doing its work: no cross-host bookkeeping, just a string
// comparison against whatever the target actually accepts.
keyring_matches :: proc(w: ^World, h: Handle(Host), out: ^[dynamic]Cred) {
	clear(out)
	host, ok := pool_get(&w.hosts, h)
	if !ok {
		return
	}
	for c in w.keyring {
		for acct in host.accounts {
			if acct.username == c.username && acct.password == c.password {
				append(out, c)
				break
			}
		}
	}
}

@(private)
concat :: proc(w: ^World, parts: ..string) -> string {
	return strings.concatenate(parts, w.allocator)
}

add_account :: proc(w: ^World, h: Handle(Host), a: Account) {
	host, ok := pool_get(&w.hosts, h)
	if !ok {
		return
	}
	acct := a
	acct.username = strings.clone(a.username, w.allocator)
	acct.password = strings.clone(a.password, w.allocator)
	acct.pw_hash = strings.clone(a.pw_hash, w.allocator)
	append(&host.accounts, acct)
}

add_file :: proc(w: ^World, h: Handle(Host), f: File, creds: []Cred = nil) {
	host, ok := pool_get(&w.hosts, h)
	if !ok {
		return
	}
	file := f
	file.path = strings.clone(f.path, w.allocator)
	file.content = strings.clone(f.content, w.allocator)
	if file.size == 0 {
		file.size = len(file.content)
	}

	if len(creds) > 0 {
		owned := make([]Cred, len(creds), w.allocator)
		for c, i in creds {
			// Default the provenance note to where the credential was found.
			// Callers almost always want exactly this, and a keyring of a dozen
			// entries is unusable without it.
			note := c.note
			if len(note) == 0 {
				note = concat(w, host.hostname, ":", file.path)
			}
			owned[i] = Cred {
				username = strings.clone(c.username, w.allocator),
				password = strings.clone(c.password, w.allocator),
				note     = strings.clone(note, w.allocator),
			}
		}
		file.creds = owned
	}

	append(&host.files, file)
}

add_service :: proc(w: ^World, h: Handle(Host), s: Service) {
	host, ok := pool_get(&w.hosts, h)
	if !ok {
		return
	}
	svc := s
	svc.name = strings.clone(s.name, w.allocator)
	svc.product = strings.clone(s.product, w.allocator)
	svc.version = strings.clone(s.version, w.allocator)
	svc.banner = strings.clone(s.banner, w.allocator)
	append(&host.services, svc)
}
