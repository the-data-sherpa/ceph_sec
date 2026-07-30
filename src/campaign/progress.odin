package campaign

// What the player has done, and therefore what they can use.
//
// The unlocked tool set is *derived* from completed levels rather than stored
// alongside them. Two sources of truth would drift the first time a level's
// `grants` changed, and a save file written before that change would hand out
// the wrong tools forever. Deriving costs a loop over a list of at most sixty
// entries, which is free.
//
// In memory this milestone. Persisting it is M5, and is the point at which the
// project acquires its first file I/O -- which will live in `main`, because this
// package is inside the purity gate and will stay there.

Progress :: struct {
	completed: [dynamic]string, // level ids, in the order they were finished
	current:   string,          // the level being played; "" when in the menu
}

progress_init :: proc(p: ^Progress, allocator := context.allocator) {
	p.completed = make([dynamic]string, 0, 16, allocator)
	p.current = ""
}

progress_destroy :: proc(p: ^Progress) {
	delete(p.completed)
	p^ = {}
}

completed_ids :: proc(p: ^Progress) -> []string {
	return p.completed[:]
}

is_complete :: proc(p: ^Progress, id: string) -> bool {
	for done in p.completed {
		if done == id {
			return true
		}
	}
	return false
}

// Recording a completion twice must not duplicate it -- replaying a level for a
// better result is expected, and should not corrupt the record.
mark_complete :: proc(p: ^Progress, id: string) -> bool {
	if is_complete(p, id) {
		return false
	}
	append(&p.completed, id)
	return true
}

// A level is playable once every prerequisite is complete. Levels with no
// prerequisites are always playable, which is how the campaign starts.
is_unlocked :: proc(p: ^Progress, l: ^Level) -> bool {
	for req in l.requires {
		if !is_complete(p, req) {
			return false
		}
	}
	return true
}

// Every command the player has permanently earned.
//
// Note this is what they *own*, not what a given level makes available: a level
// declares its own `tools`, which the validator proves is a subset of this. That
// separation is what lets a later level withhold something you own.
unlocked_tools :: proc(p: ^Progress, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, 16, allocator)
	for id in p.completed {
		l, ok := level_by_id(id)
		if !ok {
			continue
		}
		for tool in l.grants {
			already := false
			for have in out {
				if have == tool {
					already = true
					break
				}
			}
			if !already {
				append(&out, tool)
			}
		}
	}
	return out[:]
}

// Technique ids covered by completed levels, for the coverage table.
covered_techniques :: proc(p: ^Progress, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, 16, allocator)
	for id in p.completed {
		l, ok := level_by_id(id)
		if !ok {
			continue
		}
		for tech in l.techniques {
			already := false
			for have in out {
				if have == tech.id {
					already = true
					break
				}
			}
			if !already {
				append(&out, tech.id)
			}
		}
	}
	return out[:]
}

// The lowest-numbered level that is unlocked and not yet complete -- what "play"
// with no argument should start, and what the menu should highlight.
next_level :: proc(p: ^Progress) -> (^Level, bool) {
	best: ^Level
	for &l in LEVELS {
		if is_complete(p, l.id) || !is_unlocked(p, &l) {
			continue
		}
		if best == nil || l.number < best.number {
			best = &l
		}
	}
	return best, best != nil
}

// Which level teaches a command, for the "you cannot use this yet" message.
// Naming the level is the difference between a refusal that teaches and one that
// merely blocks.
grants_tool :: proc(tool: string) -> (^Level, bool) {
	for &l in LEVELS {
		for granted in l.grants {
			if granted == tool {
				return &l, true
			}
		}
	}
	return nil, false
}
