package tests

import "core:strings"
import "core:testing"
import "../src/campaign"
import "../src/shell"
import "../src/sim"

// The curriculum validator.
//
// This is the descendant of the attack-graph solvability prover that procedural
// generation would have needed. Authored content rots the same way generated
// content does -- the difference is only that it rots when someone edits it
// rather than when the RNG rolls badly.
//
// The failure these guard against is the expensive one: level 47 quietly
// becomes unsolvable because a tool moved between levels, and nobody finds out
// until a player is stuck with no way to tell whether it is them or the game.

@(private)
transitive_tools :: proc(l: ^campaign.Level, out: ^[dynamic]string) {
	for req in l.requires {
		prereq, ok := campaign.level_by_id(req)
		if !ok {
			continue
		}
		transitive_tools(prereq, out)
		for tool in prereq.grants {
			already := false
			for have in out {
				if have == tool {
					already = true
					break
				}
			}
			if !already {
				append(out, tool)
			}
		}
	}
}

// --- 1. the prerequisite graph ----------------------------------------------

@(test)
test_every_prerequisite_exists :: proc(t: ^testing.T) {
	for &l in campaign.LEVELS {
		for req in l.requires {
			_, ok := campaign.level_by_id(req)
			testing.expectf(t, ok, "level %q requires %q, which does not exist", l.id, req)
		}
	}
}

// A cycle would make both levels permanently unreachable, and the menu would
// simply never offer them -- a silent failure rather than a loud one.
@(test)
test_prerequisite_graph_is_acyclic :: proc(t: ^testing.T) {
	// Depth-limited walk: with the graph acyclic, no chain can be longer than
	// the number of levels.
	reachable :: proc(from: ^campaign.Level, target: string, depth: int) -> bool {
		if depth <= 0 {
			return false
		}
		for req in from.requires {
			if req == target {
				return true
			}
			prereq, ok := campaign.level_by_id(req)
			if ok && reachable(prereq, target, depth - 1) {
				return true
			}
		}
		return false
	}

	limit := len(campaign.LEVELS) + 1
	for &l in campaign.LEVELS {
		testing.expectf(
			t,
			!reachable(&l, l.id, limit),
			"level %q is reachable from its own prerequisites -- the graph has a cycle",
			l.id,
		)
	}
}

@(test)
test_level_numbers_are_dense_and_unique :: proc(t: ^testing.T) {
	seen := make(map[int]string, len(campaign.LEVELS), context.temp_allocator)
	for &l in campaign.LEVELS {
		other, clash := seen[l.number]
		testing.expectf(t, !clash, "levels %q and %q share number %d", other, l.id, l.number)
		seen[l.number] = l.id
	}
	for n in 1 ..= len(campaign.LEVELS) {
		_, ok := seen[n]
		testing.expectf(t, ok, "no level numbered %d -- numbering must be dense", n)
	}
}

// A level must come after everything it depends on, or the menu offers them in
// an order the player cannot follow.
@(test)
test_levels_are_numbered_after_their_prerequisites :: proc(t: ^testing.T) {
	for &l in campaign.LEVELS {
		for req in l.requires {
			prereq, ok := campaign.level_by_id(req)
			if !ok {
				continue
			}
			testing.expectf(
				t,
				prereq.number < l.number,
				"level %d (%s) requires level %d (%s), which comes later",
				l.number,
				l.id,
				prereq.number,
				prereq.id,
			)
		}
	}
}

// --- 2. tools the player can actually have ----------------------------------

// The check that matters most. A level may only make available what its
// prerequisites granted, plus what it grants itself -- otherwise it is asking
// for a tool the player has no way to hold, and is unsolvable on arrival.
@(test)
test_every_level_only_uses_tools_it_can_have :: proc(t: ^testing.T) {
	for &l in campaign.LEVELS {
		available := make([dynamic]string, 0, 8, context.temp_allocator)
		transitive_tools(&l, &available)
		for g in l.grants {
			append(&available, g)
		}

		for tool in l.tools {
			found := false
			for have in available {
				if have == tool {
					found = true
					break
				}
			}
			testing.expectf(
				t,
				found,
				"level %d (%s) offers %q, but nothing in its prerequisite chain grants it",
				l.number,
				l.id,
				tool,
			)
		}
	}
}

@(test)
test_grants_name_real_commands :: proc(t: ^testing.T) {
	for &l in campaign.LEVELS {
		for tool in l.grants {
			_, ok := shell.lookup(tool)
			testing.expectf(t, ok, "level %q grants %q, which is not a command", l.id, tool)
		}
		for tool in l.tools {
			spec, ok := shell.lookup(tool)
			testing.expectf(t, ok, "level %q offers %q, which is not a command", l.id, tool)
			// Builtins are always available and must not be listed; listing one
			// implies it could be withheld, which it cannot.
			if ok {
				testing.expectf(t, spec.job, "level %q lists builtin %q as a tool", l.id, tool)
			}
		}
	}
}

// A tool granted twice means the second grant is dead, and a player who took a
// different route through the graph might never receive it at all.
@(test)
test_no_tool_is_granted_twice :: proc(t: ^testing.T) {
	seen := make(map[string]string, 16, context.temp_allocator)
	for &l in campaign.LEVELS {
		for tool in l.grants {
			other, clash := seen[tool]
			testing.expectf(t, !clash, "%q is granted by both %q and %q", tool, other, l.id)
			seen[tool] = l.id
		}
	}
}

// Every network tool must be taught somewhere, or it is unreachable content.
@(test)
test_every_tool_is_taught_by_some_level :: proc(t: ^testing.T) {
	for spec in shell.COMMANDS {
		if !spec.job {
			continue // builtins are always available
		}
		_, ok := campaign.grants_tool(spec.name)
		testing.expectf(t, ok, "command %q is never granted by any level", spec.name)
	}
}

// --- 3. techniques ----------------------------------------------------------

@(test)
test_levels_only_teach_catalogued_techniques :: proc(t: ^testing.T) {
	for &l in campaign.LEVELS {
		testing.expectf(t, len(l.techniques) > 0, "level %q teaches no technique", l.id)
		for tech in l.techniques {
			found, ok := campaign.technique_by_id(tech.id)
			testing.expectf(t, ok, "level %q teaches %q, which is not in the catalogue", l.id, tech.id)
			if ok {
				// Catching a level that spells the same id with a different
				// name -- the reason there is a catalogue at all.
				testing.expectf(
					t,
					found.name == tech.name,
					"level %q calls %s %q; the catalogue says %q",
					l.id,
					tech.id,
					tech.name,
					found.name,
				)
			}
		}
	}
}

// --- 4. objectives point at things that exist -------------------------------

// Builds every level and checks each objective's target is really there. This
// is what catches an objective naming a host that a later edit renamed -- which
// makes the level impossible in a way nothing else would notice.
@(test)
test_every_objective_target_exists :: proc(t: ^testing.T) {
	for &l in campaign.LEVELS {
		w: sim.World
		sim.world_init(&w, 1)
		defer sim.world_destroy(&w)

		origin := l.build(&w)
		testing.expectf(t, sim.pool_valid(&w.hosts, origin), "level %q built no origin host", l.id)
		testing.expectf(t, w.origin == origin, "level %q did not set w.origin", l.id)

		testing.expectf(t, len(l.objectives) > 0, "level %q has no objectives", l.id)
		for o in l.objectives {
			testing.expectf(
				t,
				campaign.goal_target_exists(&w, o),
				"level %d (%s): objective %q points at something the level does not build",
				l.number,
				l.id,
				o.text,
			)
		}
	}
}

// A level whose objectives are already satisfied the moment it starts is not a
// level. Guards against an objective that is trivially true, like requiring
// access to the host you begin on.
@(test)
test_no_level_starts_already_complete :: proc(t: ^testing.T) {
	for &l in campaign.LEVELS {
		w: sim.World
		sim.world_init(&w, 1)
		defer sim.world_destroy(&w)
		l.build(&w)

		testing.expectf(
			t,
			!campaign.level_complete(&w, &l),
			"level %d (%s) is complete before the player does anything",
			l.number,
			l.id,
		)
	}
}

// --- 5. presentation is filled in -------------------------------------------

// Content checks. A level shipping with an empty debrief is a level that
// teaches nothing, which in this game is the actual bug.
@(test)
test_every_level_has_its_teaching_content :: proc(t: ^testing.T) {
	for &l in campaign.LEVELS {
		testing.expectf(t, len(l.title) > 0, "level %q has no title", l.id)
		testing.expectf(t, len(l.brief) > 0, "level %q has no brief", l.id)
		testing.expectf(t, len(l.debrief.what) > 0, "level %q does not say what you did", l.id)
		testing.expectf(t, len(l.debrief.why) > 0, "level %q does not say why it works", l.id)
		testing.expectf(t, len(l.debrief.defence) > 0, "level %q does not say how to defend", l.id)

		// The terminal pane is 62 cells; anything wider is clipped mid-word.
		for line in l.brief {
			testing.expectf(t, len(line) <= 62, "level %q brief line is %d cells: %q", l.id, len(line), line)
		}
		for group in ([][]string{l.debrief.what, l.debrief.why, l.debrief.defence}) {
			for line in group {
				testing.expectf(t, len(line) <= 62, "level %q debrief line is %d cells: %q", l.id, len(line), line)
			}
		}
		for o in l.objectives {
			testing.expectf(t, len(o.text) > 0, "level %q has an unnamed objective", l.id)
			testing.expectf(t, len(o.text) <= 40, "level %q objective too long: %q", l.id, o.text)
		}
	}
}

// --- hints ------------------------------------------------------------------

// Note: "every objective has its own hint" is deliberately NOT the rule. Level
// one's three objectives are all satisfied by a single sweep, so a hint per
// objective would mean writing three hints for one action. The promise that
// actually matters -- while a level is unfinished, `hint` has something useful
// to say -- is checked dynamically in playthrough_test.odin, by walking each
// level and asking at every incomplete point.

@(test)
test_hints_are_well_formed :: proc(t: ^testing.T) {
	for &l in campaign.LEVELS {
		for h, i in l.hints {
			testing.expectf(t, len(h.lines) > 0, "level %q hint %d has no text", l.id, i)
			for line in h.lines {
				testing.expectf(t, len(line) > 0, "level %q hint %d has an empty line", l.id, i)
				// Two cells narrower than the pane: hints are indented.
				testing.expectf(
					t,
					len(line) <= 60,
					"level %q hint %d line is %d cells, over the pane: %q",
					l.id,
					i,
					len(line),
					line,
				)
			}
			testing.expectf(
				t,
				h.unblocks == campaign.HINT_ANY || (h.unblocks >= 0 && h.unblocks < len(l.objectives)),
				"level %q hint %d points at objective %d, which does not exist",
				l.id,
				i,
				h.unblocks,
			)
		}
	}
}

// Hints escalate, so they must be ordered: a hint for step 3 appearing before
// one for step 1 would be revealed first and give away the ending.
@(test)
test_hints_are_ordered_by_step :: proc(t: ^testing.T) {
	for &l in campaign.LEVELS {
		highest := -1
		for h in l.hints {
			if h.unblocks == campaign.HINT_ANY {
				continue
			}
			testing.expectf(
				t,
				h.unblocks >= highest,
				"level %d (%s): a hint for step %d comes after one for step %d -- hints must escalate in order",
				l.number,
				l.id,
				h.unblocks,
				highest,
			)
			highest = max(highest, h.unblocks)
		}
	}
}

// --- progress ---------------------------------------------------------------

@(test)
test_progress_derives_tools_from_completed_levels :: proc(t: ^testing.T) {
	p: campaign.Progress
	campaign.progress_init(&p)
	defer campaign.progress_destroy(&p)

	testing.expect_value(t, len(campaign.unlocked_tools(&p, context.temp_allocator)), 0)

	campaign.mark_complete(&p, "recon-sweep")
	tools := campaign.unlocked_tools(&p, context.temp_allocator)
	testing.expect_value(t, len(tools), 1)
	testing.expect_value(t, tools[0], "nmap")

	// Completing the same level twice must not duplicate anything.
	testing.expect(t, !campaign.mark_complete(&p, "recon-sweep"), "re-completion should be a no-op")
	testing.expect_value(t, len(campaign.completed_ids(&p)), 1)

	campaign.mark_complete(&p, "recon-versions")
	campaign.mark_complete(&p, "access-exposure")
	after := campaign.unlocked_tools(&p, context.temp_allocator)
	testing.expect_value(t, len(after), 2) // nmap, curl -- level 2 grants nothing
}

@(test)
test_levels_unlock_in_order :: proc(t: ^testing.T) {
	p: campaign.Progress
	campaign.progress_init(&p)
	defer campaign.progress_destroy(&p)

	first, ok := campaign.next_level(&p)
	testing.expect(t, ok)
	testing.expect_value(t, first.number, 1)

	northwind, _ := campaign.level_by_id("northwind")
	testing.expect(t, !campaign.is_unlocked(&p, northwind), "the last level must not start unlocked")

	for id in ([]string{"recon-sweep", "recon-versions", "access-exposure", "lateral-reuse"}) {
		campaign.mark_complete(&p, id)
	}
	testing.expect(t, campaign.is_unlocked(&p, northwind), "finishing the chain should unlock it")

	next, has_next := campaign.next_level(&p)
	testing.expect(t, has_next)
	testing.expect_value(t, next.id, "northwind")
}

@(test)
test_technique_coverage_counts :: proc(t: ^testing.T) {
	p: campaign.Progress
	campaign.progress_init(&p)
	defer campaign.progress_destroy(&p)

	have, total := campaign.coverage(.Reconnaissance, campaign.covered_techniques(&p, context.temp_allocator))
	testing.expect_value(t, have, 0)
	testing.expect(t, total > 0, "the catalogue should hold reconnaissance techniques")

	campaign.mark_complete(&p, "recon-sweep")
	have2, _ := campaign.coverage(.Reconnaissance, campaign.covered_techniques(&p, context.temp_allocator))
	testing.expect_value(t, have2, 1)
}
