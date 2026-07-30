package shell

import "core:strings"
import "core:unicode/utf8"
import "../input"

// The line editor.
//
// Pure data and pure functions -- no rendering, no raylib, no clock. That is
// what lets every editing edge case (backspace at column zero, history past the
// end, word-kill across trailing spaces) be a unit test instead of something
// discovered by hand months later.
//
// Runes, not bytes: the buffer is a []rune so cursor arithmetic is uniform.
// Terminal input is mostly ASCII, but "mostly" is how off-by-one bugs get in.

HISTORY_MAX :: 128

Line :: struct {
	buf:    [dynamic]rune,
	cursor: int, // in runes, 0..len(buf)

	history:   [dynamic]string,
	// -1 means "editing a fresh line". Browsing history walks backward from the
	// end; the in-progress line is stashed so returning to the bottom restores
	// what was being typed rather than losing it.
	hist_pos:  int,
	hist_stash: string,
}

line_init :: proc(l: ^Line, allocator := context.allocator) {
	l.buf = make([dynamic]rune, 0, 128, allocator)
	l.history = make([dynamic]string, 0, 32, allocator)
	l.hist_pos = -1
}

// Only needed for a Line that owns its memory. The session's Line is backed by
// the run arena and released wholesale by world_destroy, so calling this on it
// is harmless but pointless.
line_destroy :: proc(l: ^Line, allocator := context.allocator) {
	for h in l.history {
		delete(h, allocator)
	}
	if len(l.hist_stash) > 0 {
		delete(l.hist_stash, allocator)
	}
	delete(l.buf)
	delete(l.history)
	l^ = {}
}

line_text :: proc(l: ^Line, allocator := context.allocator) -> string {
	return utf8.runes_to_string(l.buf[:], allocator)
}

line_clear :: proc(l: ^Line) {
	clear(&l.buf)
	l.cursor = 0
	l.hist_pos = -1
}

line_set :: proc(l: ^Line, text: string) {
	clear(&l.buf)
	for ch in text {
		append(&l.buf, ch)
	}
	l.cursor = len(l.buf)
}

line_insert :: proc(l: ^Line, ch: rune) {
	// Control characters arrive as named keys; letting them into the buffer
	// would put unprintable glyphs in the middle of a command.
	if ch < 32 || ch == 127 {
		return
	}
	inject_at(&l.buf, l.cursor, ch)
	l.cursor += 1
}

// --- editing ----------------------------------------------------------------

line_backspace :: proc(l: ^Line) {
	if l.cursor <= 0 {
		return
	}
	l.cursor -= 1
	ordered_remove(&l.buf, l.cursor)
}

line_delete :: proc(l: ^Line) {
	if l.cursor >= len(l.buf) {
		return
	}
	ordered_remove(&l.buf, l.cursor)
}

line_kill_to_end :: proc(l: ^Line) {
	resize(&l.buf, l.cursor)
}

line_kill_to_start :: proc(l: ^Line) {
	if l.cursor <= 0 {
		return
	}
	remove_range(&l.buf, 0, l.cursor)
	l.cursor = 0
}

// Skips trailing whitespace first, then removes the word -- so `^W` after
// "nmap -sV " kills "-sV" rather than doing nothing.
line_kill_word :: proc(l: ^Line) {
	if l.cursor <= 0 {
		return
	}
	end := l.cursor
	start := l.cursor
	for start > 0 && l.buf[start - 1] == ' ' {
		start -= 1
	}
	for start > 0 && l.buf[start - 1] != ' ' {
		start -= 1
	}
	remove_range(&l.buf, start, end)
	l.cursor = start
}

line_left :: proc(l: ^Line) {
	l.cursor = max(0, l.cursor - 1)
}

line_right :: proc(l: ^Line) {
	l.cursor = min(len(l.buf), l.cursor + 1)
}

line_home :: proc(l: ^Line) {
	l.cursor = 0
}

line_end :: proc(l: ^Line) {
	l.cursor = len(l.buf)
}

// --- history ----------------------------------------------------------------

// Consecutive duplicates are dropped, as is blank input. Re-running the same
// command three times should not cost three presses of Up to get past.
line_history_push :: proc(l: ^Line, text: string, allocator := context.allocator) {
	trimmed := strings.trim_space(text)
	if len(trimmed) == 0 {
		return
	}
	if len(l.history) > 0 && l.history[len(l.history) - 1] == trimmed {
		return
	}
	if len(l.history) >= HISTORY_MAX {
		ordered_remove(&l.history, 0)
	}
	append(&l.history, strings.clone(trimmed, allocator))
}

line_history_prev :: proc(l: ^Line, allocator := context.allocator) {
	if len(l.history) == 0 {
		return
	}
	if l.hist_pos == -1 {
		// Entering history: stash whatever was being typed. Free any previous
		// stash first -- browsing history repeatedly would otherwise leak one
		// string per trip.
		if len(l.hist_stash) > 0 {
			delete(l.hist_stash, allocator)
		}
		l.hist_stash = line_text(l, allocator)
		l.hist_pos = len(l.history)
	}
	if l.hist_pos <= 0 {
		return // already at the oldest entry; stay put rather than wrap
	}
	l.hist_pos -= 1
	line_set(l, l.history[l.hist_pos])
}

line_history_next :: proc(l: ^Line) {
	if l.hist_pos == -1 {
		return
	}
	l.hist_pos += 1
	if l.hist_pos >= len(l.history) {
		// Walked off the bottom: restore the stashed in-progress line.
		line_set(l, l.hist_stash)
		l.hist_pos = -1
		return
	}
	line_set(l, l.history[l.hist_pos])
}

// Applies one editing key. Returns true if the key was consumed, so callers can
// tell an unhandled key from a handled no-op.
line_apply_key :: proc(l: ^Line, key: input.Key, allocator := context.allocator) -> bool {
	switch key {
	case .Backspace:
		line_backspace(l)
	case .Delete:
		line_delete(l)
	case .Left:
		line_left(l)
	case .Right:
		line_right(l)
	case .Home, .Ctrl_A:
		line_home(l)
	case .End, .Ctrl_E:
		line_end(l)
	case .Ctrl_K:
		line_kill_to_end(l)
	case .Ctrl_U:
		line_kill_to_start(l)
	case .Ctrl_W:
		line_kill_word(l)
	case .Up:
		line_history_prev(l, allocator)
	case .Down:
		line_history_next(l)
	case .None, .Enter, .Tab, .Escape, .Page_Up, .Page_Down, .Ctrl_C, .Ctrl_L:
		return false // handled by the session, not the buffer
	}
	return true
}
