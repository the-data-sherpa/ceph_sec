package shell

import "core:fmt"
import "core:strconv"
import "core:strings"
import "../campaign"
import "../sim"

// Commands that talk about the campaign rather than the network.
//
// These read `Session.level` and `Session.progress`, both of which point at
// storage `main` owns. Starting or restarting a level cannot happen here: the
// transition destroys the arena this session's own strings live in. They record
// intent in `pending_transition` and `main` performs it -- the same shape as a
// job's pending move.

// --- availability -----------------------------------------------------------

// Whether a command can be used in the level currently being played.
//
// Builtins are always available: they happen on a box you already hold and
// cannot be withheld. Tools are available only if the level lists them, which
// is deliberately narrower than "the player has unlocked it" -- a later level
// can hand you a network where the obvious tool does not apply.
//
// Availability is a property of the *level*, so a session with no level has
// nothing to gate against and everything is available. That is the sandbox the
// engine test suites run in, and it is why they need no campaign.
//
// A level listing no tools is not the same thing: that is a level played with
// builtins alone, which is a legitimate shape (reading what is already in front
// of you) and stays fully gated.
tool_available :: proc(s: ^Session, spec: Command_Spec) -> bool {
	if !spec.job || s.level == nil {
		return true
	}
	for t in s.tools {
		if t == spec.name {
			return true
		}
	}
	return false
}

// Why a tool is not available, phrased so the refusal teaches rather than
// merely blocks. Two distinct cases: you have not learned it yet, or you have
// and this scenario does not offer it.
@(private)
unavailable_reason :: proc(s: ^Session, spec: Command_Spec) -> string {
	if s.progress != nil {
		owned := false
		for t in campaign.unlocked_tools(s.progress, context.temp_allocator) {
			if t == spec.name {
				owned = true
				break
			}
		}
		if !owned {
			if l, ok := campaign.grants_tool(spec.name); ok {
				return fmt.tprintf("not learned yet -- level %d teaches it (%s)", l.number, l.title)
			}
			return "not learned yet"
		}
	}
	return "not available in this scenario"
}

// --- levels -----------------------------------------------------------------

cmd_levels :: proc(s: ^Session, cmd: ^Command) {
	if s.progress == nil {
		out(s, "no campaign loaded", .Bad)
		return
	}

	out(s, "levels:", .Info)
	current_tactic := campaign.Tactic(255)

	for &l in campaign.LEVELS {
		if len(l.techniques) > 0 && l.techniques[0].tactic != current_tactic {
			current_tactic = l.techniques[0].tactic
			out(s, fmt.tprintf("  [%s]", campaign.tactic_name(current_tactic)), .Info)
		}

		done := campaign.is_complete(s.progress, l.id)
		open := campaign.is_unlocked(s.progress, &l)
		playing := s.level != nil && s.level.id == l.id

		mark := " "
		level: sim.Log_Level = .Plain
		switch {
		case playing:
			mark, level = ">", .Heading
		case done:
			mark, level = "x", .Good
		case !open:
			mark, level = "-", .Info
		}

		out(s, fmt.tprintf("  %s %2d  %-26s %s", mark, l.number, l.title, campaign.kind_label(l.kind)), level)
	}

	out(s, "", .Plain)
	if next, ok := campaign.next_level(s.progress); ok {
		out(s, fmt.tprintf("`play %d` to start: %s", next.number, next.title), .Info)
	} else {
		out(s, "every level complete.", .Good)
	}
}

cmd_play :: proc(s: ^Session, cmd: ^Command) {
	if s.progress == nil {
		out(s, "no campaign loaded", .Bad)
		return
	}

	target: ^campaign.Level
	if arg, given := positional(cmd, 0); given {
		n, parsed := strconv.parse_int(arg)
		if !parsed {
			out(s, fmt.tprintf("play: not a level number: %s", arg), .Bad)
			return
		}
		l, found := campaign.level_by_number(n)
		if !found {
			out(s, fmt.tprintf("play: no level %d", n), .Bad)
			return
		}
		target = l
	} else {
		l, found := campaign.next_level(s.progress)
		if !found {
			out(s, "every level is complete. `levels` to replay one.", .Good)
			return
		}
		target = l
	}

	// Locked levels name what is missing, so the player knows what to do about
	// it rather than only that they cannot proceed.
	if !campaign.is_unlocked(s.progress, target) {
		out(s, fmt.tprintf("level %d is locked.", target.number), .Bad)
		for req in target.requires {
			if campaign.is_complete(s.progress, req) {
				continue
			}
			if prereq, ok := campaign.level_by_id(req); ok {
				out(s, fmt.tprintf("  finish level %d first: %s", prereq.number, prereq.title), .Info)
			}
		}
		return
	}

	s.pending_transition = Transition {
		level = target.number,
	}
}

cmd_retry :: proc(s: ^Session, cmd: ^Command) {
	if s.level == nil {
		out(s, "retry: no level in progress", .Bad)
		return
	}
	s.pending_transition = Transition {
		level = s.level.number,
		retry = true,
	}
}

// --- objectives -------------------------------------------------------------

cmd_objectives :: proc(s: ^Session, cmd: ^Command) {
	if s.level == nil {
		out(s, "no level in progress", .Info)
		return
	}

	out(s, s.level.title, .Heading)
	for tech in s.level.techniques {
		out(s, fmt.tprintf("  %s  %s", tech.id, tech.name), .Info)
	}
	out(s, "", .Plain)

	for o in s.level.objectives {
		met := campaign.objective_met(s.world, o)
		box := met ? "[x]" : "[ ]"
		tag := o.optional ? "  (optional)" : ""
		out(
			s,
			fmt.tprintf("  %s %s%s", box, o.text, tag),
			met ? .Good : (o.optional ? .Info : .Plain),
		)
	}
}

// --- technique coverage -----------------------------------------------------

cmd_techniques :: proc(s: ^Session, cmd: ^Command) {
	if s.progress == nil {
		out(s, "no campaign loaded", .Bad)
		return
	}

	covered := campaign.covered_techniques(s.progress, context.temp_allocator)
	out(s, "ATT&CK coverage:", .Info)

	total_have, total_all := 0, 0
	for tactic in campaign.Tactic {
		have, all := campaign.coverage(tactic, covered)
		if all == 0 {
			continue // the campaign does not cover this tactic yet
		}
		total_have += have
		total_all += all

		bar := strings.builder_make(context.temp_allocator)
		for i in 0 ..< all {
			strings.write_string(&bar, i < have ? "#" : ".")
		}
		out(
			s,
			fmt.tprintf("  %-16s %d/%d  %s", campaign.tactic_short(tactic), have, all, strings.to_string(bar)),
			have == all ? .Good : (have > 0 ? .Data : .Info),
		)
	}

	out(s, "", .Plain)
	out(s, fmt.tprintf("%d of %d techniques covered.", total_have, total_all), .Info)
	if total_have < total_all {
		out(s, "the catalogue grows as the campaign does.", .Info)
	}
}
