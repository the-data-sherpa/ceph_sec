package tests

import "core:strings"
import "core:testing"
import "../src/shell"
import "../src/sim"

// Suspicion and trace. Fixture and helpers come from shell_test.odin and
// job_test.odin -- same package.
//
// Charge figures are asserted as exact literals, never ranges. These numbers are
// the game's difficulty, and a range would let a retuning slide past silently.

@(private)
suspicion_of :: proc(f: ^Fixture, sn: sim.Handle(sim.Subnet)) -> i32 {
	s, ok := sim.pool_get(&f.w.subnets, sn)
	if !ok {
		return 0
	}
	return s.suspicion
}

@(private)
noise_events :: proc(f: ^Fixture) -> []sim.Ev_Noise {
	out := make([dynamic]sim.Ev_Noise, 0, 8, context.temp_allocator)
	for {
		e, ok := sim.ring_pop(&f.w.events)
		if !ok {
			break
		}
		if n, is_noise := e.(sim.Ev_Noise); is_noise {
			append(&out, n)
		}
	}
	return out[:]
}

// --- charging ---------------------------------------------------------------

// nmap -sV is 22 units; the DMZ is Low, which is a gain of 60%. So
// 22 * 100 * 60 / 100 == 1320 hundredths == 13.20.
@(test)
test_noise_scales_by_monitoring :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	run(&f, "nmap -sV 10.0.4.0/24")

	events := noise_events(&f)
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0].units, i32(shell.NOISE_NMAP_VERSION))
	testing.expect_value(t, events[0].applied, i32(1320))
	testing.expect_value(t, suspicion_of(&f, f.dmz), i32(1320))
}

// A sweep of a /24 pays for one scan of the segment, not one per host. Charging
// per host would make any sweep instantly fatal and make the documented
// per-scan figures meaningless.
@(test)
test_a_sweep_charges_the_segment_once :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	// The DMZ fixture holds two hosts; both are scanned.
	run(&f, "nmap -sV 10.0.4.0/24")
	testing.expect_value(t, len(noise_events(&f)), 1)
	testing.expect_value(t, suspicion_of(&f, f.dmz), i32(1320))
}

// Your own box is unwatched, and that is a real property rather than a small
// number: nothing you do on it is ever charged.
@(test)
test_your_own_segment_is_free :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	run(&f, "ls /")
	run(&f, "pwd")
	run(&f, "whoami")
	testing.expect_value(t, len(noise_events(&f)), 0)
}

// "Failed actions are far louder than successful ones" -- the one line in
// design.md section 5 that most shapes how the game plays.
@(test)
test_failure_is_louder_than_success :: proc(t: ^testing.T) {
	failed: Fixture
	fixture(&failed)
	defer fixture_destroy(&failed)

	run(&failed, "nmap -sn 10.0.4.0/24")
	transcript(&failed)
	run(&failed, "ssh svc@10.0.4.19") // no credential held
	fail_events := noise_events(&failed)

	ok_run: Fixture
	fixture(&ok_run)
	defer fixture_destroy(&ok_run)

	sim.keyring_add(&ok_run.w, {username = "svc", password = PASSWORD, note = "seed"})
	run(&ok_run, "nmap -sn 10.0.4.0/24")
	transcript(&ok_run)
	run(&ok_run, "ssh svc@10.0.4.19") // succeeds
	ok_events := noise_events(&ok_run)

	testing.expect_value(t, len(fail_events), 1)
	testing.expect_value(t, len(ok_events), 1)
	testing.expect_value(t, fail_events[0].units, i32(shell.NOISE_SSH_FAILED))
	testing.expect_value(t, ok_events[0].units, i32(shell.NOISE_SSH))
	testing.expect(t, fail_events[0].applied > ok_events[0].applied * 3, "failure should be far louder")
}

// Anything that never left your own box is free. Being merciful about blind
// probing also avoids inventing a rule for which segment gets the bill when
// nothing answered.
@(test)
test_unreached_targets_are_free :: proc(t: ^testing.T) {
	free_lines := []string {
		"nmap not-an-address",     // never parsed
		"nmap -sV 10.0.9.0/24",    // no route to that segment at all
		"curl http://nosuchbox/",  // unresolvable
		"ssh svc@nosuchbox",       // unresolvable
		"curl http://10.0.9.10/",  // known of, but no route
		"ssh svc@10.0.9.10",       // same
	}

	for line in free_lines {
		f: Fixture
		fixture(&f)
		defer fixture_destroy(&f)

		sim.keyring_add(&f.w, {username = "svc", password = PASSWORD, note = "seed"})
		run(&f, "nmap -sn 10.0.4.0/24")
		transcript(&f)

		run(&f, line)
		events := noise_events(&f)
		testing.expectf(t, len(events) == 0, "%q should have been free, charged %d times", line, len(events))
	}
}

// But reaching a box and being refused is not free -- that is a line in their
// log, and the distinction is the point.
@(test)
test_reaching_a_box_and_failing_costs :: proc(t: ^testing.T) {
	charged_lines := []string {
		"curl http://10.0.4.11/nope", // 404 in their access log
		"curl http://10.0.4.19/",     // connection refused
		"ssh root@10.0.4.11",         // failed auth
	}

	for line in charged_lines {
		f: Fixture
		fixture(&f)
		defer fixture_destroy(&f)

		run(&f, "nmap -sn 10.0.4.0/24")
		transcript(&f)

		run(&f, line)
		events := noise_events(&f)
		testing.expectf(t, len(events) == 1, "%q should have charged once, got %d", line, len(events))
	}
}

// Taking the objective must not be silent, or the last third of a run has no
// stakes at all. The one exception to "builtins are free".
@(test)
test_reading_sensitive_material_costs :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	sim.keyring_add(&f.w, {username = "svc", password = PASSWORD, note = "seed"})
	run(&f, "nmap -sn 10.0.4.0/24")
	run(&f, "ssh svc@10.0.4.11")
	transcript(&f)

	run(&f, "cat /home/svc/.bash_history") // ordinary file
	testing.expect_value(t, len(noise_events(&f)), 0)

	run(&f, "cat /home/svc/deploy.env") // sensitive
	events := noise_events(&f)
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0].units, i32(shell.NOISE_READ_SENSITIVE))
}

// --- offline commands -------------------------------------------------------

// Every command declared offline must actually be free, and every tool that is
// not must actually charge on its success path. Asserted over the registry, so
// a tool that forgets to file a slip fails the build rather than being quietly
// free forever.
@(test)
test_offline_commands_are_free :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	sim.keyring_add(&f.w, {username = "svc", password = PASSWORD, note = "seed"})
	run(&f, "nmap -sn 10.0.4.0/24")
	transcript(&f)
	noise_events(&f)

	for spec in shell.COMMANDS {
		if !spec.offline || spec.name == "exit" || spec.name == "clear" {
			continue
		}
		run(&f, spec.name)
		events := noise_events(&f)
		testing.expectf(t, len(events) == 0, "offline command %q charged noise", spec.name)
	}
	testing.expect_value(t, f.w.trace.level, i32(0))
}

@(test)
test_every_tool_charges_on_success :: proc(t: ^testing.T) {
	Success :: struct {
		name, line: string,
	}
	successes := []Success {
		{"nmap", "nmap -sV 10.0.4.0/24"},
		{"curl", "curl http://10.0.4.11/.env"},
		{"ssh", "ssh svc@10.0.4.11"},
	}

	// Every job-bearing, non-offline command must appear above.
	expected := 0
	for spec in shell.COMMANDS {
		if spec.job && !spec.offline {
			expected += 1
		}
	}
	testing.expect_value(t, len(successes), expected)

	for s in successes {
		f: Fixture
		fixture(&f)
		defer fixture_destroy(&f)

		sim.keyring_add(&f.w, {username = "svc", password = PASSWORD, note = "seed"})
		run(&f, "nmap -sn 10.0.4.0/24")
		transcript(&f)
		noise_events(&f)

		run(&f, s.line)
		events := noise_events(&f)
		testing.expectf(t, len(events) >= 1, "%s charged nothing on its success path", s.name)
	}
}

// --- decay ------------------------------------------------------------------

@(test)
test_decay_waits_for_the_grace_period :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	// Measured at dispatch, not after the scan finishes: noise is charged the
	// moment the command is issued, and a -sV sweep runs for longer than the
	// grace period -- so by the time it completes, decay has already begun.
	shell.session_exec(&f.sess, "nmap -sV 10.0.4.0/24")
	charged := suspicion_of(&f, f.dmz)
	testing.expect_value(t, charged, i32(1320))

	at_charge := f.w.now
	for f.w.now - at_charge < sim.SUSPICION_GRACE - 1 {
		sim.tick(&f.w)
	}
	testing.expect_value(t, suspicion_of(&f, f.dmz), charged)

	sim.tick(&f.w)
	testing.expect_value(t, suspicion_of(&f, f.dmz), charged - sim.SUSPICION_DECAY)
}

@(test)
test_decay_clamps_at_zero :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	run(&f, "nmap -sn 10.0.4.0/24")
	testing.expect(t, suspicion_of(&f, f.dmz) > 0)

	sim.tick_n(&f.w, 60 * 60) // a minute of quiet: far more than enough
	testing.expect_value(t, suspicion_of(&f, f.dmz), i32(0))
}

// A fresh charge restarts the grace window, so a steady drip never gets to
// decay -- which is what makes sustained noise different from one loud action.
@(test)
test_a_new_charge_restarts_the_grace_window :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	run(&f, "nmap -sn 10.0.4.0/24")
	sim.tick_n(&f.w, int(sim.SUSPICION_GRACE) + 120) // let it decay a while
	decayed := suspicion_of(&f, f.dmz)

	// Charged at dispatch, so read it before the scan has run any further.
	shell.session_exec(&f.sess, "nmap -sn 10.0.4.0/24")
	after := suspicion_of(&f, f.dmz)
	testing.expect(t, after > decayed, "the second scan should have added")

	// Immediately after a charge, no decay for a full grace period.
	at_charge := f.w.now
	for f.w.now - at_charge < sim.SUSPICION_GRACE - 1 {
		sim.tick(&f.w)
	}
	testing.expect_value(t, suspicion_of(&f, f.dmz), after)
}

// Decay is arithmetic inside tick(), never scheduled work. A timer per segment
// per tick would turn the linear timer scan into a per-tick sweep of thousands.
@(test)
test_decay_schedules_nothing :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	run(&f, "nmap -sV 10.0.4.0/24")
	settle(&f)
	testing.expect_value(t, len(f.w.timers), 0)

	sim.tick_n(&f.w, 60 * 120)
	testing.expect_value(t, len(f.w.timers), 0)
}

// --- trace ------------------------------------------------------------------

@(private)
pin_segment :: proc(f: ^Fixture, sn: sim.Handle(sim.Subnet), to: i32) {
	s, ok := sim.pool_get(&f.w.subnets, sn)
	if ok {
		s.suspicion = to
		s.last_charge_at = f.w.now
	}
}

@(private)
stage_events :: proc(f: ^Fixture) -> []sim.Trace_Stage {
	out := make([dynamic]sim.Trace_Stage, 0, 4, context.temp_allocator)
	for {
		e, ok := sim.ring_pop(&f.w.events)
		if !ok {
			break
		}
		if st, is_stage := e.(sim.Ev_Trace_Stage); is_stage {
			append(&out, st.stage)
		}
	}
	return out[:]
}

// The property that makes being caught fair: with every segment below the alarm
// line, the trace provably cannot move. Ten simulated minutes of repeated
// sub-threshold noise must leave it at exactly zero.
@(test)
test_quiet_work_can_never_lose_the_run :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	for _ in 0 ..< 12 {
		run(&f, "nmap -sn 10.0.4.0/24")
		settle(&f)
		sim.tick_n(&f.w, 60 * 45) // let it bleed back down
		testing.expect(t, suspicion_of(&f, f.dmz) < sim.SUSPICION_ALARM, "stayed under the line")
	}

	testing.expect_value(t, f.w.trace.level, i32(0))
	testing.expect_value(t, f.w.run.state, sim.Run_State.Running)
}

@(test)
test_trace_rises_only_while_a_segment_is_hot :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	pin_segment(&f, f.dmz, sim.SUSPICION_ALARM + 2000)
	sim.tick_n(&f.w, 120)
	hot := f.w.trace.level
	testing.expect(t, hot > 0, "trace should climb while a segment is over the line")

	// Drop it back under and the trace holds -- it never falls.
	pin_segment(&f, f.dmz, 100)
	sim.tick_n(&f.w, 60 * 60)
	testing.expect_value(t, f.w.trace.level, hot)
}

// Integer division must lose nothing, so a pinned segment reaches the same
// trace whether the ticks were delivered in one batch or many.
@(test)
test_trace_accumulator_is_batch_invariant :: proc(t: ^testing.T) {
	a, b: Fixture
	fixture(&a)
	fixture(&b)
	defer fixture_destroy(&a)
	defer fixture_destroy(&b)

	pin_segment(&a, a.dmz, sim.SUSPICION_ALARM + 1337)
	pin_segment(&b, b.dmz, sim.SUSPICION_ALARM + 1337)

	sim.tick_n(&a.w, 600)
	for _ in 0 ..< 6 {
		sim.tick_n(&b.w, 100)
	}

	testing.expect(t, a.w.trace.level > 0)
	testing.expect_value(t, a.w.trace.level, b.w.trace.level)
	testing.expect_value(t, a.w.trace.accum, b.w.trace.accum)
}

@(test)
test_alarm_edges_announce_once :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	pin_segment(&f, f.dmz, sim.SUSPICION_ALARM + 500)
	sim.tick_n(&f.w, 10)

	ons, offs := 0, 0
	count :: proc(f: ^Fixture, ons, offs: ^int) {
		for {
			e, ok := sim.ring_pop(&f.w.events)
			if !ok {
				break
			}
			if a, is_alarm := e.(sim.Ev_Trace_Alarm); is_alarm {
				if a.on {
					ons^ += 1
				} else {
					offs^ += 1
				}
			}
		}
	}
	count(&f, &ons, &offs)
	testing.expect_value(t, ons, 1)
	testing.expect_value(t, offs, 0)

	pin_segment(&f, f.dmz, 0)
	sim.tick_n(&f.w, 10)
	ons, offs = 0, 0
	count(&f, &ons, &offs)
	testing.expect_value(t, ons, 0)
	testing.expect_value(t, offs, 1)
}

// A single jump from nothing to attributed must still fire all four stages, in
// order -- latched, not sampled.
@(test)
test_all_stages_fire_once_in_order :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	sim.trace_advance(&f.w, sim.TRACE_MAX)
	stages := stage_events(&f)

	testing.expect_value(t, len(stages), 4)
	testing.expect_value(t, stages[0], sim.Trace_Stage.Review)
	testing.expect_value(t, stages[1], sim.Trace_Stage.Alert)
	testing.expect_value(t, stages[2], sim.Trace_Stage.Hunt)
	testing.expect_value(t, stages[3], sim.Trace_Stage.Attributed)
	testing.expect_value(t, f.w.run.state, sim.Run_State.Caught)

	// Nothing fires twice.
	sim.trace_advance(&f.w, sim.TRACE_MAX)
	testing.expect_value(t, len(stage_events(&f)), 0)
}

@(test)
test_review_raises_monitoring_where_you_were_noisy :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	run(&f, "nmap -sn 10.0.4.0/24") // DMZ only
	transcript(&f)

	dmz, _ := sim.pool_get(&f.w.subnets, f.dmz)
	corp, _ := sim.pool_get(&f.w.subnets, f.corp)
	before_dmz, before_corp := dmz.monitoring, corp.monitoring

	sim.trace_advance(&f.w, sim.TRACE_REVIEW)

	testing.expect_value(t, dmz.monitoring, sim.monitoring_next(before_dmz))
	// A segment you never touched is not re-evaluated.
	testing.expect_value(t, corp.monitoring, before_corp)

	// And the same action now costs more.
	noise_events(&f)
	run(&f, "nmap -sn 10.0.4.0/24")
	after := noise_events(&f)
	testing.expect_value(t, after[0].applied, i32(shell.NOISE_NMAP_PING) * 100 * sim.monitoring_gain(dmz.monitoring) / 100)
}

// The response most likely to brick a run, and the reason `Stranded` could be
// left out of scope honestly. Rotation must kick you off a box you hold without
// invalidating the credential everywhere else.
@(test)
test_alert_does_not_make_the_run_unwinnable :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	sim.keyring_add(&f.w, {username = "svc", password = PASSWORD, note = "seed"})
	run(&f, "nmap -sn 10.0.4.0/24")
	run(&f, "ssh svc@10.0.4.11") // hold web01
	transcript(&f)

	held := len(f.w.keyring)
	sim.trace_advance(&f.w, sim.TRACE_ALERT)
	shell.session_update(&f.sess)

	// Kicked off web01...
	web, _ := sim.pool_get(&f.w.hosts, f.web)
	testing.expect_value(t, web.access, sim.Access.None)
	testing.expect(t, web.accounts[0].password != PASSWORD, "that host's password should have rotated")

    // ...but the credential itself is untouched, and still opens everything
    // you have not reached yet. That is what keeps the objective reachable.
	testing.expect_value(t, len(f.w.keyring), held)
	testing.expect_value(t, f.w.keyring[0].password, PASSWORD)

	jump, _ := sim.pool_get(&f.w.hosts, f.jump)
	testing.expect_value(t, jump.accounts[0].password, PASSWORD)

	transcript(&f)
	run(&f, "ssh svc@10.0.4.19")
	testing.expect_value(t, f.sess.host, f.jump)
	testing.expect(t, sim.subnet_reachable(&f.w, f.corp), "the path to the objective must survive")
}

@(test)
test_hunt_takes_footholds_newest_first :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	sim.keyring_add(&f.w, {username = "svc", password = PASSWORD, note = "seed"})
	run(&f, "nmap -sn 10.0.4.0/24")
	run(&f, "ssh svc@10.0.4.11") // web01 first
	run(&f, "ssh svc@10.0.4.19") // jump01 second, so newest
	transcript(&f)

	// Isolate the hunt. Advancing to 75% also fires Review and Alert, and Alert
	// revokes a foothold of its own -- which would leave nothing to observe here.
	// Latching them as already-fired keeps this test about the hunt.
	f.w.trace.responses += {.Review, .Alert}

	sim.trace_advance(&f.w, sim.TRACE_HUNT)
	testing.expect(t, f.w.hunt_tag != 0, "the hunt needs a real tag; 0 is unmatched by cancel_tag")

	sim.tick_n(&f.w, int(sim.HUNT_INTERVAL) + 2)
	jump, _ := sim.pool_get(&f.w.hosts, f.jump)
	web, _ := sim.pool_get(&f.w.hosts, f.web)
	testing.expect_value(t, jump.access, sim.Access.None) // newest went first
	testing.expect(t, web.access != .None, "the older foothold survives the first step")

	sim.tick_n(&f.w, int(sim.HUNT_INTERVAL) + 2)
	testing.expect_value(t, web.access, sim.Access.None)

	// It never takes your own box, and it keeps rescheduling.
	sim.tick_n(&f.w, int(sim.HUNT_INTERVAL) * 3)
	origin, _ := sim.pool_get(&f.w.hosts, f.origin)
	testing.expect_value(t, origin.access, sim.Access.Root)
	testing.expect(t, len(f.w.timers) > 0, "the hunt should still be scheduled")
}

// The emergent moment the hunt exists to produce: your scan dies because they
// killed the box you were running it through.
@(test)
test_hunt_severs_in_flight_jobs :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	sim.keyring_add(&f.w, {username = "svc", password = PASSWORD, note = "seed"})
	run(&f, "nmap -sn 10.0.4.0/24")
	run(&f, "ssh svc@10.0.4.19") // root on jump01 opens CORP
	testing.expect(t, sim.subnet_reachable(&f.w, f.corp))
	transcript(&f)

	// A scan of CORP, launched from jump01 and running in the background.
	shell.session_exec(&f.sess, "nmap -sV 10.0.9.0/24 &")
	testing.expect_value(t, shell.slots_in_use(&f.sess), 1)
	step(&f, 20)

	// They take the pivot.
	sim.revoke_access(&f.w, f.jump, .None)
	shell.session_update(&f.sess)

	testing.expect_value(t, shell.slots_in_use(&f.sess), 0)
	testing.expect(t, strings.contains(transcript(&f), "lost"), "the job should say why it died")

	// And nothing behind the severed route was ever discovered.
	settle(&f)
	fs, _ := sim.pool_get(&f.w.hosts, f.fs)
	testing.expect(t, !fs.discovered, "a severed scan must not keep finding hosts")
}

// Without this the headline defender response is cosmetic: you keep a shell on
// a box you no longer hold, and can still read the objective off it.
@(test)
test_losing_a_host_evicts_the_prompt :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	sim.keyring_add(&f.w, {username = "svc", password = PASSWORD, note = "seed"})
	run(&f, "nmap -sn 10.0.4.0/24")
	run(&f, "ssh svc@10.0.4.11")
	testing.expect_value(t, f.sess.host, f.web)
	transcript(&f)

	sim.revoke_access(&f.w, f.web, .None)

	// revoke_access is a mutator in the grant_access mould: it changes the world
	// and emits its own event, so the two cannot drift. The frontend does not
	// render this one -- the hunt and the alert narrate their own actions -- but
	// it is the record a net map will read, and it must carry what was lost.
	lost := 0
	for {
		e, ok := sim.ring_pop(&f.w.events)
		if !ok {
			break
		}
		if ev, is_lost := e.(sim.Ev_Access_Lost); is_lost {
			lost += 1
			testing.expect_value(t, ev.host, f.web)
			testing.expect_value(t, ev.was, sim.Access.User)
		}
	}
	testing.expect_value(t, lost, 1)

	// Revoking again is a no-op: access only ever moves down to a level it is
	// not already at, mirroring grant_access only ever ratcheting up.
	sim.revoke_access(&f.w, f.web, .None)
	shell.session_update(&f.sess)

	again := 0
	saw_eviction := false
	for {
		e, ok := sim.ring_pop(&f.w.events)
		if !ok {
			break
		}
		#partial switch ev in e {
		case sim.Ev_Access_Lost:
			again += 1
		case sim.Ev_Log:
			if strings.contains(ev.text, "closed by remote host") {
				saw_eviction = true
			}
		}
	}
	testing.expect_value(t, again, 0)
	testing.expect(t, saw_eviction, "the player should be told why the prompt moved")

	testing.expect_value(t, f.sess.host, f.origin)
	testing.expect_value(t, f.sess.user, "operator")
}

// --- reset and determinism --------------------------------------------------

// A field added to World and forgotten in world_bind holds a stale arena
// pointer across a reset -- a use-after-free that would surface as corruption
// on the *second* run, which is close to undiagnosable from the symptom. This
// asserts every piece of M2 state, not just the ones that were easy to reach.
@(test)
test_world_reset_clears_all_trace_state :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	// Make every one of them non-zero.
	run(&f, "nmap -sV 10.0.4.0/24")
	pin_segment(&f, f.dmz, sim.SUSPICION_ALARM + 3000)
	sim.tick_n(&f.w, 300)
	sim.trace_advance(&f.w, sim.TRACE_HUNT)
	sim.end_run(&f.w, .Caught)

	testing.expect(t, f.w.trace.level > 0)
	testing.expect(t, f.w.noise_log.count > 0)
	testing.expect(t, f.w.hunt_tag != 0)
	testing.expect(t, f.w.trace.responses != {})

	sim.world_reset(&f.w, 99)

	testing.expect_value(t, f.w.trace.level, i32(0))
	testing.expect_value(t, f.w.trace.accum, i64(0))
	testing.expect_value(t, f.w.trace.responses, bit_set[sim.Trace_Stage]{})
	testing.expect_value(t, f.w.hunt_tag, u32(0))
	testing.expect_value(t, f.w.noise_log.count, 0)
	testing.expect_value(t, f.w.noise_log.head, 0)
	testing.expect_value(t, f.w.run.state, sim.Run_State.Running)
	testing.expect_value(t, f.w.run.ended_at, sim.Tick(0))
	testing.expect_value(t, len(f.w.due), 0)
	testing.expect_value(t, len(f.w.timers), 0)
	testing.expect_value(t, f.w.tag_counter, u32(0))
	testing.expect_value(t, sim.pool_len(&f.w.subnets), 0) // segments go with the arena
}

// Seed determinism, extended through the whole trace system. Two worlds given
// the same seed and the same commands must agree on every number, including
// after all four defender responses have fired.
@(test)
test_same_seed_reproduces_trace_and_responses :: proc(t: ^testing.T) {
	drive :: proc(f: ^Fixture) {
		run(f, "nmap -sn 10.0.4.0/24")
		for _ in 0 ..< 20 {
			if sim.run_over(&f.w) {
				break
			}
			run(f, "ssh root@10.0.4.11")
		}
		for _ in 0 ..< 60 * 60 * 6 {
			if sim.run_over(&f.w) {
				break
			}
			sim.tick(&f.w)
			shell.session_update(&f.sess)
		}
	}

	a, b: Fixture
	fixture(&a)
	fixture(&b)
	defer fixture_destroy(&a)
	defer fixture_destroy(&b)

	drive(&a)
	drive(&b)

	testing.expect_value(t, a.w.run.state, b.w.run.state)
	testing.expect_value(t, a.w.run.ended_at, b.w.run.ended_at)
	testing.expect_value(t, a.w.trace.level, b.w.trace.level)
	testing.expect_value(t, a.w.trace.accum, b.w.trace.accum)
	testing.expect_value(t, a.w.trace.responses, b.w.trace.responses)
	testing.expect_value(t, a.w.now, b.w.now)
	testing.expect_value(t, a.w.tag_counter, b.w.tag_counter)
	testing.expect_value(t, a.w.noise_log.count, b.w.noise_log.count)

	ita, itb: int
	for {
		sa, ha, oka := sim.pool_iter(&a.w.subnets, &ita)
		sb, hb, okb := sim.pool_iter(&b.w.subnets, &itb)
		if !oka || !okb {
			testing.expect_value(t, oka, okb)
			break
		}
		testing.expect_value(t, ha, hb)
		testing.expect_value(t, sa.suspicion, sb.suspicion)
		testing.expect_value(t, sa.hot_ticks, sb.hot_ticks)
		testing.expect_value(t, sa.monitoring, sb.monitoring)
		testing.expect_value(t, sa.alarmed, sb.alarmed)
	}

	// The defender responses consume no randomness, so the generator's stream is
	// independent of how the player played. That is what keeps a seed a
	// description of the *world* rather than of the session -- and it means a
	// future replay feature needs no input log.
	quiet: Fixture
	fixture(&quiet)
	defer fixture_destroy(&quiet)
	testing.expect_value(t, a.w.rng, quiet.w.rng)
	testing.expect(t, a.w.trace.responses != {}, "the driven run should have escalated")
}

// --- acceptance -------------------------------------------------------------
//
// These two decide whether the numbers are right, and they are the pair worth
// running after any retuning. One says the designed route is survivable; the
// other says the run can actually be lost. Either failing means the tuning is
// wrong, not that the test is.

// The intended path, played straight, must never come close to losing. If a
// change to the noise tables makes the designed route lethal, this says so.
@(test)
test_the_intended_route_is_survivable :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	route := []string {
		"nmap -sV 10.0.4.0/24",
		"curl http://10.0.4.11/",
		"curl http://10.0.4.11/.env",
		"ssh svc@10.0.4.19",
		"nmap -sn 10.0.9.0/24",
		"ssh svc@10.0.9.10",
		"cat /srv/backup/manifest.sql",
	}

	peak_dmz, peak_corp: i32
	for line in route {
		run(&f, line)
		peak_dmz = max(peak_dmz, suspicion_of(&f, f.dmz))
		peak_corp = max(peak_corp, suspicion_of(&f, f.corp))
	}

	testing.expectf(
		t,
		peak_dmz < sim.SUSPICION_ALARM,
		"the DMZ peaked at %d, over the %d alarm line -- the designed route is lethal",
		peak_dmz,
		sim.SUSPICION_ALARM,
	)
	testing.expectf(
		t,
		peak_corp < sim.SUSPICION_ALARM,
		"CORP peaked at %d, over the %d alarm line",
		peak_corp,
		sim.SUSPICION_ALARM,
	)

	// Never alarmed, so the trace never moved, so nothing could escalate.
	testing.expect_value(t, f.w.trace.level, i32(0))
	testing.expect_value(t, f.w.trace.responses, bit_set[sim.Trace_Stage]{})

	dmz, _ := sim.pool_get(&f.w.subnets, f.dmz)
	testing.expect_value(t, dmz.hot_ticks, sim.Tick(0))
}

// And the run can be lost. Repeated failed logins in one segment -- each one a
// line in their auth log, each one resetting the decay grace -- push the DMZ
// over the line and keep it there until the trace runs out.
@(test)
test_a_sloppy_run_is_lost :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	run(&f, "nmap -sn 10.0.4.0/24")
	transcript(&f)

	// Failed logins at 12.00 each (20 units, Low gain 60%), hammered without
	// pause. Each one resets the decay grace, so the segment stays pinned above
	// the line instead of bleeding back under -- which is the difference
	// between one loud mistake and a sustained one.
	attempts := 0
	for attempts < 60 && !sim.run_over(&f.w) {
		run(&f, "ssh root@10.0.4.11")
		attempts += 1
		if attempts == 6 {
			testing.expect(
				t,
				suspicion_of(&f, f.dmz) > sim.SUSPICION_ALARM,
				"six failed logins should already be over the line",
			)
		}
	}

	testing.expect_value(t, f.w.run.state, sim.Run_State.Caught)
	testing.expect_value(t, f.w.trace.level, sim.TRACE_MAX)
	testing.expect_value(t, f.w.trace.responses, bit_set[sim.Trace_Stage]{.Review, .Alert, .Hunt, .Attributed})

	// The capture is attributable: a specific segment sat visibly hot for a
	// recorded length of time.
	dmz, _ := sim.pool_get(&f.w.subnets, f.dmz)
	testing.expect(t, dmz.hot_ticks > 0, "the DMZ should have logged time above the line")

	// And the bill names what did it.
	blamed := false
	for i in 0 ..< f.w.noise_log.count {
		r, ok := sim.noise_log_at(&f.w, i)
		if ok && strings.contains(r.source, "ssh root@10.0.4.11") {
			blamed = true
		}
	}
	testing.expect(t, blamed, "the noise log should name the command responsible")
}

// The other half of the balance, and the reason a single mistake is not fatal:
// one burst of noise is survivable, because decay pulls the segment back under
// the line within seconds. But the trace it bought never comes back -- so
// bursts accumulate, and enough of them still lose the run.
@(test)
test_a_burst_is_survivable_but_never_free :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	run(&f, "nmap -sn 10.0.4.0/24")
	transcript(&f)

	for _ in 0 ..< 6 {
		run(&f, "ssh root@10.0.4.11")
	}
	testing.expect(t, suspicion_of(&f, f.dmz) > sim.SUSPICION_ALARM)

	// Stop, and wait it out.
	sim.tick_n(&f.w, 60 * 120)
	testing.expect_value(t, suspicion_of(&f, f.dmz), i32(0))
	testing.expect_value(t, f.w.run.state, sim.Run_State.Running)

	// Survived -- but it was not free, and the cost is permanent.
	after_burst := f.w.trace.level
	testing.expect(t, after_burst > 0, "time above the line should have cost trace")

	sim.tick_n(&f.w, 60 * 300)
	testing.expect_value(t, f.w.trace.level, after_burst) // never falls
}

// --- -T2 --------------------------------------------------------------------

// The loud-fast versus quiet-slow choice, and the reason backgrounding a scan
// is worth doing.
@(test)
test_t2_is_slower_and_quieter :: proc(t: ^testing.T) {
	fast: Fixture
	fixture(&fast)
	defer fixture_destroy(&fast)

	shell.session_exec(&fast.sess, "nmap -sV 10.0.4.0/24")
	fast_job, _ := shell.job_by_id(&fast.sess, fast.sess.next_job_id)
	fast_span := fast_job.ends_at - fast_job.started_at
	settle(&fast)
	fast_noise := noise_events(&fast)

	slow: Fixture
	fixture(&slow)
	defer fixture_destroy(&slow)

	shell.session_exec(&slow.sess, "nmap -sV -T2 10.0.4.0/24")
	slow_job, _ := shell.job_by_id(&slow.sess, slow.sess.next_job_id)
	slow_span := slow_job.ends_at - slow_job.started_at
	settle(&slow)
	slow_noise := noise_events(&slow)

	testing.expect(t, slow_span > fast_span * 2, "-T2 should take substantially longer")
	testing.expect_value(t, fast_noise[0].units, i32(shell.NOISE_NMAP_VERSION))
	testing.expect_value(t, slow_noise[0].units, i32(shell.NOISE_NMAP_VERSION / shell.T2_NOISE_DIV))
	testing.expect(t, slow_noise[0].applied < fast_noise[0].applied, "-T2 should be quieter")

	// And it still finds everything -- quiet, not blind.
	web, _ := sim.pool_get(&slow.w.hosts, slow.web)
	testing.expect(t, web.discovered)
	testing.expect(t, web.services[0].discovered)
}
