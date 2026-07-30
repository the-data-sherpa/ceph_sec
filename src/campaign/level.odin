package campaign

import "../sim"

// A level: one scenario, teaching one or more techniques.
//
// Levels are compiled-in Odin data rather than files, so a level referencing a
// prerequisite that does not exist, or a technique that is not in the catalogue,
// fails to build rather than failing in front of a player. The cost is a rebuild
// to edit content, which at ~2s is not a cost.
//
// This package depends only on `sim`. A level can construct a world; it knows
// nothing about prompts, rendering or the shell -- which is what lets the
// validator build every level and inspect it without a session existing.

Level_Kind :: enum u8 {
	Teach,   // introduces a technique, in a network built to make it legible
	Apply,   // the same technique somewhere messier
	Combine, // needs techniques from earlier blocks as well
}

kind_label :: proc(k: Level_Kind) -> string {
	switch k {
	case .Teach:
		return "teach"
	case .Apply:
		return "apply"
	case .Combine:
		return "combine"
	}
	return "?"
}

// --- goals ------------------------------------------------------------------
//
// Declarative rather than a predicate procedure, deliberately. A `proc` would be
// more flexible, but then the level select could not display an objective, the
// validator could not check that its target exists, and a test could not reason
// about it without running a whole session. Levels are content; content should
// be inspectable.
//
// Hosts and subnets are named by string, not handle: handles only exist once the
// build proc has run, and the objective is written before that.

Goal_Discover_Host :: struct {
	host: string,
}

Goal_Discover_Service :: struct {
	host: string,
	port: u16,
}

Goal_Obtain_Credential :: struct {
	username: string,
}

Goal_Access :: struct {
	host:  string,
	level: sim.Access,
}

Goal_Read_File :: struct {
	host: string,
	path: string,
}

Goal_Reach_Subnet :: struct {
	subnet: string,
}

Goal :: union {
	Goal_Discover_Host,
	Goal_Discover_Service,
	Goal_Obtain_Credential,
	Goal_Access,
	Goal_Read_File,
	Goal_Reach_Subnet,
}

Objective :: struct {
	text:     string, // shown to the player, in their language not ours
	goal:     Goal,
	optional: bool, // not required to complete, but rewarded in the debrief
}

// What the level taught, said plainly once it is over. This is the part that
// makes it a learning game rather than a puzzle game: the player has just done
// the thing, and now finds out what the thing is called and how it is stopped.
Debrief :: struct {
	what:    []string, // what you just did, in real-world terms
	why:     []string, // why it works
	defence: []string, // how a defender prevents it
}

Level :: struct {
	id:         string, // stable identifier; prerequisites reference this
	number:     int,    // display order, 1-based and dense
	title:      string,
	kind:       Level_Kind,
	techniques: []Technique,

	// Prerequisite level ids. The graph must be acyclic and every id must exist;
	// both are enforced by the validator.
	requires: []string,

	// Commands this level permanently unlocks. Sparse across the campaign --
	// most levels teach a technique using tools you already hold, because
	// techniques are not tools.
	grants: []string,

	// Commands usable *inside* this level. Declared separately from `grants` so
	// a later level can withhold something you own: "you have ssh, but 22 is
	// filtered here". The validator proves this is a subset of what the player
	// can actually have by this point.
	tools: []string,

	trace: bool, // is the detection system live in this level
	slots: int,  // concurrent background jobs; 0 means the default

	brief:      []string,
	objectives: []Objective,
	debrief:    Debrief,

	// Constructs the level's world and returns the host the player starts on.
	// Called after sim.world_reset, so it may assume an empty world.
	build: proc(w: ^sim.World) -> sim.Handle(sim.Host),
}

// --- evaluating goals -------------------------------------------------------

@(private)
host_by_name :: proc(w: ^sim.World, name: string) -> (^sim.Host, bool) {
	it: int
	for host in sim.pool_iter(&w.hosts, &it) {
		if host.hostname == name {
			return host, true
		}
	}
	return nil, false
}

@(private)
subnet_by_name :: proc(w: ^sim.World, name: string) -> (sim.Handle(sim.Subnet), bool) {
	it: int
	for sn, h in sim.pool_iter(&w.subnets, &it) {
		if sn.name == name {
			return h, true
		}
	}
	return {}, false
}

// Whether a goal has been achieved, judged from world state alone.
objective_met :: proc(w: ^sim.World, o: Objective) -> bool {
	switch g in o.goal {
	case Goal_Discover_Host:
		host, ok := host_by_name(w, g.host)
		return ok && host.discovered

	case Goal_Discover_Service:
		host, ok := host_by_name(w, g.host)
		if !ok {
			return false
		}
		for svc in host.services {
			if svc.port == g.port && svc.discovered {
				return true
			}
		}
		return false

	case Goal_Obtain_Credential:
		for c in w.keyring {
			if c.username == g.username {
				return true
			}
		}
		return false

	case Goal_Access:
		host, ok := host_by_name(w, g.host)
		return ok && host.access >= g.level

	case Goal_Read_File:
		host, ok := host_by_name(w, g.host)
		if !ok {
			return false
		}
		f, found := sim.host_file(host, g.path)
		return found && f.found

	case Goal_Reach_Subnet:
		h, ok := subnet_by_name(w, g.subnet)
		return ok && sim.subnet_reachable(w, h)
	}
	return false
}

// A level is complete when every non-optional objective is met.
level_complete :: proc(w: ^sim.World, l: ^Level) -> bool {
	for o in l.objectives {
		if !o.optional && !objective_met(w, o) {
			return false
		}
	}
	return true
}

objectives_met :: proc(w: ^sim.World, l: ^Level) -> (met: int, required: int) {
	for o in l.objectives {
		if o.optional {
			continue
		}
		required += 1
		if objective_met(w, o) {
			met += 1
		}
	}
	return
}

// Whether a goal's target exists in a built world. Used by the validator to
// catch an objective pointing at a host that a later edit renamed -- which would
// otherwise make the level quietly impossible.
goal_target_exists :: proc(w: ^sim.World, o: Objective) -> bool {
	switch g in o.goal {
	case Goal_Discover_Host:
		_, ok := host_by_name(w, g.host)
		return ok

	case Goal_Discover_Service:
		host, ok := host_by_name(w, g.host)
		if !ok {
			return false
		}
		for svc in host.services {
			if svc.port == g.port {
				return true
			}
		}
		return false

	case Goal_Obtain_Credential:
		// The credential must be obtainable: some file in the world has to
		// disclose it, or some account has to hold it.
		it: int
		for host in sim.pool_iter(&w.hosts, &it) {
			for f in host.files {
				for c in f.creds {
					if c.username == g.username {
						return true
					}
				}
			}
			for a in host.accounts {
				if a.username == g.username {
					return true
				}
			}
		}
		return false

	case Goal_Access:
		host, ok := host_by_name(w, g.host)
		if !ok {
			return false
		}
		// There must be some account to log in as, or the level is asking for
		// access with no way to get it.
		return len(host.accounts) > 0

	case Goal_Read_File:
		host, ok := host_by_name(w, g.host)
		if !ok {
			return false
		}
		_, found := sim.host_file(host, g.path)
		return found

	case Goal_Reach_Subnet:
		_, ok := subnet_by_name(w, g.subnet)
		return ok
	}
	return false
}

// --- registry ---------------------------------------------------------------

level_by_id :: proc(id: string) -> (^Level, bool) {
	for &l in LEVELS {
		if l.id == id {
			return &l, true
		}
	}
	return nil, false
}

level_by_number :: proc(n: int) -> (^Level, bool) {
	for &l in LEVELS {
		if l.number == n {
			return &l, true
		}
	}
	return nil, false
}
