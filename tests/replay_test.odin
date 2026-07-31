package tests

import "core:strings"
import "core:testing"
import "../src/campaign"
import "../src/replay"
import "../src/shell"
import "../src/sim"

// The replay format, and the fact that it is untrusted input.
//
// This is the first thing in the project that reads bytes it did not write.
// Levels are compiled in, saves are written by the same build that reads them,
// and the command line comes from the person at the keyboard. A replay arrives
// as a file someone sent you, in a binary people are actively encouraged to
// point at files from strangers -- "here is the run where it went wrong" is the
// whole reason the format exists.
//
// So the negative cases get more attention here than the happy one. What is
// being asserted is not that bad input is survived but that it is *diagnosed*:
// every one of these produces a specific error and a line number, and none of
// them produces a partly-built replay that would then be played.

@(private)
HEAD :: "cephsec-replay 1\ngame test\ncatalogue 0\n"

// --- the round trip ---------------------------------------------------------

// format writes nothing parse will not read back identically. Without this the
// two would drift, and the way you would find out is a committed corpus file
// that no longer loads.
@(test)
test_a_replay_round_trips :: proc(t: ^testing.T) {
	rep: replay.Replay
	replay.init(&rep, context.temp_allocator)
	defer replay.destroy(&rep)

	replay.set_game(&rep, "round-trip")
	rep.catalogue = 0xdeadbeefcafef00d
	replay.add_progress(&rep, "recon-sweep")
	replay.add_progress(&rep, "recon-versions")

	a := replay.add_segment(&rep, "recon-sweep", 0xcef5ec)
	replay.add_entry(&rep, a, {tick = 0, kind = .Cmd, text = "nmap -sn 10.0.4.0/24"})
	replay.add_entry(&rep, a, {tick = 12, kind = .Intr})
	// A submitted blank line: it echoes a bare prompt, which is an event, so it
	// is a real entry and has to survive the round trip like any other.
	replay.add_entry(&rep, a, {tick = 13, kind = .Cmd, text = ""})
	replay.add_entry(&rep, a, {tick = 300, kind = .Mark, events = 1, world = max(u64)})

	b := replay.add_segment(&rep, "recon-versions", 1)
	replay.add_entry(&rep, b, {tick = 7, kind = .Cmd, text = "curl http://10.0.4.11/.env?a=1&b=2"})

	text, ferr := replay.format(&rep, context.temp_allocator)
	testing.expect_value(t, ferr, replay.Error.None)

	back, perr, line := replay.parse(text, context.temp_allocator)
	testing.expectf(t, perr == .None, "line %d: %s\n%s", line, replay.error_text(perr), text)
	defer replay.destroy(&back)

	testing.expect_value(t, back.version, replay.FORMAT_VERSION)
	testing.expect_value(t, back.game, "round-trip")
	testing.expect_value(t, back.catalogue, 0xdeadbeefcafef00d)
	testing.expect_value(t, len(back.progress), 2)
	testing.expect_value(t, back.progress[1], "recon-versions")
	testing.expect_value(t, len(back.segments), 2)

	testing.expect_value(t, back.segments[0].level, "recon-sweep")
	testing.expect_value(t, back.segments[0].seed, 0xcef5ec)
	testing.expect_value(t, len(back.segments[0].entries), 4)
	testing.expect_value(t, back.segments[0].entries[0].text, "nmap -sn 10.0.4.0/24")
	testing.expect_value(t, back.segments[0].entries[1].kind, replay.Kind.Intr)
	testing.expect_value(t, back.segments[0].entries[2].text, "")
	testing.expect_value(t, back.segments[0].entries[3].events, 1)
	testing.expect_value(t, back.segments[0].entries[3].world, max(u64))
	testing.expect_value(t, back.segments[1].entries[0].text, "curl http://10.0.4.11/.env?a=1&b=2")

	// No line may end in whitespace: a replay is meant to be pasted into an issue
	// and diffed there, and trailing whitespace is exactly what an editor eats.
	for l in strings.split_lines(text, context.temp_allocator) {
		testing.expectf(t, strings.trim_right_space(l) == l, "trailing whitespace on %q", l)
	}
}

// A file that came back through Windows, or through a browser. Every line ends
// CRLF and nothing about the meaning has changed.
@(test)
test_crlf_is_read_the_same_as_lf :: proc(t: ^testing.T) {
	body := HEAD + "segment recon-sweep cef5ec\nat 3 cmd nmap -sn 10.0.4.0/24\nat 9 mark 1 2\n"
	crlf, _ := strings.replace_all(body, "\n", "\r\n", context.temp_allocator)

	back, err, line := replay.parse(crlf, context.temp_allocator)
	testing.expectf(t, err == .None, "line %d: %s", line, replay.error_text(err))
	defer replay.destroy(&back)
	testing.expect_value(t, len(back.segments[0].entries), 2)
	testing.expect_value(t, back.segments[0].entries[0].text, "nmap -sn 10.0.4.0/24")
}

// --- everything that must be refused ----------------------------------------

@(private)
Bad :: struct {
	name: string,
	text: string,
	want: replay.Error,
}

@(test)
test_malformed_replays_are_diagnosed :: proc(t: ^testing.T) {
	cat :: proc(parts: ..string) -> string {
		return strings.concatenate(parts, context.temp_allocator)
	}
	long_line := cat(HEAD, strings.repeat("x", replay.MAX_LINE + 1, context.temp_allocator), "\n")
	long_id := cat(HEAD, "segment ", strings.repeat("l", replay.MAX_ID + 1, context.temp_allocator), " 1\n")
	long_text := cat(
		HEAD,
		"segment recon-sweep 1\nat 3 cmd ",
		strings.repeat("c", replay.MAX_TEXT + 1, context.temp_allocator),
		"\n",
	)

	cases := []Bad {
		// Nothing at all, and nothing that is ours.
		{"empty", "", .Empty},
		{"comments only", "# nothing here\n#\n", .Empty},
		{"someone else's file", "hello\nthis is not a replay\n", .Missing_Magic},
		{"binary", "\x00\x01\x02\xff\n", .Missing_Magic},
		{"a save file", "cephsec-progress 1\ndone recon-sweep\n", .Missing_Magic},
		{"header not first", "segment recon-sweep 1\ncephsec-replay 1\n", .Missing_Magic},

		// The version line.
		{"no version", "cephsec-replay\n", .Missing_Field},
		{"version not a number", "cephsec-replay one\n", .Bad_Version},
		{"version signed", "cephsec-replay -1\n", .Bad_Version},
		{"version from the future", "cephsec-replay 99\n", .Unsupported_Version},
		{"two version lines", "cephsec-replay 1\ncephsec-replay 1\n", .Duplicate_Header},
		{"version with junk after", "cephsec-replay 1 2\n", .Trailing_Field},

		// A well-formed header describing nothing.
		{"header only", HEAD, .No_Segments},

		// Truncation, at each of the places a file can stop.
		{"truncated verb", "cephsec-replay 1\nsegm\n", .Unknown_Verb},
		{"truncated segment", HEAD + "segment recon-sweep\n", .Missing_Field},
		{"truncated entry", HEAD + "segment recon-sweep 1\nat\n", .Missing_Field},
		{"truncated kind", HEAD + "segment recon-sweep 1\nat 3\n", .Missing_Field},
		{"truncated mark", HEAD + "segment recon-sweep 1\nat 3 mark deadbeef\n", .Missing_Field},

		// Unknown verbs are fatal, at both levels. Skipping them would look
		// tolerant and would in fact mean a replay from a newer build silently
		// stops testing whatever this build does not understand.
		{"unknown top-level verb", HEAD + "frobnicate 1\n", .Unknown_Verb},
		{"unknown entry kind", HEAD + "segment recon-sweep 1\nat 3 frobnicate\n", .Unknown_Verb},
		{"indented comment", HEAD + "  # not a comment here\n", .Unknown_Verb},

		// Numbers.
		{"negative tick", HEAD + "segment recon-sweep 1\nat -3 cmd ls\n", .Bad_Number},
		{"tick overflow", HEAD + "segment recon-sweep 1\nat 99999999999999999999999 cmd ls\n", .Bad_Number},
		{"tick with a plus", HEAD + "segment recon-sweep 1\nat +3 cmd ls\n", .Bad_Number},
		{"hex tick", HEAD + "segment recon-sweep 1\nat 0x10 cmd ls\n", .Bad_Number},
		{"seed not hex", HEAD + "segment recon-sweep zzz\n", .Bad_Number},
		{"digest not hex", HEAD + "segment recon-sweep 1\nat 3 mark zz 00\n", .Bad_Number},
		{"digest too wide", HEAD + "segment recon-sweep 1\nat 3 mark 00000000000000000 0\n", .Bad_Number},
		{"catalogue not hex", "cephsec-replay 1\ncatalogue nope\n", .Bad_Number},

		// Structure.
		{"entry before any segment", HEAD + "at 3 cmd ls\n", .Entry_Outside_Segment},
		{
			"ticks going backwards",
			HEAD + "segment recon-sweep 1\nat 9 cmd ls\nat 3 cmd ls\n",
			.Ticks_Out_Of_Order,
		},
		{"header after a segment", HEAD + "segment recon-sweep 1\ngame later\n", .Header_After_Segment},
		{
			"progress after a segment",
			HEAD + "segment recon-sweep 1\nprogress recon-sweep\n",
			.Header_After_Segment,
		},
		{"two catalogue lines", "cephsec-replay 1\ncatalogue 1\ncatalogue 2\n", .Duplicate_Header},

		// Extra operands, which mean the writer meant something this does not do.
		{"mark with three digests", HEAD + "segment recon-sweep 1\nat 3 mark 1 2 3\n", .Trailing_Field},
		{"intr with an argument", HEAD + "segment recon-sweep 1\nat 3 intr now\n", .Trailing_Field},
		{"segment with a third field", HEAD + "segment recon-sweep 1 extra\n", .Trailing_Field},
		{"progress with two ids", HEAD + "progress a b\n", .Trailing_Field},

		// Text that would not survive being written back out.
		{"control character in a command", HEAD + "segment recon-sweep 1\nat 3 cmd l\x01s\n", .Bad_Text},
		{"a DEL in a command", HEAD + "segment recon-sweep 1\nat 3 cmd l\x7fs\n", .Bad_Text},
		{"double space before the text", HEAD + "segment recon-sweep 1\nat 3 cmd  ls\n", .Bad_Text},

		// Bounds. Each of these is a bound on what a file from a stranger can
		// make this process allocate.
		{"an enormous line", long_line, .Too_Large},
		{"an enormous level id", long_id, .Bad_Id},
		{"an enormous command", long_text, .Bad_Text},
		{"an empty level id", HEAD + "progress\n", .Missing_Field},
	}

	for c in cases {
		rep, err, line := replay.parse(c.text, context.temp_allocator)
		testing.expectf(t, err == c.want, "%s: expected %v, got %v (line %d)", c.name, c.want, err, line)
		if err != .None {
			// Nothing half-parsed comes back. A partly-built replay is one
			// somebody would then play.
			testing.expectf(t, len(rep.segments) == 0, "%s: a rejected replay must come back empty", c.name)
			testing.expectf(t, len(rep.progress) == 0, "%s: a rejected replay must come back empty", c.name)
		} else {
			replay.destroy(&rep)
		}
	}
}

// A tab between the fields must read the same as a space.
//
// The tick and kind are validated with strings.fields, which splits on any
// whitespace, so `at 3\tcmd ls` passed validation -- but the text was recovered
// by partitioning on a literal " ", which desynchronised and silently returned
// a different substring. The entry parsed, and playback then reported a
// determinism divergence: the parser's error, reported as a simulation bug,
// which is the most misleading way this could fail.
//
// The doubled-space case above must keep failing. It is a difference an editor
// can introduce invisibly, so it stays an error rather than being absorbed.
@(test)
test_a_tab_between_fields_reads_as_a_separator :: proc(t: ^testing.T) {
	spaced, e1, l1 := replay.parse(HEAD + "segment recon-sweep 1\nat 3 cmd nmap -sV 10.0.4.0/24\n", context.temp_allocator)
	testing.expectf(t, e1 == .None, "the spaced form should parse, got %v (line %d)", e1, l1)
	tabbed, e2, l2 := replay.parse(HEAD + "segment recon-sweep 1\nat 3\tcmd nmap -sV 10.0.4.0/24\n", context.temp_allocator)
	testing.expectf(t, e2 == .None, "the tabbed form should parse, got %v (line %d)", e2, l2)

	testing.expect(t, len(spaced.segments) == 1 && len(tabbed.segments) == 1)
	testing.expect(t, len(spaced.segments[0].entries) == 1 && len(tabbed.segments[0].entries) == 1)

	want := spaced.segments[0].entries[0].text
	got := tabbed.segments[0].entries[0].text
	testing.expectf(t, got == want, "a tab separator changed the command: got %q, expected %q", got, want)
	testing.expectf(t, got == "nmap -sV 10.0.4.0/24", "the command text was not recovered verbatim: %q", got)
	testing.expect_value(t, tabbed.segments[0].entries[0].tick, spaced.segments[0].entries[0].tick)
}

// Too many segments, and a file over the size cap. Both are counted rather than
// discovered by running out of memory.
@(test)
test_oversized_replays_are_refused :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, HEAD)
	for _ in 0 ..= replay.MAX_SEGMENTS {
		strings.write_string(&sb, "segment recon-sweep 1\n")
	}
	_, err, _ := replay.parse(strings.to_string(sb), context.temp_allocator)
	testing.expect_value(t, err, replay.Error.Too_Large)

	huge := strings.repeat("#\n", (replay.MAX_FILE / 2) + 1, context.temp_allocator)
	_, err2, _ := replay.parse(huge, context.temp_allocator)
	testing.expect_value(t, err2, replay.Error.Too_Large)
}

// The error carries the line it was found on, because "unknown verb" without one
// is useless against a file of four hundred entries.
@(test)
test_errors_name_the_line :: proc(t: ^testing.T) {
	text := HEAD + "segment recon-sweep 1\nat 3 cmd ls\nat 9 cmd ls\nwhat\n"
	_, err, line := replay.parse(text, context.temp_allocator)
	testing.expect_value(t, err, replay.Error.Unknown_Verb)
	testing.expect_value(t, line, 7)
}

// The number parsers, directly. They are hand-rolled for the same reason
// save.odin's is: what a library does with a twenty-five digit number is the
// library's business, and this needs it to be ours.
@(test)
test_the_number_parsers_are_strict :: proc(t: ^testing.T) {
	ok_dec := []struct {
		s: string,
		v: u64,
	}{{"0", 0}, {"1", 1}, {"18446744073709551615", max(u64)}}
	for c in ok_dec {
		v, ok := replay.parse_dec(c.s)
		testing.expectf(t, ok && v == c.v, "parse_dec(%q) = %v, %v", c.s, v, ok)
	}
	bad_dec := []string {
		"",
		" ",
		"-1",
		"+1",
		"1.0",
		"0x1",
		"18446744073709551616", // one past max(u64)
		"99999999999999999999999",
		"1_000",
	}
	for s in bad_dec {
		_, ok := replay.parse_dec(s)
		testing.expectf(t, !ok, "parse_dec(%q) should have been refused", s)
	}

	ok_hex := []struct {
		s: string,
		v: u64,
	}{{"0", 0}, {"ff", 255}, {"FF", 255}, {"0xff", 255}, {"ffffffffffffffff", max(u64)}}
	for c in ok_hex {
		v, ok := replay.parse_hex(c.s)
		testing.expectf(t, ok && v == c.v, "parse_hex(%q) = %v, %v", c.s, v, ok)
	}
	bad_hex := []string{"", "0x", "g", "-1", "0xffffffffffffffff0", "00000000000000000"}
	for s in bad_hex {
		_, ok := replay.parse_hex(s)
		testing.expectf(t, !ok, "parse_hex(%q) should have been refused", s)
	}
}

// --- what playback refuses to do --------------------------------------------

@(private)
play_text :: proc(t: ^testing.T, text: string) -> shell.Playback {
	rep, err, line := replay.parse(text, context.temp_allocator)
	if !testing.expectf(t, err == .None, "line %d: %s", line, replay.error_text(err)) {
		return {}
	}
	defer replay.destroy(&rep)
	return corpus_play(&rep, .Verify, nil)
}

// A well-formed file can still describe something this build cannot do. Each of
// these is refused with a reason rather than played as far as it will go, which
// would report success for a replay that was never finished.
@(test)
test_playback_refuses_what_it_cannot_reproduce :: proc(t: ^testing.T) {
	// A level this build has never heard of.
	pb := play_text(t, HEAD + "segment no-such-level 1\nat 3 cmd ls\n")
	testing.expect_value(t, pb.why, shell.Divergence.Unknown_Level)

	// Progress naming a level this build has never heard of. Playing anyway would
	// silently change what is unlocked, and therefore what commands do.
	pb = play_text(t, "cephsec-replay 1\nprogress no-such-level\nsegment recon-sweep 1\nat 3 cmd ls\n")
	testing.expect_value(t, pb.why, shell.Divergence.Unknown_Level)

	// A second segment the first never transitions into.
	pb = play_text(
		t,
		HEAD + "segment recon-sweep 1\nat 3 cmd ls\n\nsegment recon-versions 1\nat 3 cmd ls\n",
	)
	testing.expect_value(t, pb.why, shell.Divergence.Missing_Transition)

	// A transition that goes somewhere the next segment does not.
	pb = play_text(
		t,
		HEAD +
		"progress recon-sweep\nprogress recon-versions\n" +
		"segment recon-sweep 1\nat 3 cmd play 3\n\nsegment recon-versions 1\nat 3 cmd ls\n",
	)
	testing.expect_value(t, pb.why, shell.Divergence.Level_Mismatch)

	// A mark that does not match. The digests are what make a replay a test.
	pb = play_text(t, HEAD + "segment recon-sweep 1\nat 3 mark 1 2\n")
	testing.expect_value(t, pb.why, shell.Divergence.Events_Digest)
	testing.expect_value(t, pb.want, 1)
	testing.expect(t, pb.got != 1)

	// A file describing a run that never ends. The guard is a bound on what a
	// stranger's file can make this process do, not a tuning knob.
	pb = play_text(t, HEAD + "segment recon-sweep 1\nat 99999999 cmd ls\n")
	testing.expect_value(t, pb.why, shell.Divergence.Ran_Too_Long)
}

// A replay that passes carries the run's own answers, so a build that changed
// behaviour cannot make one pass by reproducing itself. Prove the check is real
// by handing playback a mark taken from a different tick.
@(test)
test_a_mark_from_the_wrong_tick_is_caught :: proc(t: ^testing.T) {
	// Take two genuine marks from one run.
	w: sim.World
	sim.world_init(&w, 0xCEF5EC)
	defer sim.world_destroy(&w)

	prog: campaign.Progress
	campaign.progress_init(&prog)
	defer campaign.progress_destroy(&prog)

	level, _ := campaign.level_by_id("recon-sweep")
	sess: shell.Session
	shell.level_start(&sess, &w, &prog, level, 0xCEF5EC)

	p: shell.Pump
	for _ in 0 ..< 120 {
		shell.pump_tick(&p, &sess)
	}
	at_120_events, at_120_world := sim.events_digest(&w), sim.world_digest(&w)
	for _ in 0 ..< 120 {
		shell.pump_tick(&p, &sess)
	}
	at_240_events, at_240_world := sim.events_digest(&w), sim.world_digest(&w)

	// The right digest at the wrong tick is still wrong: the world digest carries
	// the clock, so a mark means something about the tick it sits on.
	moved := strings.concatenate(
		{HEAD, "segment recon-sweep cef5ec\n", "at 240 mark ", hex16(at_120_events), " ", hex16(at_120_world), "\n"},
		context.temp_allocator,
	)
	pb := play_text(t, moved)
	testing.expect_value(t, pb.why, shell.Divergence.World_Digest)

	// And both genuine pairs, each at its own tick, reproduce -- so the check
	// above is catching the move rather than simply always failing.
	genuine := strings.concatenate(
		{
			HEAD,
			"segment recon-sweep cef5ec\n",
			"at 120 mark ", hex16(at_120_events), " ", hex16(at_120_world), "\n",
			"at 240 mark ", hex16(at_240_events), " ", hex16(at_240_world), "\n",
		},
		context.temp_allocator,
	)
	ok_pb := play_text(t, genuine)
	testing.expectf(t, ok_pb.ok, "genuine marks should reproduce: %s", shell.divergence_text(ok_pb.why))
	testing.expect_value(t, ok_pb.marks_checked, 2)
}

@(private)
hex16 :: proc(v: u64) -> string {
	digits := "0123456789abcdef"
	buf := make([]byte, 16, context.temp_allocator)
	x := v
	for i := 15; i >= 0; i -= 1 {
		buf[i] = digits[x & 0xf]
		x >>= 4
	}
	return string(buf)
}
