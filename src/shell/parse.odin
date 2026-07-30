package shell

import "core:strings"

// argv -> a structured command.
//
// Flag syntax follows the tools being imitated, which are not internally
// consistent -- `nmap -sV`, `ssh -p 22`, `--script=default`. So: short flags
// are `-name` with an optional following value, long flags are `--name` or
// `--name=value`. Short flags are *not* bundled (`-sV` is one flag named "sV",
// not `-s -V`), because that is exactly how nmap reads it.
//
// Whether a short flag consumes the next token cannot be guessed from syntax:
// `-p 22` takes a value, `-sV` does not. The command's own spec declares which
// of its flags take values, so parsing is spec-driven rather than heuristic.

Command :: struct {
	name:        string,
	positionals: []string,
	flags:       []Flag,
	raw:         string, // the original line, for history and echo
}

Flag :: struct {
	name:  string, // without leading dashes
	value: string, // "" when the flag is a bare switch
	long:  bool,
}

Parse_Error :: enum {
	None,
	Empty,
	Missing_Flag_Value,
}

// `value_flags` lists the short flag names that consume the following token.
// Long flags carry their value inline with `=`, so they never need this.
parse :: proc(
	tokens: []string,
	value_flags: []string = nil,
	allocator := context.allocator,
) -> (
	cmd: Command,
	err: Parse_Error,
) {
	if len(tokens) == 0 {
		return {}, .Empty
	}

	positionals := make([dynamic]string, 0, 4, allocator)
	flags := make([dynamic]Flag, 0, 4, allocator)

	cmd.name = tokens[0]

	i := 1
	for i < len(tokens) {
		tok := tokens[i]

		switch {
		case len(tok) > 2 && tok[:2] == "--":
			body := tok[2:]
			if eq := strings.index_byte(body, '='); eq >= 0 {
				append(&flags, Flag{name = body[:eq], value = body[eq + 1:], long = true})
			} else {
				append(&flags, Flag{name = body, long = true})
			}

		// A lone "-" is a positional (it means stdin to real tools), and "--"
		// is not treated specially since nothing here needs an end-of-flags
		// marker.
		case len(tok) > 1 && tok[0] == '-' && tok != "--":
			name := tok[1:]
			if takes_value(name, value_flags) {
				if i + 1 >= len(tokens) {
					return {}, .Missing_Flag_Value
				}
				i += 1
				append(&flags, Flag{name = name, value = tokens[i]})
			} else {
				append(&flags, Flag{name = name})
			}

		case:
			append(&positionals, tok)
		}

		i += 1
	}

	cmd.positionals = positionals[:]
	cmd.flags = flags[:]
	return cmd, .None
}

@(private)
takes_value :: proc(name: string, value_flags: []string) -> bool {
	for f in value_flags {
		if f == name {
			return true
		}
	}
	return false
}

// --- accessors --------------------------------------------------------------

has_flag :: proc(cmd: ^Command, names: ..string) -> bool {
	for f in cmd.flags {
		for n in names {
			if f.name == n {
				return true
			}
		}
	}
	return false
}

flag_value :: proc(cmd: ^Command, names: ..string) -> (string, bool) {
	for f in cmd.flags {
		for n in names {
			if f.name == n {
				return f.value, true
			}
		}
	}
	return "", false
}

positional :: proc(cmd: ^Command, index: int) -> (string, bool) {
	if index < 0 || index >= len(cmd.positionals) {
		return "", false
	}
	return cmd.positionals[index], true
}
