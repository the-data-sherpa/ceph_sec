package tests

import "core:strings"
import "core:testing"
import "../src/campaign"
import "../src/shell"
import "../src/sim"

// The tick loop, and the one rule it exists to enforce.
//
// `play` and `retry` are builtins. They cannot perform a level change
// themselves, because the change frees the arena the session's own strings live
// in -- so they record the intent and the frame loop carries it out between
// frames. The accumulator, meanwhile, went right on ticking:
//
//     for accumulator >= TICK_DT {
//         sim.tick(&w)          <- still the OLD world
//         ...
//     }
//     ... transition happens here, after the loop ...
//
// One extra tick at 60fps, about two at 30, and up to fifteen after a stall long
// enough to hit the clamp. Every one of them ran suspicion_tick and trace_tick
// and fired any timer that came due, against a world already condemned -- so how
// much a doomed level charged you, and whether a pending timer landed, depended
// on the frame rate. That is exactly the frame quantisation the comment above
// that loop said the determinism guarantee forbids.
//
// It matters more now than it did: a replay records the tick a transition
// happened on, so a transition tick that moves with the frame rate is a replay
// that cannot be reproduced anywhere but the machine that recorded it.

@(private)
Play_At :: struct {
	at:   sim.Tick,
	text: string,
	done: bool,
}

// Submits a line on a chosen tick, from inside the tick loop -- the same
// position main's `--exec` feeder and a replay's entries occupy.
@(private)
play_at_hook :: proc(user: rawptr, s: ^shell.Session) {
	f := (^Play_At)(user)
	if f.done || s.world.now < f.at {
		return
	}
	f.done = true
	shell.session_submit_text(s, f.text)
}

@(test)
test_a_pending_transition_stops_the_tick_loop :: proc(t: ^testing.T) {
	level, _ := campaign.level_by_id("recon-sweep")

	p: Play
	play_open(&p, level)
	defer play_close(&p)

	// Finish level 1 and record it, so `play 2` is not refused as locked.
	play_do(&p, "nmap -sn 10.0.4.0/24")
	campaign.mark_complete(&p.prog, level.id)
	play_transcript(&p)

	before := p.w.now

	// A timer due two ticks after the transition is asked for. If the loop keeps
	// going, this fires into a world that is about to be thrown away.
	sim.log_at(&p.w, 12, "TIMER FIRED")

	feed := Play_At {
		at   = before + 10,
		text = "play 2",
	}
	pump: shell.Pump
	// A quarter-second frame: the clamp's worth of budget, fifteen whole ticks.
	shell.pump_frame(&pump, &p.sess, 0.25, shell.Tick_Hook{fn = play_at_hook, user = &feed})

	testing.expect(t, pump.transition, "the pump should report the pending transition")
	testing.expectf(
		t,
		p.w.now == before + 10,
		"the world must stop on the transition tick: expected %d, got %d",
		u64(before + 10),
		u64(p.w.now),
	)
	testing.expect_value(t, pump.ticks, 10)
	// The rest of the budget was accrued against the world being replaced, so it
	// must not be spent on the level the player has not seen a frame of yet.
	testing.expect_value(t, pump.accumulator, 0)

	text := play_transcript(&p)
	testing.expect(
		t,
		!strings.contains(text, "TIMER FIRED"),
		"a timer past the transition tick must not fire into a condemned world",
	)
}

// The control: with nothing asking for a level change, the same frame runs its
// full budget and the same timer does fire. Without this the test above would
// still pass if pump_frame simply never ticked.
@(test)
test_an_ordinary_frame_runs_its_whole_budget :: proc(t: ^testing.T) {
	level, _ := campaign.level_by_id("recon-sweep")

	p: Play
	play_open(&p, level)
	defer play_close(&p)

	before := p.w.now
	sim.log_at(&p.w, 12, "TIMER FIRED")

	pump: shell.Pump
	shell.pump_frame(&pump, &p.sess, 0.25)

	testing.expect(t, !pump.transition)
	testing.expect_value(t, pump.ticks, 15)
	testing.expect_value(t, u64(p.w.now), u64(before) + 15)
	testing.expect(t, strings.contains(play_transcript(&p), "TIMER FIRED"))
}

// One long stall must not queue thousands of ticks: simulating them takes longer
// than the stall did, which queues more, which is the spiral of death.
@(test)
test_a_long_frame_is_clamped :: proc(t: ^testing.T) {
	level, _ := campaign.level_by_id("recon-sweep")

	p: Play
	play_open(&p, level)
	defer play_close(&p)

	pump: shell.Pump
	shell.pump_frame(&pump, &p.sess, 30.0)
	testing.expect_value(t, pump.ticks, int(shell.MAX_FRAME_DT * 60))
}

// A transition still pending at the top of a frame means the caller has not
// performed it. Ticking anyway is the same bug approached from the other side.
@(test)
test_a_frame_refuses_to_tick_into_a_pending_transition :: proc(t: ^testing.T) {
	level, _ := campaign.level_by_id("access-exposure")

	p: Play
	play_open(&p, level)
	defer play_close(&p)

	shell.session_exec(&p.sess, "retry")
	_, wants := p.sess.pending_transition.?
	testing.expect(t, wants, "retry should schedule a transition")

	before := p.w.now
	pump: shell.Pump
	shell.pump_frame(&pump, &p.sess, 0.25)

	testing.expect(t, pump.transition)
	testing.expect_value(t, pump.ticks, 0)
	testing.expect_value(t, u64(p.w.now), u64(before))
}

// Completion is an edge, not a level. The debrief is rendered from it and the
// save is written from it, so reporting it twice would write the save twice and
// print the debrief twice.
@(test)
test_completion_is_reported_once :: proc(t: ^testing.T) {
	level, _ := campaign.level_by_id("recon-sweep")

	p: Play
	play_open(&p, level)
	defer play_close(&p)

	shell.session_exec(&p.sess, "nmap -sn 10.0.4.0/24")

	pump: shell.Pump
	completions, recorded := 0, 0
	for _ in 0 ..< 200 {
		shell.pump_frame(&pump, &p.sess, 1.0 / 60.0)
		if pump.completed {
			completions += 1
		}
		if pump.recorded {
			recorded += 1
		}
	}

	testing.expect(t, campaign.level_complete(&p.w, level), "the level should have finished")
	testing.expect_value(t, completions, 1)
	testing.expect_value(t, recorded, 1)
	testing.expect_value(t, len(p.prog.completed), 1)
}

// --- digests ----------------------------------------------------------------

// The event digest is folded on push, not on drain. That is what makes it a
// property of what the simulation said rather than of how often somebody was
// listening -- and the ring is deliberately lossy, so a drain-time digest would
// change under a stalled frontend.
@(test)
test_the_event_digest_does_not_depend_on_draining :: proc(t: ^testing.T) {
	run :: proc(drain_every: int) -> (u64, u64) {
		level, _ := campaign.level_by_id("northwind")

		p: Play
		play_open(&p, level)
		defer play_close(&p)

		shell.session_exec(&p.sess, "nmap -sV 10.0.4.0/24")
		for i in 0 ..< 1200 {
			sim.tick(&p.w)
			shell.session_update(&p.sess)
			if drain_every > 0 && i % drain_every == 0 {
				for {
					_, ok := sim.ring_pop(&p.w.events)
					if !ok {
						break
					}
				}
			}
		}
		return sim.events_digest(&p.w), sim.world_digest(&p.w)
	}

	e1, w1 := run(0)  // never drained
	e2, w2 := run(1)  // drained every tick
	e3, w3 := run(97) // drained on an awkward cadence

	testing.expect_value(t, e2, e1)
	testing.expect_value(t, e3, e1)
	testing.expect_value(t, w2, w1)
	testing.expect_value(t, w3, w1)
}

// A digest that never changes is not a digest. Two runs that differ in what was
// said must differ in the event digest, and two that differ in what is true must
// differ in the world digest.
@(test)
test_digests_move_when_the_run_does :: proc(t: ^testing.T) {
	run :: proc(cmd: string, ticks: int) -> (u64, u64) {
		level, _ := campaign.level_by_id("northwind")

		p: Play
		play_open(&p, level)
		defer play_close(&p)

		if len(cmd) > 0 {
			shell.session_exec(&p.sess, cmd)
		}
		for _ in 0 ..< ticks {
			sim.tick(&p.w)
			shell.session_update(&p.sess)
		}
		return sim.events_digest(&p.w), sim.world_digest(&p.w)
	}

	e_idle, w_idle := run("", 1200)
	e_scan, w_scan := run("nmap -sV 10.0.4.0/24", 1200)
	e_again, w_again := run("nmap -sV 10.0.4.0/24", 1200)

	testing.expect(t, e_scan != e_idle, "a scan says something an idle run does not")
	testing.expect(t, w_scan != w_idle, "and reaches a state an idle run does not")
	testing.expect_value(t, e_again, e_scan)
	testing.expect_value(t, w_again, w_scan)

	// The world digest carries the clock, so the same script for a different
	// length of time is a different world -- which is what makes a mark placed at
	// a tick mean anything about that tick.
	_, w_short := run("nmap -sV 10.0.4.0/24", 600)
	testing.expect(t, w_short != w_scan)
}
