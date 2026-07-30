package ui

import rl "vendor:raylib"

// Cells store a palette index rather than an RGBA value. Retheming the entire
// machine -- green phosphor, amber, the washed-out look of a compromised box --
// is then a single table swap, and no drawing code has a colour baked into it.
Color_Id :: enum u8 {
	Bg,
	Bg_Panel,
	Dim,
	Text,
	Bright,
	Accent,
	Good,
	Warn,
	Bad,
	Border,
	Cursor,
	Trace,
}

Theme :: struct {
	name:   string,
	colors: [Color_Id]rl.Color,
}

// P1 green phosphor. Backgrounds are not pure black -- a real CRT's glass
// glows faintly even where nothing is drawn, and the bloom pass in crt.fs needs
// something to lift.
THEME_GREEN := Theme {
	name = "phosphor-green",
	colors = {
		.Bg       = {6, 12, 8, 255},
		.Bg_Panel = {10, 20, 14, 255},
		.Dim      = {42, 92, 56, 255},
		.Text     = {110, 220, 130, 255},
		.Bright   = {190, 255, 200, 255},
		.Accent   = {90, 220, 255, 255},
		.Good     = {120, 255, 150, 255},
		.Warn     = {255, 200, 90, 255},
		.Bad      = {255, 90, 90, 255},
		.Border   = {50, 110, 70, 255},
		.Cursor   = {190, 255, 200, 255},
		.Trace    = {255, 120, 60, 255},
	},
}

THEME_AMBER := Theme {
	name = "phosphor-amber",
	colors = {
		.Bg       = {14, 9, 4, 255},
		.Bg_Panel = {24, 16, 8, 255},
		.Dim      = {110, 68, 20, 255},
		.Text     = {235, 165, 55, 255},
		.Bright   = {255, 220, 150, 255},
		.Accent   = {120, 200, 255, 255},
		.Good     = {180, 235, 90, 255},
		.Warn     = {255, 205, 90, 255},
		.Bad      = {255, 95, 70, 255},
		.Border   = {130, 82, 26, 255},
		.Cursor   = {255, 220, 150, 255},
		.Trace    = {255, 110, 50, 255},
	},
}

theme_color :: proc(t: ^Theme, id: Color_Id) -> rl.Color {
	return t.colors[id]
}
