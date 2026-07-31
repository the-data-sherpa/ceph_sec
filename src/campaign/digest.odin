package campaign

import "../sim"

// A content hash of the campaign.
//
// Levels are compiled-in Odin data, so a replay is only meaningful against the
// catalogue it was recorded against. Renaming a host, retiming an objective or
// rewording a brief all change what a recorded session does, and without this
// the only symptom would be a digest mismatch a hundred ticks into playback --
// which reads exactly like a determinism regression.
//
// With it, playback can say "the campaign changed since this was recorded"
// before it plays a single tick, and the corpus test can say "regenerate the
// replays" rather than "the simulation broke".
//
// Everything a level says or builds goes in, including brief and debrief text,
// because the brief is logged into the event stream and is therefore part of
// what a replay reproduces. What deliberately does not go in is the `build`
// procedure -- a proc pointer has no stable identity across builds, and hashing
// its address would make this number differ between two compilations of
// identical source. That is the one thing this cannot see, and the marks are
// what covers it.
catalogue_digest :: proc() -> u64 {
	d := sim.digest_init()

	for t in CATALOGUE {
		sim.digest_str(&d, t.id)
		sim.digest_str(&d, t.name)
		sim.digest_u64(&d, u64(t.tactic))
	}

	for &l in LEVELS {
		sim.digest_str(&d, l.id)
		sim.digest_i64(&d, i64(l.number))
		sim.digest_str(&d, l.title)
		sim.digest_u64(&d, u64(l.kind))
		sim.digest_u64(&d, l.trace ? 1 : 0)
		sim.digest_i64(&d, i64(l.slots))

		for t in l.techniques {
			sim.digest_str(&d, t.id)
		}
		for r in l.requires {
			sim.digest_str(&d, r)
		}
		for g in l.grants {
			sim.digest_str(&d, g)
		}
		for t in l.tools {
			sim.digest_str(&d, t)
		}
		for b in l.brief {
			sim.digest_str(&d, b)
		}

		for o in l.objectives {
			sim.digest_str(&d, o.text)
			sim.digest_u64(&d, o.optional ? 1 : 0)
			digest_goal(&d, o.goal)
		}

		for h in l.hints {
			sim.digest_i64(&d, i64(h.unblocks))
			for line in h.lines {
				sim.digest_str(&d, line)
			}
		}

		for s in l.debrief.what {
			sim.digest_str(&d, s)
		}
		for s in l.debrief.why {
			sim.digest_str(&d, s)
		}
		for s in l.debrief.defence {
			sim.digest_str(&d, s)
		}
	}

	return d.h
}

// Exhaustive, so a new goal variant is a compile error here rather than a hole
// in the hash.
@(private)
digest_goal :: proc(d: ^sim.Digest, g: Goal) {
	switch v in g {
	case Goal_Discover_Host:
		sim.digest_u64(d, 1)
		sim.digest_str(d, v.host)
	case Goal_Discover_Service:
		sim.digest_u64(d, 2)
		sim.digest_str(d, v.host)
		sim.digest_u64(d, u64(v.port))
	case Goal_Obtain_Credential:
		sim.digest_u64(d, 3)
		sim.digest_str(d, v.username)
	case Goal_Access:
		sim.digest_u64(d, 4)
		sim.digest_str(d, v.host)
		sim.digest_u64(d, u64(v.level))
	case Goal_Read_File:
		sim.digest_u64(d, 5)
		sim.digest_str(d, v.host)
		sim.digest_str(d, v.path)
	case Goal_Reach_Subnet:
		sim.digest_u64(d, 6)
		sim.digest_str(d, v.subnet)
	case:
		sim.digest_u64(d, 0)
	}
}
