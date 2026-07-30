package tests

import "core:strings"
import "core:testing"
import "../src/campaign"
import "../src/shell"
import "../src/sim"

// Golden digests: determinism asserted against a committed value.
//
// Every other determinism test in this suite compares one in-process run to
// another -- two worlds, same seed, same script, do they agree. That proves the
// simulation is self-consistent, which is necessary but much weaker than it
// sounds: change nmap's timing, or the tick ordering, or a trace constant, and
// both sides change identically and every one of those tests still passes.
//
// Only `test_pcg32_matches_reference_vector` pinned anything to a literal, and
// it pins the random number generator alone. Nothing pinned what the simulation
// actually *does*.
//
// So: run a fixed script from a fixed seed for a fixed number of ticks, digest
// everything observable, and compare against a number committed to the
// repository. This is what makes "same seed, same world" a claim about the
// project rather than about a single process.
//
// WHEN THIS FAILS: it means simulation behaviour changed. That is sometimes
// intended -- retuning noise, changing a tool's timing -- and then updating the
// literal is correct, and should be its own reviewable line in a diff. What it
// must never be is updated reflexively, because the same failure is what a real
// determinism regression looks like.

// FNV-1a, 64-bit. Hand-rolled for the same reason PCG32 is: a digest committed
// to the repository has to mean the same thing in five years, and a hash from a
// library is free to change representation between releases.
@(private)
FNV_OFFSET :: 0xcbf29ce484222325
@(private)
FNV_PRIME :: 0x100000001b3

@(private)
Digest :: struct {
	h: u64,
}

@(private)
digest_init :: proc() -> Digest {
	return Digest{h = FNV_OFFSET}
}

@(private)
digest_bytes :: proc(d: ^Digest, data: []byte) {
	for b in data {
		d.h ~= u64(b)
		d.h *= FNV_PRIME
	}
}

@(private)
digest_str :: proc(d: ^Digest, s: string) {
	digest_bytes(d, transmute([]byte)s)
	digest_bytes(d, {0}) // separator, so "ab"+"c" and "a"+"bc" differ
}

@(private)
digest_u64 :: proc(d: ^Digest, v: u64) {
	buf: [8]byte
	x := v
	for i in 0 ..< 8 {
		buf[i] = byte(x & 0xff)
		x >>= 8
	}
	digest_bytes(d, buf[:])
}

@(private)
digest_i64 :: proc(d: ^Digest, v: i64) {
	digest_u64(d, u64(v))
}

// Everything observable about a world, in a fixed order.
//
// Iteration is by pool slot throughout, which is the same order the simulation
// itself uses -- a digest that walked a map would hash differently run to run
// and prove nothing.
@(private)
digest_world :: proc(w: ^sim.World, d: ^Digest) {
	digest_u64(d, w.seed)
	digest_u64(d, u64(w.now))
	digest_u64(d, w.rng.state)
	digest_u64(d, w.rng.inc)
	digest_u64(d, u64(w.tag_counter))

	digest_i64(d, i64(w.trace.level))
	digest_i64(d, w.trace.accum)
	digest_u64(d, u64(transmute(u8)w.trace.responses))
	digest_u64(d, u64(w.run.state))
	digest_u64(d, u64(w.run.ended_at))

	it: int
	for sn in sim.pool_iter(&w.subnets, &it) {
		digest_str(d, sn.name)
		digest_u64(d, u64(sn.monitoring))
		digest_i64(d, i64(sn.suspicion))
		digest_u64(d, u64(sn.hot_ticks))
		digest_u64(d, sn.alarmed ? 1 : 0)
	}

	ith: int
	for host in sim.pool_iter(&w.hosts, &ith) {
		digest_str(d, host.hostname)
		digest_u64(d, u64(host.address))
		digest_u64(d, u64(host.access))
		digest_u64(d, u64(host.access_at))
		digest_u64(d, host.discovered ? 1 : 0)
		for svc in host.services {
			digest_u64(d, u64(svc.port))
			digest_u64(d, svc.discovered ? 1 : 0)
		}
		for f in host.files {
			digest_str(d, f.path)
			digest_u64(d, f.found ? 1 : 0)
		}
		for a in host.accounts {
			digest_str(d, a.username)
			digest_str(d, a.password) // the 50% response rewrites these
		}
	}

	for c in w.keyring {
		digest_str(d, c.username)
		digest_str(d, c.password)
	}

	// The noise log carries what was charged and by which command.
	for i in 0 ..< w.noise_log.count {
		r, ok := sim.noise_log_at(w, i)
		if !ok {
			continue
		}
		digest_u64(d, u64(r.at))
		digest_i64(d, i64(r.applied))
		digest_str(d, r.source)
	}
}

// Runs a scripted session against a level and digests both the world and every
// line the player would have seen, including which job produced it.
@(private)
golden_run :: proc(level_id: string, script: []string, extra_ticks: int) -> u64 {
	level, found := campaign.level_by_id(level_id)
	if !found {
		return 0
	}

	w: sim.World
	sim.world_init(&w, 0xCEF5EC)
	defer sim.world_destroy(&w)

	prog: campaign.Progress
	campaign.progress_init(&prog)
	defer campaign.progress_destroy(&prog)
	for &l in campaign.LEVELS {
		if l.number < level.number {
			campaign.mark_complete(&prog, l.id)
		}
	}

	origin := level.build(&w)
	sess: shell.Session
	shell.session_init(&sess, &w, origin, "operator")
	sess.level = level
	sess.progress = &prog
	sess.tools = level.tools
	if !level.trace {
		it: int
		for sn in sim.pool_iter(&w.subnets, &it) {
			sn.monitoring = .None
		}
	}

	d := digest_init()

	drain :: proc(w: ^sim.World, d: ^Digest) {
		for {
			e, ok := sim.ring_pop(&w.events)
			if !ok {
				break
			}
			if l, is_log := e.(sim.Ev_Log); is_log {
				digest_str(d, l.text)
				digest_u64(d, u64(l.job))
			}
		}
	}

	for step in script {
		shell.session_exec(&sess, step)
		for _ in 0 ..< 4000 {
			if !shell.session_active(&sess) && len(w.timers) == 0 {
				break
			}
			sim.tick(&w)
			shell.session_update(&sess)
			drain(&w, &d)
		}
		shell.session_update(&sess)
		drain(&w, &d)
	}

	// Keep ticking past the script, so anything scheduled but unfired -- trace
	// accrual, a hunt step -- is part of the digest too.
	for _ in 0 ..< extra_ticks {
		sim.tick(&w)
		shell.session_update(&sess)
		drain(&w, &d)
	}

	digest_world(&w, &d)
	return d.h
}

// --- the goldens ------------------------------------------------------------

// The full combine level, played the intended way. Covers recon, http, the
// credential chain, the pivot, and the trace system running throughout.
@(test)
test_golden_northwind_playthrough :: proc(t: ^testing.T) {
	GOLDEN :: 0x5a3a4e49ee69460
	got := golden_run(
		"northwind",
		{
			"nmap -sV 10.0.4.0/24",
			"curl http://10.0.4.11/",
			"curl http://10.0.4.11/.env",
			"ssh svc@10.0.4.19",
			"nmap -sn 10.0.9.0/24",
			"ssh svc@10.0.9.10",
			"cat /srv/backup/manifest.sql",
		},
		600,
	)
	testing.expectf(t, got == GOLDEN, "northwind digest changed: got 0x%x, expected 0x%x", got, GOLDEN)
}

// A run loud enough to trip every defender stage, so the goldens cover the
// trace arithmetic, the escalation ladder and the password rotation -- the parts
// most likely to drift silently under retuning.
@(test)
test_golden_a_lost_run :: proc(t: ^testing.T) {
	GOLDEN :: 0x33670519a9e0d2c1
	script := make([dynamic]string, 0, 32, context.temp_allocator)
	append(&script, "nmap -sn 10.0.4.0/24")
	for _ in 0 ..< 24 {
		append(&script, "ssh root@10.0.4.11")
	}
	got := golden_run("northwind", script[:], 60 * 60 * 8)
	testing.expectf(t, got == GOLDEN, "lost-run digest changed: got 0x%x, expected 0x%x", got, GOLDEN)
}

// Background jobs: interleaved output, the gutter, and the scheduler under
// concurrency -- the property M2 was built around.
@(test)
test_golden_concurrent_jobs :: proc(t: ^testing.T) {
	GOLDEN :: 0x9f2b14ca1c076199
	got := golden_run(
		"northwind",
		{"nmap -sV -T2 10.0.4.0/24 &", "curl http://10.0.4.11/.env &", "jobs", "creds"},
		1200,
	)
	testing.expectf(t, got == GOLDEN, "concurrent-jobs digest changed: got 0x%x, expected 0x%x", got, GOLDEN)
}
