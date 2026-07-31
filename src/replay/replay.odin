// Package replay is the replay file format: what it is, and how to turn it into
// text and back.
//
// Parsing and formatting only. Nothing here opens a file -- `save` and `main`
// own that -- and this package is inside the purity gate for the same reason the
// simulation is: a replay is played by driving the real shell against the real
// world, and a format that could reach the outside world would be a way for a
// file from a stranger to do the same.
//
// WHY THIS EXISTS AT ALL, given `--exec`:
//
//   Timing is content. Trace decay, suspicion cooldown, job completion and the
//   hunt are all functions of elapsed ticks. `--exec` dispatches each command as
//   soon as the shell frees up, so "scan, wait forty seconds, scan again" cannot
//   be written down -- and every decay, grace and hunt bug lives exactly there.
//   A replay carries the tick each command landed on.
//
//   Interrupts. ^C has no --exec representation at all.
//
//   Progress. What is unlocked changes what commands do, so a script that means
//   one thing on a fresh save means another on a finished one. A replay carries
//   the progress it was recorded against.
//
//   Verification. A replay carries digests, so it is a test. `--exec` has no
//   notion of a correct outcome; it only has a notion of having run.
//
// THE FORMAT IS UNTRUSTED INPUT. It is line-based text, pasteable into an issue
// and diffable there, which means people will run replays they were sent. Every
// field is length-checked, every number is parsed by hand with an explicit
// overflow check, and an unknown verb is an ERROR rather than a skipped line --
// silently skipping is how a replay quietly stops testing anything.
package replay

import "core:mem"
import "core:strings"
import "../sim"

MAGIC :: "cephsec-replay"
FORMAT_VERSION :: 1

// What one recorded moment was.
//
// Deliberately only three. A replay records what a player did (Cmd, Intr) and
// what was true afterwards (Mark); it does not record what the game did in
// response, because reproducing that is the entire point of playing it back.
Kind :: enum u8 {
	Cmd,  // a command line submitted at the prompt
	Intr, // ^C
	Mark, // a checkpoint: the two digests, as they were at the end of this tick
}

kind_name :: proc(k: Kind) -> string {
	switch k {
	case .Cmd:
		return "cmd"
	case .Intr:
		return "intr"
	case .Mark:
		return "mark"
	}
	return "?"
}

Entry :: struct {
	tick: sim.Tick,
	kind: Kind,
	text: string, // Cmd only; "" for the rest

	// Mark only. Two digests, because either can move without the other: a world
	// that reached the same state by a different route matches on `world` and
	// differs on `events`, and that difference is a real divergence.
	events: u64,
	world:  u64,
}

// One level, played from its first tick.
//
// Segments exist because a level transition resets the world clock to zero.
// Recording one flat stream of ticks across a transition would need every
// consumer to know where the resets were; a segment boundary says it once.
Segment :: struct {
	level:   string, // level id, never the display number -- see Transition
	seed:    u64,
	entries: [dynamic]Entry,
}

Replay :: struct {
	version: int,
	game:    string, // the build that recorded it, for a human reading a bug report

	// A content hash of the campaign catalogue. Levels are compiled-in data, so a
	// replay is only meaningful against the catalogue it was recorded against;
	// this is what lets playback say "the campaign changed" instead of "digest
	// mismatch at tick 300".
	catalogue: u64,

	// Completed level ids at the moment recording started, in the order they were
	// finished. What is unlocked changes what commands do, so a replay that did
	// not carry this would reproduce only on the machine it came from.
	progress: [dynamic]string,

	segments: [dynamic]Segment,

	allocator: mem.Allocator,
}

// --- limits -----------------------------------------------------------------
//
// Every one of these is a bound on what a file from a stranger can make this
// process allocate or do. They are generous next to any real replay -- the
// committed corpus is a few hundred entries -- and they are checked before the
// allocation rather than after.

MAX_FILE :: 4 << 20 // 4 MiB of text
MAX_LINE :: 4096
MAX_TEXT :: 512   // one command line
MAX_ID :: 64      // one level id
MAX_GAME :: 128
MAX_ENTRIES :: 1 << 16
MAX_SEGMENTS :: 512
MAX_PROGRESS :: 512

// --- lifetime ---------------------------------------------------------------

init :: proc(rep: ^Replay, allocator := context.allocator) {
	rep.allocator = allocator
	rep.version = FORMAT_VERSION
	rep.progress = make([dynamic]string, 0, 8, allocator)
	rep.segments = make([dynamic]Segment, 0, 4, allocator)
}

destroy :: proc(rep: ^Replay) {
	a := rep.allocator
	delete(rep.game, a)
	for id in rep.progress {
		delete(id, a)
	}
	delete(rep.progress)
	for &seg in rep.segments {
		delete(seg.level, a)
		for e in seg.entries {
			delete(e.text, a)
		}
		delete(seg.entries)
	}
	delete(rep.segments)
	rep^ = {}
}

// Appends a segment and returns a pointer to it.
//
// The pointer is invalidated by the next add_segment -- take the index, or
// finish with one segment before starting the next, which is what recording
// does anyway.
add_segment :: proc(rep: ^Replay, level: string, seed: u64) -> ^Segment {
	append(
		&rep.segments,
		Segment {
			level = strings.clone(level, rep.allocator),
			seed = seed,
			entries = make([dynamic]Entry, 0, 64, rep.allocator),
		},
	)
	return &rep.segments[len(rep.segments) - 1]
}

// Appends an entry, taking a copy of its text. Never borrows: an entry outlives
// whatever produced it, and `destroy` frees every text it holds -- so an entry
// holding a borrowed string would be a bad free waiting for a corpus generator
// to pass a literal.
add_entry :: proc(rep: ^Replay, seg: ^Segment, e: Entry) {
	entry := e
	if entry.kind == .Cmd {
		entry.text = strings.clone(e.text, rep.allocator)
	} else {
		entry.text = ""
	}
	append(&seg.entries, entry)
}

add_progress :: proc(rep: ^Replay, id: string) {
	append(&rep.progress, strings.clone(id, rep.allocator))
}

set_game :: proc(rep: ^Replay, game: string) {
	delete(rep.game, rep.allocator)
	rep.game = strings.clone(game, rep.allocator)
}

// Total entries across every segment, for the bound checks and for reporting.
entry_count :: proc(rep: ^Replay) -> int {
	n := 0
	for &seg in rep.segments {
		n += len(seg.entries)
	}
	return n
}

mark_count :: proc(rep: ^Replay) -> int {
	n := 0
	for &seg in rep.segments {
		for e in seg.entries {
			if e.kind == .Mark {
				n += 1
			}
		}
	}
	return n
}

// --- what a text field may contain ------------------------------------------

// Whether a command line survives a round trip through the file.
//
// A replay is meant to be pasted into an issue and diffed there, so anything an
// editor would silently alter must not be representable: no control characters,
// no leading or trailing whitespace. Enforced on the way out as well as on the
// way in, so the formatter can never write a file the parser would reject.
text_representable :: proc(s: string) -> bool {
	if len(s) > MAX_TEXT {
		return false
	}
	if strings.trim_space(s) != s {
		return false
	}
	for b in transmute([]byte)s {
		if b < 0x20 || b == 0x7f {
			return false
		}
	}
	return true
}

// A level id, as it appears on a `segment` or `progress` line. Must survive
// being one whitespace-separated field.
id_representable :: proc(s: string) -> bool {
	if len(s) == 0 || len(s) > MAX_ID {
		return false
	}
	for b in transmute([]byte)s {
		if b <= 0x20 || b == 0x7f {
			return false
		}
	}
	return true
}
