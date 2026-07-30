// Package save is the only part of the game permitted to touch the filesystem.
//
// It sits outside the purity gate deliberately and is named in GATE_EXEMPT,
// which makes granting that permission a visible, reviewable line in build.sh
// rather than something that happened by omission. Nothing here knows what a
// level is; it reads and writes a list of strings. `campaign` -- which is inside
// the gate -- never learns that a filesystem exists.
package save

import "core:os"
import "core:strings"

// The format is a tiny line-based text file rather than anything structured.
//
// It has one field that matters: the list of completed level ids. Everything
// else the game knows -- which tools you have, which techniques you have
// covered, which levels are unlocked -- is derived from that list at runtime.
// Storing the derived values would mean a save written before a level's
// `grants` changed would hand out the wrong tools forever.
//
// Text, because a player finding this file should be able to read it, and
// because a format I can debug by eye is worth more here than one that packs.

FORMAT_VERSION :: 1

MAGIC :: "cephsec-progress"

// What a save holds. Deliberately not campaign.Progress: this package must not
// import campaign, so that campaign cannot import this.
Save :: struct {
	version:   int,
	completed: [dynamic]string,
}

Load_Result :: enum {
	Ok,
	Missing,      // no save yet -- a new player, not an error
	Unreadable,   // permissions, a directory where a file should be
	Malformed,    // not our format, or truncated
	Newer_Version, // written by a later build; refuse rather than misread
}

// Takes the allocator the save was loaded with. Not defaulted to
// context.allocator by accident: `load` clones every id with the caller's
// allocator, and freeing those with a different one is a bad free -- which is
// exactly what happened on the malformed-file path, where a temp-allocated
// save was being torn down against the heap.
save_destroy :: proc(s: ^Save, allocator := context.allocator) {
	for c in s.completed {
		delete(c, allocator)
	}
	delete(s.completed)
	s^ = {}
}

// --- where it lives ---------------------------------------------------------

// Follows each platform's convention rather than dropping a dotfile in $HOME:
//
//   Linux    $XDG_DATA_HOME/cephsec  or ~/.local/share/cephsec
//   macOS    ~/Library/Application Support/cephsec
//   Windows  %APPDATA%\cephsec
//
// Returns ok=false when there is no home directory to anchor to -- which happens
// in containers and on CI runners. The caller treats that as "play without
// saving" rather than as a failure, because a game that refuses to start
// because it cannot find a home directory is worse than one that forgets.
state_dir :: proc(allocator := context.allocator) -> (dir: string, ok: bool) {
	when ODIN_OS == .Windows {
		if appdata := os.get_env("APPDATA", context.temp_allocator); appdata != "" {
			return strings.concatenate({appdata, "\\cephsec"}, allocator), true
		}
		return "", false
	} else when ODIN_OS == .Darwin {
		if home := os.get_env("HOME", context.temp_allocator); home != "" {
			return strings.concatenate({home, "/Library/Application Support/cephsec"}, allocator), true
		}
		return "", false
	} else {
		if xdg := os.get_env("XDG_DATA_HOME", context.temp_allocator); xdg != "" {
			return strings.concatenate({xdg, "/cephsec"}, allocator), true
		}
		if home := os.get_env("HOME", context.temp_allocator); home != "" {
			return strings.concatenate({home, "/.local/share/cephsec"}, allocator), true
		}
		return "", false
	}
}

save_path :: proc(allocator := context.allocator) -> (path: string, ok: bool) {
	dir := state_dir(context.temp_allocator) or_return
	when ODIN_OS == .Windows {
		return strings.concatenate({dir, "\\progress.txt"}, allocator), true
	} else {
		return strings.concatenate({dir, "/progress.txt"}, allocator), true
	}
}

// --- reading ----------------------------------------------------------------

// A save is never trusted. It is a text file in a directory the player can
// reach, so it will eventually be edited by hand, truncated by a full disk, or
// written by a different build. Every one of those returns a result the caller
// can act on rather than a corrupted campaign.
load :: proc(path: string, allocator := context.allocator) -> (s: Save, result: Load_Result) {
	if !os.exists(path) {
		return {}, .Missing
	}

	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		return {}, .Unreadable
	}

	text := string(data)
	s.completed = make([dynamic]string, 0, 16, allocator)

	saw_magic := false
	for line in strings.split_lines_iterator(&text) {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 || trimmed[0] == '#' {
			continue
		}

		key, _, value := strings.partition(trimmed, " ")
		switch key {
		case MAGIC:
			saw_magic = true
			v, parsed := parse_int(strings.trim_space(value))
			if !parsed {
				save_destroy(&s, allocator)
				return {}, .Malformed
			}
			s.version = v
			// A save from a later build may mean anything. Refusing to read it
			// keeps a player who downgrades from silently losing progress to a
			// misparse -- they get "unreadable", and their file is left alone.
			if v > FORMAT_VERSION {
				save_destroy(&s, allocator)
				return {}, .Newer_Version
			}
		case "done":
			id := strings.trim_space(value)
			if len(id) > 0 {
				append(&s.completed, strings.clone(id, allocator))
			}
		}
	}

	if !saw_magic {
		save_destroy(&s, allocator)
		return {}, .Malformed
	}
	return s, .Ok
}

@(private)
parse_int :: proc(s: string) -> (int, bool) {
	if len(s) == 0 {
		return 0, false
	}
	v := 0
	for i in 0 ..< len(s) {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
		v = v * 10 + int(s[i] - '0')
	}
	return v, true
}

// --- writing ----------------------------------------------------------------

// Written to a temporary file and renamed over the target.
//
// A save is rewritten every time a level is completed, and a process killed
// mid-write would otherwise leave a truncated file -- losing an entire campaign
// to a power cut at the wrong instant. rename is atomic on every platform this
// runs on, so the file is either the old one or the new one and never a torn
// mixture.
write :: proc(path: string, completed: []string) -> bool {
	if dir := parent_dir(path); len(dir) > 0 {
		if !make_dirs(dir) {
			return false
		}
	}

	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "# Ceph.Sec progress. Safe to delete; you will start from level one.\n")
	strings.write_string(&sb, MAGIC)
	strings.write_string(&sb, " 1\n")
	for id in completed {
		strings.write_string(&sb, "done ")
		strings.write_string(&sb, id)
		strings.write_byte(&sb, '\n')
	}

	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if err := os.write_entire_file(tmp, transmute([]byte)strings.to_string(sb)); err != nil {
		return false
	}
	if err := os.rename(tmp, path); err != nil {
		os.remove(tmp)
		return false
	}
	return true
}

// Creates a directory and every missing parent.
//
// os.make_directory creates one level only, so a missing grandparent made the
// whole save fail -- silently, because nothing checked. On Linux
// ~/.local/share usually exists, which is precisely why this would not have
// been noticed until someone ran it on a fresh account or in a container.
@(private)
make_dirs :: proc(dir: string) -> bool {
	if os.exists(dir) {
		return true
	}
	// Walk forward creating each component; an intermediate that already
	// exists is not an error.
	for i in 1 ..< len(dir) {
		if dir[i] != '/' && dir[i] != '\\' {
			continue
		}
		part := dir[:i]
		if !os.exists(part) {
			_ = os.make_directory(part)
		}
	}
	_ = os.make_directory(dir)
	return os.exists(dir)
}

@(private)
parent_dir :: proc(path: string) -> string {
	cut := -1
	for i in 0 ..< len(path) {
		if path[i] == '/' || path[i] == '\\' {
			cut = i
		}
	}
	if cut <= 0 {
		return ""
	}
	return path[:cut]
}
