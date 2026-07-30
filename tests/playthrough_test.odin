package tests

import "core:strings"
import "core:testing"
import "../src/campaign"
import "../src/shell"
import "../src/sim"

// Every level is completable.
//
// This is M3's acceptance criterion and the authored-content equivalent of
// proving a generated network solvable. The validator checks a level is
// *coherent*; this checks it can actually be finished, by finishing it -- with
// only the tools that level offers, from a fresh world, through the real shell.
//
// A level that stops being winnable fails here rather than in front of someone
// who cannot tell whether it is them or the game.

// A level under test, driven exactly as a player would drive it.
Play :: struct {
	w:    sim.World,
	sess: shell.Session,
	prog: campaign.Progress,
}

@(private)
play_open :: proc(p: ^Play, level: ^campaign.Level) {
	sim.world_init(&p.w, 0xCEF5EC)
	campaign.progress_init(&p.prog)

	// Grant everything the level's prerequisites would have granted, so the
	// session is in exactly the state a player reaching this level would be in.
	for &l in campaign.LEVELS {
		if l.number < level.number {
			campaign.mark_complete(&p.prog, l.id)
		}
	}

	origin := level.build(&p.w)
	shell.session_init(&p.sess, &p.w, origin, "operator")
	p.sess.level = level
	p.sess.progress = &p.prog
	p.sess.tools = level.tools

	// Levels before the trace is taught run with nothing watching, matching
	// what main.start_level does.
	if !level.trace {
		it: int
		for sn in sim.pool_iter(&p.w.subnets, &it) {
			sn.monitoring = .None
		}
	}
}

@(private)
play_close :: proc(p: ^Play) {
	campaign.progress_destroy(&p.prog)
	sim.world_destroy(&p.w)
}

// Runs a command and lets it finish, exactly as the frame loop would.
@(private)
play_do :: proc(p: ^Play, line: string, max_ticks := 4000) {
	shell.session_exec(&p.sess, line)
	for _ in 0 ..< max_ticks {
		if !shell.session_active(&p.sess) && len(p.w.timers) == 0 {
			break
		}
		sim.tick(&p.w)
		shell.session_update(&p.sess)
	}
	shell.session_update(&p.sess)
}

@(private)
play_transcript :: proc(p: ^Play) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for {
		e, ok := sim.ring_pop(&p.w.events)
		if !ok {
			break
		}
		if l, is_log := e.(sim.Ev_Log); is_log {
			strings.write_string(&sb, l.text)
			strings.write_byte(&sb, '\n')
		}
	}
	return strings.to_string(sb)
}

// The intended solution to each level. Written as a player would type it --
// these double as the reference walkthrough, and if a level's design changes
// this is where that shows up first.
Walkthrough :: struct {
	id:    string,
	steps: []string,
}

WALKTHROUGHS := []Walkthrough {
	{"recon-sweep", {"nmap -sn 10.0.4.0/24"}},
	{"recon-versions", {"nmap -sV 10.0.7.0/24"}},
	{
		"access-exposure",
		{"nmap -sV 10.0.5.0/24", "curl http://10.0.5.12/", "curl http://10.0.5.12/.env"},
	},
	{
		"lateral-reuse",
		{
			"nmap -sn 10.0.6.0/24",
			"curl http://10.0.6.12/",
			"curl http://10.0.6.12/backup.conf",
			"ssh svc-backup@10.0.6.12",
			"ssh svc-backup@10.0.6.40",
		},
	},
	{
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
	},
}

@(private)
walkthrough_for :: proc(id: string) -> (Walkthrough, bool) {
	for w in WALKTHROUGHS {
		if w.id == id {
			return w, true
		}
	}
	return {}, false
}

// --- the acceptance test ----------------------------------------------------

@(test)
test_every_level_is_completable :: proc(t: ^testing.T) {
	// Every level must have a walkthrough, so adding a level without proving it
	// finishable fails the build rather than shipping.
	testing.expect_value(t, len(WALKTHROUGHS), len(campaign.LEVELS))

	for &level in campaign.LEVELS {
		wt, has := walkthrough_for(level.id)
		testing.expectf(t, has, "level %q has no walkthrough", level.id)
		if !has {
			continue
		}

		p: Play
		play_open(&p, &level)
		defer play_close(&p)

		testing.expectf(t, !campaign.level_complete(&p.w, &level), "level %q starts complete", level.id)

		for step in wt.steps {
			play_do(&p, step)
		}

		met, required := campaign.objectives_met(&p.w, &level)
		if met != required {
			// Name the objective that failed; "3 of 5" alone is not diagnosable.
			for o in level.objectives {
				if !o.optional && !campaign.objective_met(&p.w, o) {
					testing.expectf(
						t,
						false,
						"level %d (%s): objective %q not met by the walkthrough",
						level.number,
						level.id,
						o.text,
					)
				}
			}
		}
		testing.expectf(
			t,
			campaign.level_complete(&p.w, &level),
			"level %d (%s) was not completed by its own walkthrough (%d/%d)",
			level.number,
			level.id,
			met,
			required,
		)
	}
}

// A walkthrough that quietly relies on a tool the level does not offer would
// pass the test above while being impossible in play. Assert the steps only use
// what the level actually hands the player.
@(test)
test_walkthroughs_only_use_the_levels_tools :: proc(t: ^testing.T) {
	for wt in WALKTHROUGHS {
		level, ok := campaign.level_by_id(wt.id)
		testing.expectf(t, ok, "walkthrough for unknown level %q", wt.id)
		if !ok {
			continue
		}

		for step in wt.steps {
			toks, err := shell.lex(step, context.temp_allocator)
			testing.expect_value(t, err, shell.Lex_Error.None)
			if len(toks) == 0 {
				continue
			}
			spec, found := shell.lookup(toks[0])
			testing.expectf(t, found, "walkthrough step %q is not a command", step)
			if !found || !spec.job {
				continue // builtins are always available
			}

			offered := false
			for tool in level.tools {
				if tool == toks[0] {
					offered = true
					break
				}
			}
			testing.expectf(t, offered, "level %q walkthrough uses %q, which it does not offer", wt.id, toks[0])
		}
	}
}

// The early levels are meant to be survivable without thinking about noise --
// that is why trace is off until the combine level. If a teaching level ever
// becomes losable, the lesson is buried under a mechanic it has not taught yet.
@(test)
test_teaching_levels_cannot_be_lost :: proc(t: ^testing.T) {
	for &level in campaign.LEVELS {
		if level.trace {
			continue
		}
		wt, has := walkthrough_for(level.id)
		if !has {
			continue
		}

		p: Play
		play_open(&p, &level)
		defer play_close(&p)

		for step in wt.steps {
			play_do(&p, step)
		}

		testing.expectf(t, p.w.trace.level == 0, "level %q has trace off but accrued trace", level.id)
		testing.expectf(t, !sim.run_over(&p.w), "level %q ended the run", level.id)
	}
}

// The combine level has trace live, and its intended route must still be
// comfortably survivable. This is the tuning canary from M2, now pointed at the
// level rather than at a bare scenario.
@(test)
test_the_combine_level_is_survivable :: proc(t: ^testing.T) {
	level, ok := campaign.level_by_id("northwind")
	testing.expect(t, ok)

	p: Play
	play_open(&p, level)
	defer play_close(&p)
	testing.expect(t, level.trace, "northwind should have the detection system live")

	wt, _ := walkthrough_for("northwind")
	for step in wt.steps {
		play_do(&p, step)
	}

	testing.expect(t, campaign.level_complete(&p.w, level))
	testing.expect_value(t, p.w.trace.level, i32(0))

	it: int
	for sn in sim.pool_iter(&p.w.subnets, &it) {
		testing.expectf(t, sn.hot_ticks == 0, "%s went over the alarm line on the intended route", sn.name)
	}
}

// --- discoverability --------------------------------------------------------

// Solvable is not the same as discoverable, and the walkthrough test above
// cannot tell the difference: it knows the answers.
//
// This caught a real failure in the combine level. Taking the jump box left the
// player on a host with no files at all, expected to scan an internal range
// stated only in a file back on the machine they had just left. The level
// finished perfectly in tests and stranded a human being.
//
// So: before each step, every address the step targets must be knowable from
// where the player is *standing* -- the brief, or a file on the host under the
// prompt. Holding a host they walked away from does not count, because reading
// it means already knowing to go back.
@(private)
network_prefix :: proc(arg: string) -> (string, bool) {
	// "10.0.9.0/24" and "10.0.9.10" both reduce to "10.0.9." -- the granularity
	// at which a clue is useful. A hostname or a URL path is not an address.
	digits, dots := 0, 0
	for i in 0 ..< len(arg) {
		c := arg[i]
		switch {
		case c >= '0' && c <= '9':
			digits += 1
		case c == '.':
			dots += 1
			if dots == 3 {
				return arg[:i + 1], digits > 0
			}
		case:
			return "", false
		}
	}
	return "", false
}

// Pulls the address out of a step, whatever syntax the tool uses.
@(private)
step_target :: proc(step: string) -> (string, bool) {
	toks, err := shell.lex(step, context.temp_allocator)
	if err != .None {
		return "", false
	}
	for tok in toks[1:] {
		arg := tok
		// user@host
		if at := strings.index_byte(arg, '@'); at >= 0 {
			arg = arg[at + 1:]
		}
		// http://host/path
		if strings.has_prefix(arg, "http://") {
			arg = arg[7:]
		} else if strings.has_prefix(arg, "https://") {
			arg = arg[8:]
		}
		if slash := strings.index_byte(arg, '/'); slash >= 0 && strings.count(arg, ".") >= 3 {
			arg = arg[:slash] // strip a URL path, keep a CIDR's own slash out
		}
		if prefix, ok := network_prefix(arg); ok {
			return prefix, true
		}
	}
	return "", false
}

@(test)
test_every_step_targets_something_the_player_could_know :: proc(t: ^testing.T) {
	for &level in campaign.LEVELS {
		wt, has := walkthrough_for(level.id)
		if !has {
			continue
		}

		p: Play
		play_open(&p, &level)
		defer play_close(&p)

		for step in wt.steps {
			prefix, targeted := step_target(step)
			if targeted {
				known := false

				// Stated in the brief?
				for line in level.brief {
					if strings.contains(line, prefix) {
						known = true
						break
					}
				}

				// Or readable on the host under the prompt right now?
				if !known {
					if host, ok := sim.pool_get(&p.w.hosts, p.sess.host); ok {
						for f in host.files {
							if strings.contains(f.content, prefix) || strings.contains(f.path, prefix) {
								known = true
								break
							}
						}
					}
				}

				host_name := "?"
				if host, ok := sim.pool_get(&p.w.hosts, p.sess.host); ok {
					host_name = host.hostname
				}
				testing.expectf(
					t,
					known,
					"level %d (%s): %q targets %s*, but standing on %s nothing states it -- solvable, not discoverable",
					level.number,
					level.id,
					step,
					prefix,
					host_name,
				)
			}
			play_do(&p, step)
		}
	}
}

// --- hints ------------------------------------------------------------------

// The promise: while a level is unfinished, asking for a hint gets you
// something about what is still outstanding.
//
// Checked dynamically rather than as "every objective has a hint", because
// several objectives are often satisfied by one action -- level one's three
// finds all fall out of a single sweep. What matters is not the shape of the
// data but whether a stuck player is ever left with nothing to ask for.
@(test)
test_a_hint_is_always_available_while_a_level_is_unfinished :: proc(t: ^testing.T) {
	for &level in campaign.LEVELS {
		wt, has := walkthrough_for(level.id)
		if !has {
			continue
		}

		p: Play
		play_open(&p, &level)
		defer play_close(&p)

		// Before anything, and after each step short of completion.
		for step, i in wt.steps {
			if campaign.level_complete(&p.w, &level) {
				break
			}
			_, _, ok := campaign.next_hint(&p.w, &level, 0)
			testing.expectf(
				t,
				ok,
				"level %d (%s): nothing to hint at after %d step(s) -- a player stuck here has no help",
				level.number,
				level.id,
				i,
			)
			play_do(&p, step)
		}

		// And once finished, there is nothing left to hint at.
		testing.expectf(t, campaign.level_complete(&p.w, &level), "level %q did not finish", level.id)
		testing.expect_value(t, campaign.hints_remaining(&p.w, &level, 0), 0)
	}
}

// Escalation: asking repeatedly walks forward rather than repeating, and the
// last hint for a step is concrete enough to act on.
@(test)
test_hints_escalate_and_do_not_repeat :: proc(t: ^testing.T) {
	level, _ := campaign.level_by_id("recon-sweep")

	p: Play
	play_open(&p, level)
	defer play_close(&p)

	seen := make([dynamic]string, 0, 8, context.temp_allocator)
	for _ in 0 ..< 12 {
		before := p.sess.hints_shown
		play_do(&p, "hint")
		if p.sess.hints_shown == before {
			break // exhausted
		}
		text := play_transcript(&p)
		for previous in seen {
			testing.expectf(t, !strings.contains(text, previous), "hint repeated: %q", previous)
		}
		append(&seen, strings.clone(text, context.temp_allocator))
	}

	testing.expect(t, len(seen) >= 3, "there should be several escalating hints")
	// The last one has to be actionable -- running out while still stuck is
	// worse than having no hints at all.
	last := seen[len(seen) - 1]
	testing.expect(t, strings.contains(last, "nmap"), "the final hint should name the command")
}

// A hint about something already done is a hint that teaches nothing and reads
// as though the game is not paying attention. This is the whole reason hints
// carry the step they unblock.
@(test)
test_hints_skip_steps_already_solved :: proc(t: ^testing.T) {
	level, _ := campaign.level_by_id("access-exposure")

	p: Play
	play_open(&p, level)
	defer play_close(&p)

	// Do the first two steps unaided.
	play_do(&p, "nmap -sV 10.0.5.0/24")
	play_do(&p, "curl http://10.0.5.12/")
	play_transcript(&p)
	testing.expect(t, campaign.objective_met(&p.w, level.objectives[0]))
	testing.expect(t, campaign.objective_met(&p.w, level.objectives[1]))

	play_do(&p, "hint")
	text := play_transcript(&p)

	// It should be helping with the credential, not with scanning.
	testing.expect(t, strings.contains(text, "Obtain a credential"), "the hint should name the outstanding step")
	testing.expect(t, !strings.contains(text, "find out what is there"), "and not re-explain a solved one")
}

@(test)
test_hint_says_so_when_the_level_is_done :: proc(t: ^testing.T) {
	level, _ := campaign.level_by_id("recon-sweep")

	p: Play
	play_open(&p, level)
	defer play_close(&p)

	play_do(&p, "nmap -sn 10.0.4.0/24")
	play_transcript(&p)

	play_do(&p, "hint")
	testing.expect(t, strings.contains(play_transcript(&p), "done"))
}

// --- gating -----------------------------------------------------------------

@(test)
test_a_level_refuses_tools_it_does_not_offer :: proc(t: ^testing.T) {
	level, ok := campaign.level_by_id("recon-sweep")
	testing.expect(t, ok)

	p: Play
	play_open(&p, level)
	defer play_close(&p)

	before_tag := p.w.tag_counter
	play_do(&p, "ssh svc@10.0.4.11")
	text := play_transcript(&p)

	testing.expect(t, strings.contains(text, "ssh:"), "the refusal should name the command")
	testing.expect(t, strings.contains(text, "level 4"), "and the level that teaches it")

	// Refused before anything is committed: no job, no tag, no noise.
	testing.expect(t, !shell.session_active(&p.sess))
	testing.expect_value(t, p.w.tag_counter, before_tag)
	testing.expect_value(t, p.sess.next_job_id, 0)
	it: int
	for sn in sim.pool_iter(&p.w.subnets, &it) {
		testing.expect_value(t, sn.suspicion, i32(0))
	}
}

// A tool the player owns but this scenario withholds gets a different message,
// because it is a different situation: you know the technique, it does not
// apply here.
@(test)
test_withheld_and_unlearned_read_differently :: proc(t: ^testing.T) {
	level, ok := campaign.level_by_id("recon-sweep")
	testing.expect(t, ok)

	p: Play
	play_open(&p, level)
	defer play_close(&p)

	// Pretend the player has finished everything: ssh is owned, but level 1
	// still does not offer it.
	for &l in campaign.LEVELS {
		campaign.mark_complete(&p.prog, l.id)
	}

	play_do(&p, "ssh svc@10.0.4.11")
	text := play_transcript(&p)
	testing.expect(t, strings.contains(text, "not available in this scenario"))
	testing.expect(t, !strings.contains(text, "level 4 teaches"), "an owned tool should not say it is unlearned")
}

@(test)
test_progression_unlocks_tools :: proc(t: ^testing.T) {
	p: campaign.Progress
	campaign.progress_init(&p)
	defer campaign.progress_destroy(&p)

	has :: proc(tools: []string, name: string) -> bool {
		for t in tools {
			if t == name {
				return true
			}
		}
		return false
	}

	campaign.mark_complete(&p, "recon-sweep")
	early := campaign.unlocked_tools(&p, context.temp_allocator)
	testing.expect(t, has(early, "nmap"))
	testing.expect(t, !has(early, "ssh"), "ssh must not be available after level 1")

	campaign.mark_complete(&p, "recon-versions")
	campaign.mark_complete(&p, "access-exposure")
	campaign.mark_complete(&p, "lateral-reuse")
	late := campaign.unlocked_tools(&p, context.temp_allocator)
	testing.expect(t, has(late, "ssh"), "ssh should be available after level 4")
	testing.expect(t, has(late, "curl"))
}

// --- the campaign commands --------------------------------------------------

// `play` is how every level after the first is reached, and it shipped
// untested. The bug it hid was in main's loop rather than here -- completion was
// recorded after the tick loop while scripted commands were fed inside it, so
// `play 2` immediately after finishing level 1 was refused as locked -- but a
// command nothing exercises is a command nothing protects.
@(test)
test_play_accepts_an_unlocked_level :: proc(t: ^testing.T) {
	level, _ := campaign.level_by_id("recon-sweep")

	p: Play
	play_open(&p, level)
	defer play_close(&p)

	// Level 2 is locked until level 1 is recorded complete.
	play_do(&p, "play 2")
	testing.expect(t, strings.contains(play_transcript(&p), "locked"))
	_, wants_early := p.sess.pending_transition.?
	testing.expect(t, !wants_early, "a locked level must not be scheduled")

	// Finish level 1 the way a player would, then ask again.
	play_do(&p, "nmap -sn 10.0.4.0/24")
	testing.expect(t, campaign.level_complete(&p.w, level))
	campaign.mark_complete(&p.prog, level.id)
	play_transcript(&p)

	play_do(&p, "play 2")
	transition, wants := p.sess.pending_transition.?
	testing.expect(t, wants, "play should schedule the transition once unlocked")
	if wants {
		testing.expect_value(t, transition.level, 2)
		testing.expect(t, !transition.retry)
	}
}

@(test)
test_play_names_what_is_missing :: proc(t: ^testing.T) {
	level, _ := campaign.level_by_id("recon-sweep")

	p: Play
	play_open(&p, level)
	defer play_close(&p)

	play_do(&p, "play 5")
	text := play_transcript(&p)
	testing.expect(t, strings.contains(text, "locked"))
	// Naming the prerequisite is the difference between a refusal that helps
	// and one that only blocks.
	testing.expect(t, strings.contains(text, "finish level"), "the refusal should name a prerequisite")

	play_do(&p, "play 99")
	testing.expect(t, strings.contains(play_transcript(&p), "no level 99"))
}

@(test)
test_retry_schedules_the_current_level :: proc(t: ^testing.T) {
	level, _ := campaign.level_by_id("access-exposure")

	p: Play
	play_open(&p, level)
	defer play_close(&p)

	play_do(&p, "retry")
	transition, wants := p.sess.pending_transition.?
	testing.expect(t, wants, "retry should schedule a transition")
	if wants {
		testing.expect_value(t, transition.level, level.number)
		testing.expect(t, transition.retry, "and mark it as a retry")
	}
}

@(test)
test_objectives_reflects_progress :: proc(t: ^testing.T) {
	level, _ := campaign.level_by_id("recon-sweep")

	p: Play
	play_open(&p, level)
	defer play_close(&p)

	play_do(&p, "objectives")
	before := play_transcript(&p)
	testing.expect(t, strings.contains(before, "[ ]"), "unmet objectives should be shown unticked")
	testing.expect(t, !strings.contains(before, "[x]"))
	// The technique is named here too -- this is the level's ATT&CK label.
	testing.expect(t, strings.contains(before, "T1595.001"))

	play_do(&p, "nmap -sn 10.0.4.0/24")
	play_transcript(&p)

	play_do(&p, "objectives")
	after := play_transcript(&p)
	testing.expect(t, strings.contains(after, "[x]"), "met objectives should tick")
	testing.expect(t, !strings.contains(after, "[ ]"), "all three should be met")
}

@(test)
test_levels_marks_done_and_locked :: proc(t: ^testing.T) {
	level, _ := campaign.level_by_id("recon-versions")

	p: Play
	play_open(&p, level) // play_open completes everything before level 2
	defer play_close(&p)

	play_do(&p, "levels")
	text := play_transcript(&p)

	testing.expect(t, strings.contains(text, "Knock and see who answers"), "levels should list level 1")
	// Odin's %2d zero-pads, so levels render as 01..60 -- which suits a campaign
	// of sixty and keeps the column aligned.
	testing.expect(t, strings.contains(text, "x 01"), "a finished level should be marked done")
	testing.expect(t, strings.contains(text, "> 02"), "the level in progress should be marked")
	testing.expect(t, strings.contains(text, "- 05"), "a locked level should be marked locked")
	// A combine level spans several tactics, so it is grouped as a synthesis
	// rather than filed under whichever technique is listed first.
	testing.expect(t, strings.contains(text, "[synthesis]"), "combine levels group separately")
}

@(test)
test_techniques_reports_coverage :: proc(t: ^testing.T) {
	level, _ := campaign.level_by_id("recon-versions")

	p: Play
	play_open(&p, level)
	defer play_close(&p)

	play_do(&p, "techniques")
	text := play_transcript(&p)

	testing.expect(t, strings.contains(text, "Recon"), "tactics with catalogued techniques should appear")
	testing.expect(t, strings.contains(text, "techniques covered"), "and a total")

	// Level 1 is complete in this fixture, so at least one technique is covered.
	covered := campaign.covered_techniques(&p.prog, context.temp_allocator)
	testing.expect(t, len(covered) > 0)
}

// --- retry ------------------------------------------------------------------

// The hazard M2 deferred. ui.Term holds string references into the run arena and
// Session.user/cwd/history are arena-allocated, so a reset in the wrong order is
// a use-after-free that would surface as garbled text rather than a crash.
//
// Driven twice in a row, reading the supposedly-dangling state each time.
@(test)
test_a_level_can_be_replayed_safely :: proc(t: ^testing.T) {
	level, ok := campaign.level_by_id("recon-sweep")
	testing.expect(t, ok)

	w: sim.World
	sim.world_init(&w, 0xCEF5EC)
	defer sim.world_destroy(&w)

	prog: campaign.Progress
	campaign.progress_init(&prog)
	defer campaign.progress_destroy(&prog)

	sess: shell.Session

	for attempt in 1 ..= 3 {
		// The order start_level uses: nothing may hold an arena pointer across
		// the reset. There is no Term here, so the Session is what is at risk.
		sim.world_reset(&w, 0xCEF5EC)
		origin := level.build(&w)
		shell.session_init(&sess, &w, origin, "operator")
		sess.level = level
		sess.progress = &prog
		sess.tools = level.tools

		// Read every string that lived in the freed arena.
		testing.expect_value(t, sess.user, "operator")
		testing.expect_value(t, sess.cwd, "/home/operator")
		testing.expect_value(t, len(sess.line.history), 0)
		testing.expectf(t, len(shell.prompt(&sess, context.temp_allocator)) > 0, "attempt %d: empty prompt", attempt)

		// And the world is genuinely fresh each time.
		testing.expect_value(t, w.now, sim.Tick(0))
		testing.expect_value(t, w.trace.level, i32(0))
		testing.expect(t, !campaign.level_complete(&w, level))

		shell.session_exec(&sess, "nmap -sn 10.0.4.0/24")
		for _ in 0 ..< 3000 {
			if !shell.session_active(&sess) && len(w.timers) == 0 {
				break
			}
			sim.tick(&w)
			shell.session_update(&sess)
		}
		testing.expectf(t, campaign.level_complete(&w, level), "attempt %d did not complete", attempt)
	}
}
