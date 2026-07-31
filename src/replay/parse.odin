package replay

import "core:strings"
import "../sim"

// The parser.
//
// This is the project's first untrusted external input. Everything before it --
// levels, the save file, the command line -- comes from the build or from the
// person at the keyboard. A replay arrives as a file someone sent you, and the
// binary that reads it is one people are actively encouraged to point at files
// from strangers.
//
// So: no raw index arithmetic anywhere. The text is cut with
// strings.split_lines, each line with strings.fields or strings.partition, and
// every field is length-checked before it is used. Numbers are parsed by hand
// with an explicit overflow check rather than through strconv, for the same
// reason save.odin does it -- what a library does with "99999999999999999999999"
// is a library's business, and this needs to be ours.
//
// UNKNOWN VERBS ARE AN ERROR. Skipping them would look tolerant and would in
// fact mean that a replay recorded by a newer build silently stops testing the
// parts the older build does not understand -- it would still pass, having
// checked less. A replay that cannot be understood in full has not been
// verified at all.

Error :: enum u8 {
	None,
	Too_Large,             // the file, or a line, or a count, exceeds a bound
	Empty,                 // nothing but comments and blank lines
	Missing_Magic,         // the first meaningful line is not `cephsec-replay <n>`
	Bad_Version,           // the version is not a number
	Unsupported_Version,   // recorded by a build whose format we do not know
	Unknown_Verb,          // see above -- deliberately fatal
	Missing_Field,         // a verb without its operands
	Trailing_Field,        // a verb with more operands than it takes
	Bad_Number,            // a tick, seed or digest that is not one
	Bad_Text,              // a control character, or leading/trailing whitespace
	Bad_Id,                // a level id that could not survive the round trip
	Entry_Outside_Segment, // an `at` line before any `segment`
	Header_After_Segment,  // a `game`/`catalogue`/`progress` line after a segment
	Ticks_Out_Of_Order,    // entries within a segment must not go backwards
	Duplicate_Header,      // two `game` or two `catalogue` lines
	No_Segments,           // a well-formed header describing nothing to play
}

error_text :: proc(e: Error) -> string {
	switch e {
	case .None:
		return "ok"
	case .Too_Large:
		return "too large"
	case .Empty:
		return "empty"
	case .Missing_Magic:
		return "not a Ceph.Sec replay (expected a `cephsec-replay <version>` line first)"
	case .Bad_Version:
		return "the format version is not a number"
	case .Unsupported_Version:
		return "recorded by a newer build; this one cannot read it"
	case .Unknown_Verb:
		return "unknown verb"
	case .Missing_Field:
		return "missing field"
	case .Trailing_Field:
		return "unexpected extra field"
	case .Bad_Number:
		return "not a number"
	case .Bad_Text:
		return "the command text contains something that would not survive a round trip"
	case .Bad_Id:
		return "not a usable level id"
	case .Entry_Outside_Segment:
		return "an `at` line before any `segment`"
	case .Header_After_Segment:
		return "a header line after the first `segment`"
	case .Ticks_Out_Of_Order:
		return "ticks within a segment must not go backwards"
	case .Duplicate_Header:
		return "repeated header line"
	case .No_Segments:
		return "no segments; there is nothing to play"
	}
	return "?"
}

// Parses a replay. `line` is the 1-based line the error was found on, so a
// message can point at it.
//
// On any error the partially built replay is destroyed and a zero value is
// returned -- there is no such thing as a half-parsed replay that is still worth
// playing, and returning one would be an invitation to play it.
parse :: proc(text: string, allocator := context.allocator) -> (rep: Replay, err: Error, line: int) {
	if len(text) > MAX_FILE {
		return {}, .Too_Large, 0
	}

	init(&rep, allocator)
	fail :: proc(rep: ^Replay, e: Error, n: int) -> (Replay, Error, int) {
		destroy(rep)
		return {}, e, n
	}

	lines := strings.split_lines(text, context.temp_allocator)
	defer delete(lines, context.temp_allocator)

	saw_magic := false
	saw_game := false
	saw_catalogue := false
	// Index rather than a pointer: add_segment may grow the backing array, and a
	// held pointer would then be into freed memory.
	segment := -1
	last_tick: sim.Tick
	total_entries := 0

	for raw, i in lines {
		n := i + 1

		if len(raw) > MAX_LINE {
			return fail(&rep, .Too_Large, n)
		}

		// '#' is a comment only as the first character of a line. Checked before
		// any trimming, so an indented '#' is not a comment -- it is an unknown
		// verb, and therefore an error. A format where whitespace decides whether
		// a line means anything is a format that breaks when it is pasted.
		if len(raw) > 0 && raw[0] == '#' {
			continue
		}

		// A file written on Windows, or pasted through one, arrives with CR.
		trimmed := strings.trim_space(strings.trim_right(raw, "\r"))
		if len(trimmed) == 0 {
			continue
		}

		fields := strings.fields(trimmed, context.temp_allocator)
		defer delete(fields, context.temp_allocator)
		if len(fields) == 0 {
			continue
		}
		verb := fields[0]

		if !saw_magic && verb != MAGIC {
			return fail(&rep, .Missing_Magic, n)
		}

		switch verb {
		case MAGIC:
			if saw_magic {
				return fail(&rep, .Duplicate_Header, n)
			}
			if len(fields) < 2 {
				return fail(&rep, .Missing_Field, n)
			}
			if len(fields) > 2 {
				return fail(&rep, .Trailing_Field, n)
			}
			v, ok := parse_dec(fields[1])
			if !ok {
				return fail(&rep, .Bad_Version, n)
			}
			// Refused rather than guessed at. A newer format may mean anything,
			// and a replay half-understood is a test that passes without testing.
			if v > FORMAT_VERSION {
				return fail(&rep, .Unsupported_Version, n)
			}
			rep.version = int(v)
			saw_magic = true

		case "game":
			if segment >= 0 {
				return fail(&rep, .Header_After_Segment, n)
			}
			if saw_game {
				return fail(&rep, .Duplicate_Header, n)
			}
			if len(fields) < 2 {
				return fail(&rep, .Missing_Field, n)
			}
			if len(fields) > 2 {
				return fail(&rep, .Trailing_Field, n)
			}
			if len(fields[1]) > MAX_GAME || !id_representable(fields[1]) {
				return fail(&rep, .Bad_Id, n)
			}
			set_game(&rep, fields[1])
			saw_game = true

		case "catalogue":
			if segment >= 0 {
				return fail(&rep, .Header_After_Segment, n)
			}
			if saw_catalogue {
				return fail(&rep, .Duplicate_Header, n)
			}
			if len(fields) < 2 {
				return fail(&rep, .Missing_Field, n)
			}
			if len(fields) > 2 {
				return fail(&rep, .Trailing_Field, n)
			}
			h, ok := parse_hex(fields[1])
			if !ok {
				return fail(&rep, .Bad_Number, n)
			}
			rep.catalogue = h
			saw_catalogue = true

		case "progress":
			if segment >= 0 {
				return fail(&rep, .Header_After_Segment, n)
			}
			if len(fields) < 2 {
				return fail(&rep, .Missing_Field, n)
			}
			if len(fields) > 2 {
				return fail(&rep, .Trailing_Field, n)
			}
			if !id_representable(fields[1]) {
				return fail(&rep, .Bad_Id, n)
			}
			if len(rep.progress) >= MAX_PROGRESS {
				return fail(&rep, .Too_Large, n)
			}
			add_progress(&rep, fields[1])

		case "segment":
			if len(fields) < 3 {
				return fail(&rep, .Missing_Field, n)
			}
			if len(fields) > 3 {
				return fail(&rep, .Trailing_Field, n)
			}
			if !id_representable(fields[1]) {
				return fail(&rep, .Bad_Id, n)
			}
			seed, ok := parse_hex(fields[2])
			if !ok {
				return fail(&rep, .Bad_Number, n)
			}
			if len(rep.segments) >= MAX_SEGMENTS {
				return fail(&rep, .Too_Large, n)
			}
			add_segment(&rep, fields[1], seed)
			segment = len(rep.segments) - 1
			last_tick = 0

		case "at":
			if segment < 0 {
				return fail(&rep, .Entry_Outside_Segment, n)
			}
			if len(fields) < 3 {
				return fail(&rep, .Missing_Field, n)
			}
			tick, tick_ok := parse_dec(fields[1])
			if !tick_ok {
				return fail(&rep, .Bad_Number, n)
			}
			// Monotonic within a segment, because playback dispatches entries as
			// the clock reaches them and can never go back for one it passed. A
			// backwards tick is a file that would silently drop entries.
			if sim.Tick(tick) < last_tick {
				return fail(&rep, .Ticks_Out_Of_Order, n)
			}
			last_tick = sim.Tick(tick)

			if total_entries >= MAX_ENTRIES {
				return fail(&rep, .Too_Large, n)
			}
			total_entries += 1

			e := Entry {
				tick = sim.Tick(tick),
			}
			switch fields[2] {
			case "cmd":
				e.kind = .Cmd
				// The text is everything after the kind, taken from the line
				// rather than from the fields, because the spacing inside a
				// command line is part of it. Skips verb, tick and kind using
				// the same whitespace rule strings.fields used to validate
				// them -- see after_fields for why that has to match.
				rest, split_ok := after_fields(trimmed, 3)
				if !split_ok {
					return fail(&rep, .Missing_Field, n)
				}
				if !text_representable(rest) {
					return fail(&rep, .Bad_Text, n)
				}
				e.text = strings.clone(rest, rep.allocator)

			case "intr":
				e.kind = .Intr
				if len(fields) > 3 {
					return fail(&rep, .Trailing_Field, n)
				}

			case "mark":
				e.kind = .Mark
				if len(fields) < 5 {
					return fail(&rep, .Missing_Field, n)
				}
				if len(fields) > 5 {
					return fail(&rep, .Trailing_Field, n)
				}
				ev, ev_ok := parse_hex(fields[3])
				wd, wd_ok := parse_hex(fields[4])
				if !ev_ok || !wd_ok {
					return fail(&rep, .Bad_Number, n)
				}
				e.events, e.world = ev, wd

			case:
				return fail(&rep, .Unknown_Verb, n)
			}
			append(&rep.segments[segment].entries, e)

		case:
			return fail(&rep, .Unknown_Verb, n)
		}
	}

	if !saw_magic {
		return fail(&rep, .Empty, 0)
	}
	if len(rep.segments) == 0 {
		return fail(&rep, .No_Segments, 0)
	}
	return rep, .None, 0
}

// --- numbers ----------------------------------------------------------------

// Decimal, unsigned, no sign, no separators, overflow rejected rather than
// wrapped. Deliberately strict: "12 " does not reach here (fields removed the
// space), and "+12", "1_2" and "0x10" are all refused, because a replay is
// machine-written and a human editing one should be told when they have written
// something the recorder never would.
parse_dec :: proc(s: string) -> (u64, bool) {
	if len(s) == 0 || len(s) > 20 {
		return 0, false
	}
	v: u64
	for b in transmute([]byte)s {
		if b < '0' || b > '9' {
			return 0, false
		}
		d := u64(b - '0')
		if v > (max(u64) - d) / 10 {
			return 0, false // would overflow
		}
		v = v * 10 + d
	}
	return v, true
}

// Lower or upper case hex, up to 16 digits, optional `0x`. Sixteen digits is
// exactly a u64, so the length check is the overflow check.
parse_hex :: proc(s: string) -> (u64, bool) {
	body := s
	if strings.has_prefix(body, "0x") || strings.has_prefix(body, "0X") {
		body = strings.trim_prefix(body, "0x")
		body = strings.trim_prefix(body, "0X")
	}
	if len(body) == 0 || len(body) > 16 {
		return 0, false
	}
	v: u64
	for b in transmute([]byte)body {
		d: u64
		switch {
		case b >= '0' && b <= '9':
			d = u64(b - '0')
		case b >= 'a' && b <= 'f':
			d = u64(b-'a') + 10
		case b >= 'A' && b <= 'F':
			d = u64(b-'A') + 10
		case:
			return 0, false
		}
		v = v * 16 + d
	}
	return v, true
}
