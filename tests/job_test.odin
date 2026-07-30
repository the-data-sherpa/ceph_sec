package tests

import "core:fmt"
import "core:strings"
import "core:testing"
import "../src/shell"
import "../src/sim"

// Background jobs. The fixture, `run`, `settle` and `transcript` come from
// shell_test.odin -- same package.

// One drained log line, with the job it was attributed to. Tests assert on this
// rather than on substring matching, because attribution is the property under
// test and a text search would pass on a coincidence.
Log_Entry :: struct {
	job:  u16,
	text: string,
}

@(private)
log_stream :: proc(f: ^Fixture) -> []Log_Entry {
	out := make([dynamic]Log_Entry, 0, 32, context.temp_allocator)
	for {
		e, ok := sim.ring_pop(&f.w.events)
		if !ok {
			break
		}
		if l, is_log := e.(sim.Ev_Log); is_log {
			append(&out, Log_Entry{job = l.job, text = l.text})
		}
	}
	return out[:]
}

// Advances the world without waiting for the shell to go idle, so tests can
// observe several jobs part-way through.
@(private)
step :: proc(f: ^Fixture, ticks: int) {
	for _ in 0 ..< ticks {
		sim.tick(&f.w)
		shell.session_update(&f.sess)
	}
}

// --- launching --------------------------------------------------------------

@(test)
test_ampersand_forms :: proc(t: ^testing.T) {
	forms := []string{"nmap -sn 10.0.4.0/24 &", "nmap -sn 10.0.4.0/24&", "nmap -sn 10.0.4.0/24   &"}
	for form in forms {
		f: Fixture
		fixture(&f)
		defer fixture_destroy(&f)

		shell.session_exec(&f.sess, form)
		testing.expectf(t, shell.slots_in_use(&f.sess) == 1, "%q should have launched a background job", form)
		testing.expectf(t, !shell.session_busy(&f.sess), "%q should not hold the terminal", form)
	}
}

// Regression guard for the decision not to make `&` a lexer metacharacter: a
// query string is a perfectly ordinary thing to type, and tokenising on `&`
// would silently cut it into three arguments.
@(test)
test_ampersand_inside_a_url_is_not_a_separator :: proc(t: ^testing.T) {
	toks, err := shell.lex(`curl "http://10.0.4.11/x?a=1&b=2"`, context.temp_allocator)
	testing.expect_value(t, err, shell.Lex_Error.None)
	testing.expect_value(t, len(toks), 2)
	testing.expect_value(t, toks[1], "http://10.0.4.11/x?a=1&b=2")

	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	// And it must not be treated as a background launch either.
	shell.session_exec(&f.sess, `curl "http://10.0.4.11/x?a=1&b=2"`)
	testing.expect(t, shell.session_busy(&f.sess), "should have run in the foreground")
	testing.expect_value(t, shell.slots_in_use(&f.sess), 0)
}

// The whole point: the prompt comes back in the same tick.
@(test)
test_backgrounding_frees_the_prompt_immediately :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	shell.session_exec(&f.sess, "nmap -sV 10.0.4.0/24 &")
	testing.expect(t, !shell.session_busy(&f.sess), "background launch must not hold the terminal")
	testing.expect(t, shell.session_active(&f.sess), "but the job is running")

	// A foreground tool dispatches straight away, alongside it.
	shell.session_exec(&f.sess, "curl http://10.0.4.11/")
	testing.expect(t, shell.session_busy(&f.sess), "foreground command should have started")
	testing.expect_value(t, shell.slots_in_use(&f.sess), 1)
}

@(test)
test_ssh_cannot_be_backgrounded :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	sim.keyring_add(&f.w, {username = "svc", password = PASSWORD, note = "seed"})
	run(&f, "nmap -sn 10.0.4.0/24")
	transcript(&f)

	before_tag := f.w.tag_counter
	before_id := f.sess.next_job_id
	shell.session_exec(&f.sess, "ssh svc@10.0.4.19 &")

	testing.expect(t, strings.contains(transcript(&f), "cannot be backgrounded"))
	testing.expect_value(t, shell.slots_in_use(&f.sess), 0)
	testing.expect(t, !shell.session_busy(&f.sess))
	// A refused launch leaves no trace in any deterministic counter.
	testing.expect_value(t, f.w.tag_counter, before_tag)
	testing.expect_value(t, f.sess.next_job_id, before_id)
}

@(test)
test_slot_limit_is_enforced :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	shell.session_exec(&f.sess, "nmap -sV 10.0.4.0/24 &")
	shell.session_exec(&f.sess, "curl http://10.0.4.11/ &")
	testing.expect_value(t, shell.slots_in_use(&f.sess), 2)
	transcript(&f)

	before_tag := f.w.tag_counter
	before_id := f.sess.next_job_id
	shell.session_exec(&f.sess, "nmap -sn 10.0.4.0/24 &")

	refusal := transcript(&f)
	testing.expect(t, strings.contains(refusal, "slots"), "the refusal should name the limit")
	testing.expect(t, strings.contains(refusal, "kill"), "and how to free one")
	testing.expect_value(t, shell.slots_in_use(&f.sess), 2)
	testing.expect_value(t, f.w.tag_counter, before_tag)
	testing.expect_value(t, f.sess.next_job_id, before_id)
}

// A tool that validates and bails never claims any time, so its slot must be
// released at once. Leaving it allocated leaks the slot, and the failure only
// becomes visible several commands later -- which is nearly impossible to
// diagnose from the symptom.
@(test)
test_a_tool_that_bails_early_releases_its_slot :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	shell.session_exec(&f.sess, "nmap not-an-address &")
	testing.expect_value(t, shell.slots_in_use(&f.sess), 0)
	testing.expect(t, !shell.session_active(&f.sess))

	shell.session_exec(&f.sess, "nmap -sV 10.0.4.0/24 &")
	shell.session_exec(&f.sess, "curl http://10.0.4.11/ &")
	testing.expect_value(t, shell.slots_in_use(&f.sess), 2)
}

// Job ids are the player-facing handle: monotonic, never reused within a run,
// so `kill %2` cannot ever hit a different job than the one `jobs` listed.
@(test)
test_job_ids_are_monotonic_and_never_reused :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	shell.session_exec(&f.sess, "nmap -sV 10.0.4.0/24 &")
	first := f.sess.next_job_id
	run(&f, "curl http://10.0.4.11/") // foreground, completes
	shell.session_exec(&f.sess, "curl http://10.0.4.11/.env &")

	testing.expect(t, f.sess.next_job_id > first + 1, "ids should keep climbing")

	// Everything settles, then a new launch still gets a fresh id.
	settle(&f, 2000)
	before := f.sess.next_job_id
	shell.session_exec(&f.sess, "nmap -sn 10.0.4.0/24 &")
	testing.expect_value(t, f.sess.next_job_id, before + 1)
}

// A job captures its host at launch. Without this a scan started on web01 would
// silently retarget the moment the prompt pivots to jump01.
@(test)
test_job_context_is_captured_at_launch :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	sim.keyring_add(&f.w, {username = "svc", password = PASSWORD, note = "seed"})
	run(&f, "nmap -sn 10.0.4.0/24")
	run(&f, "ssh svc@10.0.4.11")
	testing.expect_value(t, f.sess.host, f.web)
	transcript(&f)

	shell.session_exec(&f.sess, "nmap -sV 10.0.4.0/24 &")
	j, ok := shell.job_by_id(&f.sess, f.sess.next_job_id)
	testing.expect(t, ok)
	testing.expect_value(t, j.host, f.web)

	run(&f, "ssh svc@10.0.4.19")
	testing.expect_value(t, f.sess.host, f.jump)
	// The job still points at where it was launched.
	j2, ok2 := shell.job_by_id(&f.sess, j.id)
	if ok2 {
		testing.expect_value(t, j2.host, f.web)
	}
}

// --- attribution ------------------------------------------------------------

@(test)
test_foreground_output_carries_no_gutter :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	run(&f, "nmap -sV 10.0.4.0/24")
	for e in log_stream(&f) {
		testing.expectf(t, e.job == 0, "foreground line was attributed to job %d: %q", e.job, e.text)
	}
}

@(test)
test_background_output_is_attributed :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	shell.session_exec(&f.sess, "nmap -sV 10.0.4.0/24 &")
	id := u16(f.sess.next_job_id)
	settle(&f, 2000)

	stream := log_stream(&f)
	attributed, done := 0, false
	for e in stream {
		if e.job == id {
			attributed += 1
			// The gutter is rendered by the frontend from `job`. A line that
			// also formats its own "[N]" prints it twice -- which is exactly
			// what the launch echo and the completion notice used to do.
			testing.expectf(
				t,
				!strings.has_prefix(e.text, "["),
				"attributed line formats its own gutter: %q",
				e.text,
			)
		}
		if e.job == id && strings.contains(e.text, "done") {
			done = true
		}
	}
	testing.expect(t, attributed > 3, "the scan's output should carry its job id")
	// The completion notice is scheduled, so it arrives after the tool's own
	// last line and still carries the gutter even though the job has retired.
	testing.expect(t, done, "the completion notice should be attributed too")
}

// Interleaving needs no new machinery: two jobs both schedule under the tick
// loop, and same-tick timers fire in schedule order. Asserted on the attribution
// stream rather than on text, so it cannot pass by coincidence.
@(test)
test_two_jobs_interleave :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	shell.session_exec(&f.sess, "nmap -sV 10.0.4.0/24 &")
	a := u16(f.sess.next_job_id)
	shell.session_exec(&f.sess, "curl http://10.0.4.11/.env &")
	b := u16(f.sess.next_job_id)
	testing.expect(t, a != b)

	settle(&f, 2000)

	// Count transitions between the two jobs' lines. Genuinely interleaved
	// output alternates; serialised output would transition exactly once.
	transitions := 0
	last: u16 = 0
	saw_a, saw_b := false, false
	for e in log_stream(&f) {
		if e.job != a && e.job != b {
			continue
		}
		if e.job == a {
			saw_a = true
		} else {
			saw_b = true
		}
		if last != 0 && e.job != last {
			transitions += 1
		}
		last = e.job
	}
	testing.expect(t, saw_a && saw_b, "both jobs should have produced output")
	testing.expectf(t, transitions >= 2, "output did not interleave (%d transitions)", transitions)
}

// --- cancellation -----------------------------------------------------------

@(test)
test_kill_isolates_one_job :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	shell.session_exec(&f.sess, "nmap -sV 10.0.4.0/24 &")
	victim := f.sess.next_job_id
	shell.session_exec(&f.sess, "curl http://10.0.4.11/.env &")
	survivor := u16(f.sess.next_job_id)
	transcript(&f)

	step(&f, 20)
	shell.session_exec(&f.sess, "kill %1")
	testing.expect(t, strings.contains(transcript(&f), "terminated"))

	_, still_there := shell.job_by_id(&f.sess, victim)
	testing.expect(t, !still_there, "the killed job should be gone")
	testing.expect_value(t, shell.slots_in_use(&f.sess), 1)

	settle(&f, 2000)
	saw_victim, saw_survivor := false, false
	for e in log_stream(&f) {
		if e.job == u16(victim) {
			saw_victim = true
		}
		if e.job == survivor {
			saw_survivor = true
		}
	}
	testing.expect(t, !saw_victim, "no further output from the killed job")
	testing.expect(t, saw_survivor, "the other job should have finished normally")
}

// ^C is bash's ^C: it takes the foreground job and leaves background work alone.
@(test)
test_interrupt_targets_only_the_foreground :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	sim.keyring_add(&f.w, {username = "svc", password = PASSWORD, note = "seed"})
	run(&f, "nmap -sn 10.0.4.0/24")
	transcript(&f)

	shell.session_exec(&f.sess, "nmap -sV 10.0.4.0/24 &")
	shell.session_exec(&f.sess, "ssh svc@10.0.4.19")
	testing.expect(t, shell.session_busy(&f.sess))

	step(&f, 30)
	shell.session_interrupt(&f.sess)

	testing.expect(t, !shell.session_busy(&f.sess), "^C should end the foreground login")
	testing.expect_value(t, shell.slots_in_use(&f.sess), 1)
	testing.expect(t, len(f.w.timers) > 0, "the background scan should still have work queued")

	settle(&f, 2000)
	jump, _ := sim.pool_get(&f.w.hosts, f.jump)
	testing.expect_value(t, jump.access, sim.Access.None)
	testing.expect_value(t, f.sess.host, f.origin)
}

@(test)
test_interrupt_with_no_foreground_clears_the_line :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	shell.session_exec(&f.sess, "nmap -sV 10.0.4.0/24 &")
	type_text(&f.sess, "half typed")
	shell.session_interrupt(&f.sess)

	testing.expect_value(t, shell.line_text(&f.sess.line, context.temp_allocator), "")
	testing.expect_value(t, shell.slots_in_use(&f.sess), 1)
}

@(test)
test_exit_kills_every_job :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	shell.session_exec(&f.sess, "nmap -sV 10.0.4.0/24 &")
	shell.session_exec(&f.sess, "curl http://10.0.4.11/ &")
	testing.expect_value(t, shell.slots_in_use(&f.sess), 2)

	shell.session_exec(&f.sess, "exit")
	testing.expect_value(t, shell.slots_in_use(&f.sess), 0)
	testing.expect_value(t, len(f.w.timers), 0)
	testing.expect_value(t, f.w.run.state, sim.Run_State.Quit)
}

// Every job-bearing command must leave nothing behind when killed immediately.
// The table length is asserted against the registry, so adding a tool without
// covering it here fails the build rather than being silently untested.
@(test)
test_no_tool_leaves_orphaned_timers :: proc(t: ^testing.T) {
	invocations := []string {
		"nmap -sV 10.0.4.0/24",
		"curl http://10.0.4.11/.env",
		"ssh svc@10.0.4.11",
	}

	job_specs := 0
	for spec in shell.COMMANDS {
		if spec.job {
			job_specs += 1
		}
	}
	testing.expect_value(t, len(invocations), job_specs)

	for line in invocations {
		f: Fixture
		fixture(&f)
		defer fixture_destroy(&f)

		sim.keyring_add(&f.w, {username = "svc", password = PASSWORD, note = "seed"})
		run(&f, "nmap -sn 10.0.4.0/24")
		transcript(&f)

		shell.session_exec(&f.sess, line)
		step(&f, 10)
		shell.session_interrupt(&f.sess)

		testing.expectf(t, len(f.w.timers) == 0, "%q left %d orphaned timers", line, len(f.w.timers))
		testing.expectf(t, !shell.session_active(&f.sess), "%q left a job running", line)
	}
}

// --- job control commands ---------------------------------------------------

// `fg` shipped in M2 without a single test executing it. Promoting a job must
// hand it the terminal *and* give its slot back -- it is no longer running in
// the background, so it should stop being counted as if it were.
@(test)
test_fg_promotes_a_background_job :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	shell.session_exec(&f.sess, "nmap -sV 10.0.4.0/24 &")
	id := f.sess.next_job_id
	testing.expect(t, !shell.session_busy(&f.sess))
	testing.expect_value(t, shell.slots_in_use(&f.sess), 1)
	transcript(&f)

	step(&f, 20)
	shell.session_exec(&f.sess, "fg")

	testing.expect(t, shell.session_busy(&f.sess), "fg should hand the job the terminal")
	testing.expect_value(t, f.sess.fg, id)
	testing.expect_value(t, shell.slots_in_use(&f.sess), 0)
	testing.expect(t, strings.contains(transcript(&f), "nmap -sV"), "fg should echo what it promoted")

	// And it is now interruptible with ^C, like any foreground command.
	shell.session_interrupt(&f.sess)
	testing.expect(t, !shell.session_busy(&f.sess))
	testing.expect_value(t, len(f.w.timers), 0)
}

@(test)
test_fg_refuses_while_the_terminal_is_held :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	shell.session_exec(&f.sess, "nmap -sV 10.0.4.0/24 &")
	background := f.sess.next_job_id
	shell.session_exec(&f.sess, "curl http://10.0.4.11/") // foreground
	held := f.sess.fg
	transcript(&f)

	shell.session_exec(&f.sess, fmt_id(&f, "fg %%%d", background))

	testing.expect(t, strings.contains(transcript(&f), "already holds the terminal"))
	testing.expect_value(t, f.sess.fg, held) // unchanged
	testing.expect_value(t, shell.slots_in_use(&f.sess), 1)
}

// Bare `fg` and bare `kill` take the most recently launched job, which is what
// makes the common case one word.
@(test)
test_bare_fg_and_kill_take_the_newest_job :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	shell.session_exec(&f.sess, "nmap -sV 10.0.4.0/24 &")
	older := f.sess.next_job_id
	shell.session_exec(&f.sess, "curl http://10.0.4.11/.env &")
	newer := f.sess.next_job_id
	transcript(&f)

	shell.session_exec(&f.sess, "kill")
	transcript(&f)

	_, newer_alive := shell.job_by_id(&f.sess, newer)
	older_job, older_alive := shell.job_by_id(&f.sess, older)
	testing.expect(t, !newer_alive, "bare kill should have taken the newest")
	testing.expect(t, older_alive, "and left the older one running")
	testing.expect_value(t, older_job.id, older)
}

@(test)
test_job_commands_reject_unknown_ids :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	// Nothing running at all.
	shell.session_exec(&f.sess, "fg")
	testing.expect(t, strings.contains(transcript(&f), "no such job"))
	shell.session_exec(&f.sess, "kill %3")
	testing.expect(t, strings.contains(transcript(&f), "no such job"))

	// A job that has already finished is gone, not merely idle.
	shell.session_exec(&f.sess, "curl http://10.0.4.11/ &")
	done := f.sess.next_job_id
	settle(&f)
	transcript(&f)

	shell.session_exec(&f.sess, fmt_id(&f, "kill %%%d", done))
	testing.expect(t, strings.contains(transcript(&f), "no such job"))

	// Garbage arguments are rejected rather than parsed into job 0.
	shell.session_exec(&f.sess, "kill %abc")
	testing.expect(t, strings.contains(transcript(&f), "no such job"))
}

@(test)
test_jobs_lists_what_is_running :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	shell.session_exec(&f.sess, "jobs")
	testing.expect(t, strings.contains(transcript(&f), "no jobs running"))

	shell.session_exec(&f.sess, "nmap -sV 10.0.4.0/24 &")
	shell.session_exec(&f.sess, "curl http://10.0.4.11/") // foreground
	transcript(&f)

	shell.session_exec(&f.sess, "jobs")
	listing := transcript(&f)

	testing.expect(t, strings.contains(listing, "nmap"), "the background job should be listed")
	testing.expect(t, strings.contains(listing, "curl"), "so should the foreground one")
	testing.expect(t, strings.contains(listing, "+"), "the foreground job should be marked")
	// Slots count background work only, so one of the two is using a slot.
	testing.expect(t, strings.contains(listing, "1 of 2 slots"), "slot usage should be reported")
}

// Said once per run, the first time it could matter. Repeating it every kill
// would be noise; never saying it leaves players assuming a kill undoes the
// noise the command already charged.
@(test)
test_the_kill_hint_is_said_once :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	shell.session_exec(&f.sess, "nmap -sV 10.0.4.0/24 &")
	shell.session_exec(&f.sess, "kill")
	testing.expect(t, strings.contains(transcript(&f), "killing saves time, not attention"))

	shell.session_exec(&f.sess, "curl http://10.0.4.11/ &")
	shell.session_exec(&f.sess, "kill")
	testing.expect(t, !strings.contains(transcript(&f), "killing saves time"), "the hint should not repeat")
}

// Killing genuinely does not refund the charge -- the rule the hint describes.
@(test)
test_killing_does_not_refund_noise :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	shell.session_exec(&f.sess, "nmap -sV 10.0.4.0/24 &")
	charged := suspicion_of(&f, f.dmz)
	testing.expect(t, charged > 0, "dispatch should have charged")

	shell.session_exec(&f.sess, "kill")
	testing.expect_value(t, suspicion_of(&f, f.dmz), charged)

	// Still no refund once the clock passes where the job would have ended.
	step(&f, 60)
	testing.expect(t, suspicion_of(&f, f.dmz) <= charged, "suspicion may decay but must never be credited back")
	testing.expect(t, suspicion_of(&f, f.dmz) > 0)
}

@(test)
test_trace_command_reports_real_state :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)

	shell.session_exec(&f.sess, "trace")
	quiet := transcript(&f)
	testing.expect(t, strings.contains(quiet, "0.0%"), "a clean run should report no trace")
	testing.expect(t, strings.contains(quiet, "DMZ"), "reachable segments should be listed")

	// Make a segment genuinely hot and check it is reported as such.
	pin_segment(&f, f.dmz, sim.SUSPICION_ALARM + 1000)
	sim.tick_n(&f.w, 5)
	shell.session_exec(&f.sess, "trace")
	hot := transcript(&f)
	testing.expect(t, strings.contains(hot, "ALARM"), "a segment over the line should be flagged")
}

@(private)
fmt_id :: proc(f: ^Fixture, format: string, id: int) -> string {
	return fmt.tprintf(format, id)
}

// --- determinism ------------------------------------------------------------

// The headline property, and the one a latched "is a job running" flag would
// break silently: the tick a command dispatches on must not depend on where the
// frame boundaries fell.
//
// Drives an identical session twice -- once one tick at a time, once in batches
// of seven -- and requires byte-identical output, attribution included.
@(test)
test_frame_batching_does_not_change_the_transcript :: proc(t: ^testing.T) {
	script := []string {
		"nmap -sV 10.0.4.0/24 &",
		"curl http://10.0.4.11/.env",
		"jobs",
		"creds",
	}

	// Same TOTAL tick count either way -- only the batch size differs. That is
	// the whole point: identical simulated time, different frame boundaries.
	TOTAL_TICKS :: 2800

	drive :: proc(f: ^Fixture, script: []string, batch: int) -> []Log_Entry {
		collected := make([dynamic]Log_Entry, 0, 128, context.temp_allocator)
		next := 0
		for _ in 0 ..< TOTAL_TICKS / batch {
			for _ in 0 ..< batch {
				sim.tick(&f.w)
				shell.session_update(&f.sess)
				if next < len(script) && !shell.session_busy(&f.sess) {
					shell.session_exec(&f.sess, script[next])
					next += 1
				}
			}
			for e in log_stream(f) {
				append(&collected, e)
			}
		}
		return collected[:]
	}

	a, b: Fixture
	fixture(&a)
	fixture(&b)
	defer fixture_destroy(&a)
	defer fixture_destroy(&b)

	one := drive(&a, script, 1)
	seven := drive(&b, script, 7)

	testing.expect(t, len(one) > 10, "the script should have produced output")
	testing.expect_value(t, len(one), len(seven))

	n := min(len(one), len(seven))
	for i in 0 ..< n {
		testing.expectf(
			t,
			one[i].text == seven[i].text && one[i].job == seven[i].job,
			"line %d diverged: [%d]%q vs [%d]%q",
			i,
			one[i].job,
			one[i].text,
			seven[i].job,
			seven[i].text,
		)
	}

	testing.expect_value(t, a.w.now, b.w.now)
	testing.expect_value(t, a.w.rng, b.w.rng)
	testing.expect_value(t, a.w.tag_counter, b.w.tag_counter)
	testing.expect_value(t, a.sess.next_job_id, b.sess.next_job_id)
}
