package ui

import "core:math"
import rl "vendor:raylib"

// Everything raylib touches lives in this package. `main` and `sim` never see
// it, which is what keeps the simulation headless and testable.

FONT_SIZE :: 20 // 2x the built-in font's 10px base, so glyphs stay pixel-exact

App :: struct {
	grid:   Grid,
	theme:  Theme,
	crt:    Crt,
	font:   rl.Font,
	target: rl.RenderTexture2D,

	cell_w, cell_h: int,
	virtual_w:      int,
	virtual_h:      int,

	crt_enabled: bool,
	flat_mode:   bool,
	screenshots: int,
}

app_init :: proc(app: ^App, title: cstring, grid_w, grid_h: int) {
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT})
	rl.SetTraceLogLevel(.WARNING)

	// InitWindow must come first: raylib loads its built-in font as part of
	// window creation, so GetFontDefault() before this point returns a zeroed
	// Font whose glyph array is a null pointer. The size here is provisional --
	// the real one depends on the cell metrics we can only measure afterwards.
	rl.InitWindow(960, 640, title)

	app.font = rl.GetFontDefault()
	app.cell_w, app.cell_h = measure_cell(app.font)

	app.grid = grid_make(grid_w, grid_h)
	app.theme = THEME_GREEN
	app.virtual_w = grid_w * app.cell_w
	app.virtual_h = grid_h * app.cell_h

	rl.SetWindowSize(i32(app.virtual_w), i32(app.virtual_h))
	rl.SetWindowMinSize(i32(app.virtual_w / 2), i32(app.virtual_h / 2))

	app.target = rl.LoadRenderTexture(i32(app.virtual_w), i32(app.virtual_h))
	// Bilinear on the offscreen buffer: the barrel warp resamples at
	// non-integer offsets, and point sampling there produces crawling aliasing
	// along every glyph edge.
	rl.SetTextureFilter(app.target.texture, .BILINEAR)

	app.crt = crt_load()
	app.crt_enabled = app.crt.ok
}

app_shutdown :: proc(app: ^App) {
	crt_unload(&app.crt)
	rl.UnloadRenderTexture(app.target)
	grid_destroy(&app.grid)
	rl.CloseWindow()
}

app_should_close :: proc(app: ^App) -> bool {
	return bool(rl.WindowShouldClose())
}

app_frame_time :: proc(app: ^App) -> f64 {
	return f64(rl.GetFrameTime())
}

// The built-in font is proportional, so the cell width has to be the widest
// printable glyph or wide characters would bleed into their neighbour. Measured
// once at startup rather than assumed, since it is a property of raylib's atlas
// and not something we control.
@(private)
measure_cell :: proc(font: rl.Font) -> (w: int, h: int) {
	scale := f32(FONT_SIZE) / f32(font.baseSize)
	widest: f32 = 0

	for cp in rune(33) ..= rune(126) {
		idx := rl.GetGlyphIndex(font, cp)
		g := font.glyphs[idx]
		adv := f32(g.advanceX)
		if adv == 0 {
			adv = font.recs[idx].width
		}
		widest = max(widest, adv * scale)
	}

	return int(math.ceil(widest)), FONT_SIZE
}

// --- rasterisation ----------------------------------------------------------

// Box-drawing and block characters are stroked as rectangles instead of looked
// up in the font. The built-in font has no coverage for them at all, and even
// with a font that did, drawn strokes land on exact cell boundaries so panel
// borders join seamlessly at any scale.
@(private)
draw_special :: proc(app: ^App, ch: rune, px, py: f32, color: rl.Color) -> bool {
	cw, chh := f32(app.cell_w), f32(app.cell_h)
	// Stroke thickness scales with the cell so the look holds if FONT_SIZE moves.
	t := max(f32(1), math.round(chh / 12))
	mx := px + math.round((cw - t) * 0.5) // vertical stroke, centred
	my := py + math.round((chh - t) * 0.5) // horizontal stroke, centred

	left := rl.Rectangle{px, my, math.round(cw*0.5) + t, t}
	right := rl.Rectangle{mx, my, cw - (mx - px), t}
	up := rl.Rectangle{mx, py, t, math.round(chh*0.5) + t}
	down := rl.Rectangle{mx, my, t, chh - (my - py)}

	switch ch {
	case BOX_H:
		rl.DrawRectangleRec({px, my, cw, t}, color)
	case BOX_V:
		rl.DrawRectangleRec({mx, py, t, chh}, color)
	case BOX_TL:
		rl.DrawRectangleRec(right, color);  rl.DrawRectangleRec(down, color)
	case BOX_TR:
		rl.DrawRectangleRec(left, color);   rl.DrawRectangleRec(down, color)
	case BOX_BL:
		rl.DrawRectangleRec(right, color);  rl.DrawRectangleRec(up, color)
	case BOX_BR:
		rl.DrawRectangleRec(left, color);   rl.DrawRectangleRec(up, color)
	case BOX_T_L:
		rl.DrawRectangleRec({mx, py, t, chh}, color); rl.DrawRectangleRec(right, color)
	case BOX_T_R:
		rl.DrawRectangleRec({mx, py, t, chh}, color); rl.DrawRectangleRec(left, color)
	case '█':
		rl.DrawRectangleRec({px, py, cw, chh}, color)
	case '●', '○':
		// Status bullets, drawn rather than typed. The built-in font covers
		// ASCII only, so anything outside it silently becomes '?' -- see the
		// note in draw_grid.
		cx, cy := px + cw * 0.5, py + chh * 0.5
		r := min(cw, chh) * 0.28
		if ch == '●' {
			rl.DrawCircleV({cx, cy}, r, color)
		} else {
			rl.DrawRing({cx, cy}, r * 0.62, r, 0, 360, 16, color)
		}
	case '▓', '▒', '░':
		// Shade blocks as scaled-alpha fills. On a phosphor display the eye
		// reads these as intensity steps, which is all a meter needs.
		alpha: u8 = 160 if ch == '▓' else (100 if ch == '▒' else 55)
		c := color
		c.a = alpha
		rl.DrawRectangleRec({px, py, cw, chh}, c)
	case:
		return false
	}
	return true
}

@(private)
draw_grid :: proc(app: ^App) {
	g := &app.grid
	bg_default := app.theme.colors[.Bg]

	for y in 0 ..< g.h {
		for x in 0 ..< g.w {
			cell := g.cells[y * g.w + x]

			fg_id, bg_id := cell.fg, cell.bg
			if .Reverse in cell.attr {
				fg_id, bg_id = bg_id, fg_id
			}
			fg := app.theme.colors[fg_id]
			bg := app.theme.colors[bg_id]

			px := f32(x * app.cell_w)
			py := f32(y * app.cell_h)

			if bg != bg_default {
				rl.DrawRectangleRec({px, py, f32(app.cell_w), f32(app.cell_h)}, bg)
			}

			if cell.ch == 0 || cell.ch == ' ' {
				continue
			}
			if draw_special(app, cell.ch, px, py, fg) {
				continue
			}

			// Centre proportional glyphs within their fixed cell so text reads
			// as monospaced despite the font not being.
			//
			// NOTE: the built-in font covers ASCII only. Any other rune that
			// draw_special does not handle silently renders as '?'. Keep UI
			// text ASCII, or add the character to draw_special, until the
			// milestone that ships a real font.
			idx := rl.GetGlyphIndex(app.font, cell.ch)
			scale := f32(FONT_SIZE) / f32(app.font.baseSize)
			adv := f32(app.font.glyphs[idx].advanceX)
			if adv == 0 {
				adv = app.font.recs[idx].width
			}
			ox := math.round((f32(app.cell_w) - adv * scale) * 0.5)

			rl.DrawTextCodepoint(app.font, cell.ch, {px + ox, py}, f32(FONT_SIZE), fg)
			if .Bold in cell.attr {
				// Re-stamp one pixel over for a heavier stroke; a real terminal
				// bold, not a colour change.
				rl.DrawTextCodepoint(app.font, cell.ch, {px + ox + 1, py}, f32(FONT_SIZE), fg)
			}
			if .Underline in cell.attr {
				rl.DrawRectangleRec({px, py + f32(app.cell_h) - 2, f32(app.cell_w), 1}, fg)
			}
		}
	}
}

// --- frame ------------------------------------------------------------------

app_render :: proc(app: ^App, sim_time: f32) {
	crt_set_time(&app.crt, sim_time)

	rl.BeginTextureMode(app.target)
	rl.ClearBackground(app.theme.colors[.Bg])
	draw_grid(app)
	rl.EndTextureMode()

	vw, vh := f32(app.virtual_w), f32(app.virtual_h)
	sw, sh := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	// Letterbox rather than stretch: the grid has a fixed aspect and stretched
	// glyphs look wrong immediately.
	scale := min(sw / vw, sh / vh)
	dest := rl.Rectangle {
		x      = math.round((sw - vw * scale) * 0.5),
		y      = math.round((sh - vh * scale) * 0.5),
		width  = vw * scale,
		height = vh * scale,
	}
	// Negative source height flips the render texture, which OpenGL stores
	// bottom-up.
	src := rl.Rectangle{0, 0, vw, -vh}

	rl.BeginDrawing()
	rl.ClearBackground(rl.BLACK)

	if app.crt_enabled && app.crt.ok {
		crt_apply(&app.crt, vw, vh)
		rl.BeginShaderMode(app.crt.shader)
		rl.DrawTexturePro(app.target.texture, src, dest, {0, 0}, 0, rl.WHITE)
		rl.EndShaderMode()
	} else {
		rl.DrawTexturePro(app.target.texture, src, dest, {0, 0}, 0, rl.WHITE)
	}

	rl.EndDrawing()
}

app_capture :: proc(app: ^App, path: cstring) {
	app.screenshots += 1
	rl.TakeScreenshot(path)
}

// --- platform diagnostics ---------------------------------------------------

// What app_render's letterbox arithmetic is actually working from, reported
// rather than acted on.
//
// The open question this exists to answer: raylib's GetRenderWidth has an
// Apple-only branch that multiplies the screen size by GetWindowScaleDPI(),
// while GetScreenWidth never does. app_render uses GetScreenWidth. On a Retina
// display that is either correct or off by the backing scale, and which one
// depends on whether the window was created DPI-aware -- app_init sets only
// {.WINDOW_RESIZABLE, .VSYNC_HINT}, with FLAG_WINDOW_HIGHDPI deliberately
// absent, so the framebuffer should be in the same units GetScreenWidth
// reports and the two should agree.
//
// "Should" is the problem. Nobody working on this has a Mac, so switching to
// the DPI-aware getter to "fix" HiDPI would pair a scaled measurement with an
// unscaled surface and could manufacture exactly the letterboxing bug it claims
// to prevent -- on the one platform that cannot be tested here. So the numbers
// get printed on the --shot line instead, and the first person to run
// `cephsec --shot 2` on a Retina Mac settles it with data. If render_w equals
// screen_w there, GetScreenWidth is right and nothing needs to change.
Metrics :: struct {
	cell_w, cell_h:       int,
	virtual_w, virtual_h: int,
	// GetRenderWidth/Height: the framebuffer, DPI-scaled on Apple platforms.
	render_w, render_h:   int,
	// GetScreenWidth/Height: the window, never DPI-scaled. What app_render uses.
	screen_w, screen_h:   int,
	dpi_x, dpi_y:         f32,
}

app_metrics :: proc(app: ^App) -> Metrics {
	dpi := rl.GetWindowScaleDPI()
	return Metrics {
		cell_w    = app.cell_w,
		cell_h    = app.cell_h,
		virtual_w = app.virtual_w,
		virtual_h = app.virtual_h,
		render_w  = int(rl.GetRenderWidth()),
		render_h  = int(rl.GetRenderHeight()),
		screen_w  = int(rl.GetScreenWidth()),
		screen_h  = int(rl.GetScreenHeight()),
		dpi_x     = dpi.x,
		dpi_y     = dpi.y,
	}
}

// F1 CRT on/off · F2 flat/curved · F3 cycle theme · F12 screenshot.
// Present from the first milestone so the render pipeline stays inspectable as
// it grows.
app_debug_keys :: proc(app: ^App) {
	if rl.IsKeyPressed(.F1) {
		app.crt_enabled = !app.crt_enabled
	}
	if rl.IsKeyPressed(.F2) {
		app.flat_mode = !app.flat_mode
		app.crt.params = CRT_FLAT if app.flat_mode else CRT_DEFAULT
	}
	if rl.IsKeyPressed(.F3) {
		app.theme = THEME_AMBER if app.theme.name == THEME_GREEN.name else THEME_GREEN
	}
	if rl.IsKeyPressed(.F12) {
		app_capture(app, "cephsec.png")
	}
}
