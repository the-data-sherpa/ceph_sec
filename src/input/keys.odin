// Package input is the shared vocabulary for "what did the user do".
//
// It has no dependencies at all, by design. `ui` cannot own these types because
// `shell` must not import raylib, and `shell` should not own them because `ui`
// is meant to stay a general text-mode toolkit that knows nothing about the
// game. Two packages needing to agree on a type that neither should own is
// exactly what a leaf package is for.
package input

// Named keys. Only what a line editor and a scrollback actually need -- this is
// not trying to be a complete keyboard map, and shouldn't grow into one.
Key :: enum u8 {
	None,
	Enter,
	Backspace,
	Delete,
	Left,
	Right,
	Up,
	Down,
	Home,
	End,
	Tab,
	Page_Up,
	Page_Down,
	Escape,

	// Control combinations, as their own keys rather than a modifier bitfield.
	// Terminals have treated these as atomic since long before modifiers were a
	// concept, and every one of them means something specific here.
	Ctrl_A, // start of line
	Ctrl_C, // interrupt the running command
	Ctrl_E, // end of line
	Ctrl_K, // kill to end of line
	Ctrl_L, // clear screen
	Ctrl_U, // kill to start of line
	Ctrl_W, // kill previous word
}

// A typed character or a named key -- never both. Text input and editing
// commands arrive through the same ordered stream so their relative order is
// preserved; typing "ab", pressing Left, then typing "c" must yield "acb".
Event :: union {
	Rune_Typed,
	Key_Pressed,
	Scroll,
}

Rune_Typed :: struct {
	ch: rune,
}

Key_Pressed :: struct {
	key: Key,
}

// Positive scrolls toward older content.
Scroll :: struct {
	lines: int,
}
