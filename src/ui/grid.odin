package ui

import "core:unicode/utf8"

// A character grid, and nothing else -- no raylib, no drawing. Everything the
// game shows (terminal, net map, panels, status bars) composites into this one
// buffer, which then gets rasterised and CRT-warped exactly once. Nothing can
// accidentally escape the screen effect by drawing straight to the window.

Attr :: enum u8 {
	Bold,
	Underline,
	Reverse,
}

Attrs :: bit_set[Attr;u8]

Cell :: struct {
	ch:   rune,
	fg:   Color_Id,
	bg:   Color_Id,
	attr: Attrs,
}

Grid :: struct {
	w, h:  int,
	cells: []Cell,
}

grid_make :: proc(w, h: int, allocator := context.allocator) -> Grid {
	return Grid{w = w, h = h, cells = make([]Cell, w * h, allocator)}
}

grid_destroy :: proc(g: ^Grid) {
	delete(g.cells)
	g^ = {}
}

grid_in_bounds :: proc(g: ^Grid, x, y: int) -> bool {
	return x >= 0 && y >= 0 && x < g.w && y < g.h
}

grid_at :: proc(g: ^Grid, x, y: int) -> ^Cell {
	if !grid_in_bounds(g, x, y) {
		return nil
	}
	return &g.cells[y * g.w + x]
}

grid_clear :: proc(g: ^Grid, bg: Color_Id = .Bg) {
	blank := Cell {
		ch = ' ',
		fg = .Text,
		bg = bg,
	}
	for i in 0 ..< len(g.cells) {
		g.cells[i] = blank
	}
}

grid_set :: proc(g: ^Grid, x, y: int, ch: rune, fg: Color_Id = .Text, bg: Color_Id = .Bg, attr: Attrs = {}) {
	c := grid_at(g, x, y)
	if c == nil {
		return
	}
	c^ = Cell {
		ch   = ch,
		fg   = fg,
		bg   = bg,
		attr = attr,
	}
}

// Writes without wrapping; clipped at the right edge. Returns the column just
// past the last glyph written, so callers can chain differently-coloured runs.
grid_write :: proc(
	g: ^Grid,
	x, y: int,
	text: string,
	fg: Color_Id = .Text,
	bg: Color_Id = .Bg,
	attr: Attrs = {},
) -> int {
	cx := x
	for ch in text {
		if cx >= g.w {
			break
		}
		if cx >= 0 {
			grid_set(g, cx, y, ch, fg, bg, attr)
		}
		cx += 1
	}
	return cx
}

// Word-wrapped write into a column-bounded region. Returns the next free row --
// the terminal scrollback needs this to lay out multi-line tool output.
grid_write_wrapped :: proc(
	g: ^Grid,
	x, y, width: int,
	text: string,
	fg: Color_Id = .Text,
	bg: Color_Id = .Bg,
) -> int {
	if width <= 0 {
		return y
	}
	cx, cy := x, y
	for word, i in split_words(text) {
		wlen := utf8.rune_count_in_string(word)
		if cx > x && cx + wlen > x + width {
			cx = x
			cy += 1
		}
		if cy >= g.h {
			return cy
		}
		// A single word longer than the region gets hard-broken rather than
		// silently truncated.
		if wlen > width {
			for ch in word {
				if cx >= x + width {
					cx = x
					cy += 1
					if cy >= g.h {
						return cy
					}
				}
				grid_set(g, cx, cy, ch, fg, bg)
				cx += 1
			}
		} else {
			grid_write(g, cx, cy, word, fg, bg)
			cx += wlen
		}
		if i >= 0 && cx < x + width {
			grid_set(g, cx, cy, ' ', fg, bg)
			cx += 1
		}
	}
	return cy + 1
}

@(private)
split_words :: proc(text: string) -> []string {
	// Small fixed-cap splitter using the temp allocator; scrollback lines are
	// short and this runs once per line per frame at most.
	words := make([dynamic]string, 0, 16, context.temp_allocator)
	start := -1
	for i in 0 ..< len(text) {
		if text[i] == ' ' {
			if start >= 0 {
				append(&words, text[start:i])
				start = -1
			}
		} else if start < 0 {
			start = i
		}
	}
	if start >= 0 {
		append(&words, text[start:])
	}
	return words[:]
}

grid_fill :: proc(g: ^Grid, x, y, w, h: int, ch: rune = ' ', fg: Color_Id = .Text, bg: Color_Id = .Bg) {
	for yy in y ..< y + h {
		for xx in x ..< x + w {
			grid_set(g, xx, yy, ch, fg, bg)
		}
	}
}

// Box-drawing characters. These are rendered as vector strokes rather than
// glyphs (see draw.odin), so they stay pixel-exact and need no font coverage.
BOX_H :: '─'
BOX_V :: '│'
BOX_TL :: '┌'
BOX_TR :: '┐'
BOX_BL :: '└'
BOX_BR :: '┘'
BOX_T_L :: '├'
BOX_T_R :: '┤'

grid_box :: proc(g: ^Grid, x, y, w, h: int, fg: Color_Id = .Border, bg: Color_Id = .Bg) {
	if w < 2 || h < 2 {
		return
	}
	for xx in x + 1 ..< x + w - 1 {
		grid_set(g, xx, y, BOX_H, fg, bg)
		grid_set(g, xx, y + h - 1, BOX_H, fg, bg)
	}
	for yy in y + 1 ..< y + h - 1 {
		grid_set(g, x, yy, BOX_V, fg, bg)
		grid_set(g, x + w - 1, yy, BOX_V, fg, bg)
	}
	grid_set(g, x, y, BOX_TL, fg, bg)
	grid_set(g, x + w - 1, y, BOX_TR, fg, bg)
	grid_set(g, x, y + h - 1, BOX_BL, fg, bg)
	grid_set(g, x + w - 1, y + h - 1, BOX_BR, fg, bg)
}

// A titled panel -- the shape every window in the game uses.
grid_panel :: proc(
	g: ^Grid,
	x, y, w, h: int,
	title: string,
	fg: Color_Id = .Border,
	title_fg: Color_Id = .Bright,
	bg: Color_Id = .Bg_Panel,
) {
	grid_fill(g, x, y, w, h, ' ', .Text, bg)
	grid_box(g, x, y, w, h, fg, bg)
	if len(title) > 0 && w > 6 {
		grid_set(g, x + 2, y, ' ', title_fg, bg)
		end := grid_write(g, x + 3, y, title, title_fg, bg, {.Bold})
		if end < x + w - 1 {
			grid_set(g, end, y, ' ', title_fg, bg)
		}
	}
}

// Horizontal meter, e.g. the trace bar. `frac` is clamped to [0,1].
grid_meter :: proc(g: ^Grid, x, y, w: int, frac: f32, fg: Color_Id = .Good, bg: Color_Id = .Bg) {
	f := clamp(frac, 0, 1)
	filled := int(f * f32(w) + 0.5)
	for i in 0 ..< w {
		grid_set(g, x + i, y, '█' if i < filled else '░', fg, bg)
	}
}
