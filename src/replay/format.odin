package replay

import "core:fmt"
import "core:strings"

// Writing a replay out.
//
// The output is deliberately plain: one fact per line, fixed-width digests so
// two replays of the same session line up in a diff, and a header comment that
// explains the file to whoever it was pasted in front of. `fmt.sbprintf` formats
// into a builder rather than onto a stream, which is why it is allowed inside
// the purity gate at all.
//
// format refuses to write anything parse would refuse to read. Without that the
// two could drift, and the way you would find out is a corpus file that no
// longer loads.

HEADER := []string {
	"# Ceph.Sec replay.",
	"#",
	"# `cephsec --replay <this file>` plays it back and checks every mark. A mark",
	"# is the event digest and the world digest at the end of that tick; if either",
	"# differs, playback stops and says which, and when.",
	"#",
	"# Ticks are 60 to the second and restart at zero for each segment, because a",
	"# level transition resets the world clock. '#' starts a comment only as the",
	"# first character of a line.",
}

// Renders a replay as text. Returns the same errors parse would raise, so a
// replay that cannot be written is diagnosed here rather than at the next read.
format :: proc(rep: ^Replay, allocator := context.allocator) -> (out: string, err: Error) {
	if len(rep.segments) == 0 {
		return "", .No_Segments
	}
	if len(rep.segments) > MAX_SEGMENTS || len(rep.progress) > MAX_PROGRESS {
		return "", .Too_Large
	}
	if entry_count(rep) > MAX_ENTRIES {
		return "", .Too_Large
	}

	sb := strings.builder_make(allocator)

	for line in HEADER {
		strings.write_string(&sb, line)
		strings.write_byte(&sb, '\n')
	}

	fmt.sbprintf(&sb, "%s %d\n", MAGIC, FORMAT_VERSION)

	game := rep.game
	if len(game) == 0 {
		game = "unknown"
	}
	if len(game) > MAX_GAME || !id_representable(game) {
		strings.builder_destroy(&sb)
		return "", .Bad_Id
	}
	fmt.sbprintf(&sb, "game %s\n", game)
	fmt.sbprintf(&sb, "catalogue %016x\n", rep.catalogue)

	for id in rep.progress {
		if !id_representable(id) {
			strings.builder_destroy(&sb)
			return "", .Bad_Id
		}
		fmt.sbprintf(&sb, "progress %s\n", id)
	}

	for &seg in rep.segments {
		if !id_representable(seg.level) {
			strings.builder_destroy(&sb)
			return "", .Bad_Id
		}
		strings.write_byte(&sb, '\n')
		fmt.sbprintf(&sb, "segment %s %x\n", seg.level, seg.seed)

		last: u64
		for e in seg.entries {
			if u64(e.tick) < last {
				strings.builder_destroy(&sb)
				return "", .Ticks_Out_Of_Order
			}
			last = u64(e.tick)

			switch e.kind {
			case .Cmd:
				if !text_representable(e.text) {
					strings.builder_destroy(&sb)
					return "", .Bad_Text
				}
				// One space between the kind and the text, and the text carries no
				// leading or trailing whitespace of its own -- which is what makes
				// the round trip exact without any quoting.
				//
				// A submitted blank line is a real entry (it echoes a bare prompt)
				// and is written without the separator, so no line in the file ever
				// ends in a space an editor would strip.
				if len(e.text) == 0 {
					fmt.sbprintf(&sb, "at %d cmd\n", u64(e.tick))
				} else {
					fmt.sbprintf(&sb, "at %d cmd %s\n", u64(e.tick), e.text)
				}
			case .Intr:
				fmt.sbprintf(&sb, "at %d intr\n", u64(e.tick))
			case .Mark:
				fmt.sbprintf(&sb, "at %d mark %016x %016x\n", u64(e.tick), e.events, e.world)
			}
		}
	}

	return strings.to_string(sb), .None
}
