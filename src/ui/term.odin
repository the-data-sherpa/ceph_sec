package ui

// Terminal scrollback.
//
// Kept free of any `sim` types on purpose: this package renders, it does not
// know what a host or a trace is. Callers map their own domain events onto a
// Color_Id and push a line. That keeps the presentation layer reusable for the
// net map, job output and log panes without each one dragging sim into the UI.

TERM_SCROLLBACK :: 512

Term_Line :: struct {
	text:  string,
	color: Color_Id,
	attr:  Attrs,
}

Term :: struct {
	lines:  [TERM_SCROLLBACK]Term_Line,
	head:   int, // next slot to write
	count:  int, // live lines, saturating at TERM_SCROLLBACK
	scroll: int, // lines scrolled up from the bottom
}

// Strings are stored by reference, not copied. Sim log text lives in the run
// arena and outlives the scrollback, so copying would be pure waste.
term_push :: proc(t: ^Term, text: string, color: Color_Id = .Text, attr: Attrs = {}) {
	t.lines[t.head] = Term_Line {
		text  = text,
		color = color,
		attr  = attr,
	}
	t.head = (t.head + 1) % TERM_SCROLLBACK
	if t.count < TERM_SCROLLBACK {
		t.count += 1
	}
	// Pin the view to the bottom when the user is already there; if they have
	// scrolled up to read something, hold their position instead of yanking it
	// away every time a background job prints.
	if t.scroll > 0 {
		t.scroll = min(t.scroll + 1, t.count - 1)
	}
}

term_clear :: proc(t: ^Term) {
	t.head = 0
	t.count = 0
	t.scroll = 0
}

// Index 0 is the oldest retained line.
term_line :: proc(t: ^Term, i: int) -> Term_Line {
	if i < 0 || i >= t.count {
		return {}
	}
	idx := (t.head - t.count + i + 2 * TERM_SCROLLBACK) % TERM_SCROLLBACK
	return t.lines[idx]
}

term_scroll_by :: proc(t: ^Term, delta: int, viewport_h: int) {
	max_scroll := max(0, t.count - viewport_h)
	t.scroll = clamp(t.scroll + delta, 0, max_scroll)
}

term_scroll_to_bottom :: proc(t: ^Term) {
	t.scroll = 0
}

// Renders the visible window into the grid, bottom-aligned. Lines longer than
// the viewport are clipped rather than wrapped -- tool output is column-aligned
// and wrapping it would break the alignment that makes it readable.
term_draw :: proc(t: ^Term, g: ^Grid, x, y, w, h: int, bg: Color_Id = .Bg_Panel) {
	if w <= 0 || h <= 0 {
		return
	}

	visible := min(h, t.count)
	first := t.count - visible - t.scroll
	if first < 0 {
		first = 0
	}

	// Bottom-align a partially-filled buffer so early output starts at the top
	// of the pane and grows downward, like a real console.
	row := y + (h - visible if t.count < h else 0)

	for i in 0 ..< visible {
		line := term_line(t, first + i)
		grid_fill(g, x, row, w, 1, ' ', .Text, bg)
		if len(line.text) > 0 {
			grid_write(g, x, row, line.text, line.color, bg, line.attr)
		}
		row += 1
	}
}

// The live input line: prompt, buffer, and a block cursor sitting on the
// character it would overwrite.
//
// Scrolls horizontally to keep the cursor visible, because a long `nmap`
// invocation is easily wider than the pane and a cursor you cannot see is
// worse than truncated text.
term_draw_input :: proc(
	g: ^Grid,
	x, y, w: int,
	prompt: string,
	text: string,
	cursor: int,
	busy: bool,
	blink_on: bool,
	bg: Color_Id = .Bg_Panel,
) {
	if w <= 0 {
		return
	}
	grid_fill(g, x, y, w, 1, ' ', .Text, bg)

	// A busy terminal shows the prompt dimmed and no cursor: the shell is not
	// listening, and the display should say so rather than invite typing.
	prompt_color: Color_Id = busy ? .Dim : .Good
	end := grid_write(g, x, y, prompt, prompt_color, bg, busy ? {} : Attrs{.Bold})

	if busy {
		return
	}

	avail := w - (end - x)
	if avail <= 0 {
		return
	}

	// Slide the window so the cursor stays inside it, keeping a little context
	// to the left once we have scrolled.
	runes := make([dynamic]rune, 0, len(text), context.temp_allocator)
	for ch in text {
		append(&runes, ch)
	}

	start := 0
	if cursor >= avail {
		start = cursor - avail + 1
	}

	col := end
	for i in start ..< len(runes) {
		if col >= x + w {
			break
		}
		on_cursor := i == cursor
		grid_set(
			g,
			col,
			y,
			runes[i],
			on_cursor && blink_on ? bg : .Bright,
			on_cursor && blink_on ? .Cursor : bg,
		)
		col += 1
	}

	// Cursor past the last character: draw it as a solid block on the empty
	// cell, which is where the next keystroke lands.
	if cursor >= len(runes) && col < x + w && blink_on {
		grid_set(g, col, y, ' ', bg, .Cursor)
	}
}
