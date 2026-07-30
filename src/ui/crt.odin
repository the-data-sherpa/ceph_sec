package ui

import rl "vendor:raylib"

// Wrapper around the CRT post-process shader.
//
// Uniform locations are resolved once at load; looking them up by name every
// frame is a string compare per uniform per frame for no benefit. If the shader
// fails to compile, `ok` is false and the caller blits the raw texture -- a
// broken shader should cost you the glow, not the game.

Crt_Params :: struct {
	curvature:  f32,
	scanline:   f32,
	aberration: f32,
	vignette:   f32,
	bloom:      f32,
	flicker:    f32,
}

// Tuned to read as a decent late-90s trinitron: visible but not seasick.
CRT_DEFAULT := Crt_Params {
	curvature  = 7.0,
	scanline   = 0.28,
	aberration = 1.6,
	vignette   = 0.35,
	bloom      = 0.34,
	flicker    = 0.012,
}

// Curvature off, everything else softened -- for screenshots and for anyone who
// finds the barrel warp unpleasant.
CRT_FLAT := Crt_Params {
	curvature  = 1000.0,
	scanline   = 0.16,
	aberration = 0.0,
	vignette   = 0.18,
	bloom      = 0.26,
	flicker    = 0.0,
}

Crt :: struct {
	shader: rl.Shader,
	ok:     bool,
	params: Crt_Params,
	time:   f32,

	loc_time:       i32,
	loc_resolution: i32,
	loc_curvature:  i32,
	loc_scanline:   i32,
	loc_aberration: i32,
	loc_vignette:   i32,
	loc_bloom:      i32,
	loc_flicker:    i32,
}

crt_load :: proc(path: cstring, params := CRT_DEFAULT) -> Crt {
	c: Crt
	c.params = params
	c.shader = rl.LoadShader(nil, path) // nil vertex shader = raylib's default

	// raylib hands back a non-zero fallback id on failure, so probe a uniform we
	// know the real shader declares instead of trusting the id alone.
	c.loc_resolution = rl.GetShaderLocation(c.shader, "uResolution")
	c.ok = c.shader.id != 0 && c.loc_resolution >= 0
	if !c.ok {
		return c
	}

	c.loc_time = rl.GetShaderLocation(c.shader, "uTime")
	c.loc_curvature = rl.GetShaderLocation(c.shader, "uCurvature")
	c.loc_scanline = rl.GetShaderLocation(c.shader, "uScanline")
	c.loc_aberration = rl.GetShaderLocation(c.shader, "uAberration")
	c.loc_vignette = rl.GetShaderLocation(c.shader, "uVignette")
	c.loc_bloom = rl.GetShaderLocation(c.shader, "uBloom")
	c.loc_flicker = rl.GetShaderLocation(c.shader, "uFlicker")
	return c
}

crt_unload :: proc(c: ^Crt) {
	if c.ok {
		rl.UnloadShader(c.shader)
	}
	c^ = {}
}

// Time is *pushed in* from the simulation clock rather than accumulated from
// wall-clock delta.
//
// The flicker uniform is a function of this value, so accumulating real time
// here would make the rendered frame depend on how long the process had been
// running -- and two runs of the same seed to the same tick would not produce
// the same image. Driving it from sim time keeps the whole frame reproducible,
// which is what makes `--shot` a regression check rather than a screenshot.
crt_set_time :: proc(c: ^Crt, t: f32) {
	// Wrap well away from f32 precision loss; the shader only uses this inside
	// sines, so a discontinuity at a period boundary is invisible.
	c.time = t - f32(int(t / 3600)) * 3600
}

@(private)
set_f32 :: proc(s: rl.Shader, loc: i32, v: f32) {
	if loc < 0 {
		return
	}
	value := v
	rl.SetShaderValue(s, loc, &value, .FLOAT)
}

crt_apply :: proc(c: ^Crt, virtual_w, virtual_h: f32) {
	if !c.ok {
		return
	}
	res := [2]f32{virtual_w, virtual_h}
	rl.SetShaderValue(c.shader, c.loc_resolution, &res, .VEC2)
	set_f32(c.shader, c.loc_time, c.time)
	set_f32(c.shader, c.loc_curvature, c.params.curvature)
	set_f32(c.shader, c.loc_scanline, c.params.scanline)
	set_f32(c.shader, c.loc_aberration, c.params.aberration)
	set_f32(c.shader, c.loc_vignette, c.params.vignette)
	set_f32(c.shader, c.loc_bloom, c.params.bloom)
	set_f32(c.shader, c.loc_flicker, c.params.flicker)
}
