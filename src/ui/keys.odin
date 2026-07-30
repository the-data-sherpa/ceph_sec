package ui

import "../input"
import rl "vendor:raylib"

// Translates raylib's keyboard state into the shared input vocabulary.
//
// This is the only place raylib key codes exist. Everything downstream --
// the line editor, the session, the tests -- sees `input.Event`, which is why
// the shell can be driven headlessly with no window at all.

// Held keys repeat; typed characters already repeat via raylib's own queue.
REPEAT_DELAY :: 0.42
REPEAT_RATE :: 0.035

Input_State :: struct {
	events: [dynamic]input.Event,

	// Which key is currently auto-repeating, and when it next fires. Only one
	// key repeats at a time, which is what terminals do and avoids tracking a
	// timer per key.
	repeat_key:  rl.KeyboardKey,
	repeat_at:   f64,
	elapsed:     f64,
}

input_init :: proc(st: ^Input_State, allocator := context.allocator) {
	st.events = make([dynamic]input.Event, 0, 32, allocator)
}

input_destroy :: proc(st: ^Input_State) {
	delete(st.events)
	st^ = {}
}

// Keys that auto-repeat when held. Deliberately excludes Enter: holding it
// should not submit a command a hundred times.
@(private)
REPEATABLE := [?]rl.KeyboardKey {
	.BACKSPACE,
	.DELETE,
	.LEFT,
	.RIGHT,
	.UP,
	.DOWN,
}

// Maps a raylib key to the shared vocabulary, honouring Ctrl. Returns .None for
// keys the game does not use.
@(private)
translate :: proc(key: rl.KeyboardKey, ctrl: bool) -> input.Key {
	if ctrl {
		#partial switch key {
		case .A:
			return .Ctrl_A
		case .C:
			return .Ctrl_C
		case .E:
			return .Ctrl_E
		case .K:
			return .Ctrl_K
		case .L:
			return .Ctrl_L
		case .U:
			return .Ctrl_U
		case .W:
			return .Ctrl_W
		}
		// Any other Ctrl combination is swallowed rather than falling through
		// to its unmodified meaning -- Ctrl+X must not behave like X.
		return .None
	}

	#partial switch key {
	case .ENTER, .KP_ENTER:
		return .Enter
	case .BACKSPACE:
		return .Backspace
	case .DELETE:
		return .Delete
	case .LEFT:
		return .Left
	case .RIGHT:
		return .Right
	case .UP:
		return .Up
	case .DOWN:
		return .Down
	case .HOME:
		return .Home
	case .END:
		return .End
	case .TAB:
		return .Tab
	case .PAGE_UP:
		return .Page_Up
	case .PAGE_DOWN:
		return .Page_Down
	case .ESCAPE:
		return .Escape
	}
	return .None
}

// Collects this frame's input in the order it happened.
//
// Characters and keys are interleaved by draining raylib's character queue
// first, then polling named keys: within one frame that ordering is what makes
// typing feel correct, since a Backspace and the character before it cannot
// arrive out of order at 60 fps.
poll_input :: proc(st: ^Input_State, dt: f64) -> []input.Event {
	clear(&st.events)
	st.elapsed += dt

	ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)

	// Printable characters. raylib decodes these to Unicode for us, and
	// suppresses them while Ctrl is held.
	if !ctrl {
		for {
			ch := rl.GetCharPressed()
			if ch == 0 {
				break
			}
			append(&st.events, input.Rune_Typed{ch = ch})
		}
	}

	// Named keys, fresh presses.
	for {
		key := rl.GetKeyPressed()
		if key == .KEY_NULL {
			break
		}
		if translated := translate(key, ctrl); translated != .None {
			append(&st.events, input.Key_Pressed{key = translated})
		}
		if is_repeatable(key) {
			st.repeat_key = key
			st.repeat_at = st.elapsed + REPEAT_DELAY
		}
	}

	// Auto-repeat for a held key.
	if st.repeat_key != .KEY_NULL {
		if !rl.IsKeyDown(st.repeat_key) {
			st.repeat_key = .KEY_NULL
		} else {
			for st.elapsed >= st.repeat_at {
				if translated := translate(st.repeat_key, ctrl); translated != .None {
					append(&st.events, input.Key_Pressed{key = translated})
				}
				st.repeat_at += REPEAT_RATE
			}
		}
	}

	if wheel := rl.GetMouseWheelMove(); wheel != 0 {
		// Wheel up (positive) scrolls toward older output.
		append(&st.events, input.Scroll{lines = int(wheel * 3)})
	}

	return st.events[:]
}

@(private)
is_repeatable :: proc(key: rl.KeyboardKey) -> bool {
	for k in REPEATABLE {
		if k == key {
			return true
		}
	}
	return false
}
