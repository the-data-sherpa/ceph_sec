package tests

import "core:os"
import "core:strings"
import "core:testing"
import "../src/save"

// Progress persistence.
//
// A save is a text file in a directory the player can reach, so it will be
// hand-edited, truncated by a full disk, and written by builds newer than the
// one reading it. Every one of those has to fail in a way that keeps the file
// intact rather than losing a campaign, so the failure paths get more attention
// here than the happy one.

@(private)
temp_save :: proc(name: string) -> string {
	dir := os.get_env("TMPDIR", context.temp_allocator)
	if dir == "" {
		dir = "/tmp"
	}
	return strings.concatenate({dir, "/cephsec-test-", name, ".txt"}, context.temp_allocator)
}

@(private)
put :: proc(path, contents: string) {
	_ = os.write_entire_file(path, transmute([]byte)contents)
}

@(test)
test_save_round_trips :: proc(t: ^testing.T) {
	path := temp_save("roundtrip")
	os.remove(path)
	defer os.remove(path)

	ids := []string{"recon-sweep", "recon-versions", "access-exposure"}
	testing.expect(t, save.write(path, ids), "write should succeed")

	loaded, result := save.load(path, context.temp_allocator)
	testing.expect_value(t, result, save.Load_Result.Ok)
	testing.expect_value(t, loaded.version, save.FORMAT_VERSION)
	testing.expect_value(t, len(loaded.completed), 3)
	// Order is preserved: it is the order the player finished them in.
	testing.expect_value(t, loaded.completed[0], "recon-sweep")
	testing.expect_value(t, loaded.completed[2], "access-exposure")
}

// A new player is not an error, and must not produce a warning.
@(test)
test_missing_save_is_not_an_error :: proc(t: ^testing.T) {
	path := temp_save("absent")
	os.remove(path)

	_, result := save.load(path, context.temp_allocator)
	testing.expect_value(t, result, save.Load_Result.Missing)
}

// Anything that is not ours is refused rather than half-parsed. The caller
// leaves the file alone on this result, so a player who pointed the game at the
// wrong file does not lose it.
@(test)
test_foreign_and_truncated_files_are_refused :: proc(t: ^testing.T) {
	Case :: struct {
		name, contents: string,
	}
	cases := []Case {
		{"empty", ""},
		{"not-ours", "hello\nthis is someone else's file\n"},
		{"comments-only", "# just a comment\n"},
		{"truncated-magic", "cephsec-progres 1\ndone recon-sweep\n"},
		{"no-version", "cephsec-progress\ndone recon-sweep\n"},
		{"version-not-a-number", "cephsec-progress one\n"},
	}

	for c in cases {
		path := temp_save(c.name)
		put(path, c.contents)
		defer os.remove(path)

		_, result := save.load(path, context.temp_allocator)
		testing.expectf(
			t,
			result == .Malformed,
			"%q should be Malformed, got %v",
			c.name,
			result,
		)
	}
}

// A save from a later build could mean anything. Refusing beats misreading:
// a player who downgrades keeps their file and can upgrade back.
@(test)
test_a_newer_save_is_refused_not_misread :: proc(t: ^testing.T) {
	path := temp_save("newer")
	put(path, "cephsec-progress 99\ndone recon-sweep\ndone something-from-the-future\n")
	defer os.remove(path)

	_, result := save.load(path, context.temp_allocator)
	testing.expect_value(t, result, save.Load_Result.Newer_Version)

	// And the file is untouched -- the caller does not overwrite on this path.
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect(t, strings.contains(string(data), "something-from-the-future"))
}

// Hand-editing is expected, so the parser tolerates what a human would produce:
// blank lines, comments, stray whitespace, lines it does not recognise.
@(test)
test_hand_edited_saves_still_load :: proc(t: ^testing.T) {
	path := temp_save("handedited")
	put(
		path,
		"# my progress\n\ncephsec-progress 1\n\n  done   recon-sweep  \n" +
		"nonsense line the parser should skip\ndone recon-versions\n\n",
	)
	defer os.remove(path)

	loaded, result := save.load(path, context.temp_allocator)
	testing.expect_value(t, result, save.Load_Result.Ok)
	testing.expect_value(t, len(loaded.completed), 2)
	testing.expect_value(t, loaded.completed[0], "recon-sweep")
	testing.expect_value(t, loaded.completed[1], "recon-versions")
}

// The write is atomic, so a save is either the old one or the new one. Writing
// repeatedly must never leave the file in a state that fails to load, and must
// never leave the temporary behind.
@(test)
test_writes_replace_cleanly :: proc(t: ^testing.T) {
	path := temp_save("atomic")
	os.remove(path)
	defer os.remove(path)

	for n in 1 ..= 5 {
		ids := make([dynamic]string, 0, n, context.temp_allocator)
		for i in 0 ..< n {
			append(&ids, "recon-sweep")
		}
		testing.expect(t, save.write(path, ids[:]))

		loaded, result := save.load(path, context.temp_allocator)
		testing.expectf(t, result == .Ok, "load failed after write %d: %v", n, result)
		testing.expect_value(t, len(loaded.completed), n)
	}

	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	testing.expect(t, !os.exists(tmp), "the temporary file should not survive a successful write")
}

@(test)
test_an_empty_campaign_round_trips :: proc(t: ^testing.T) {
	path := temp_save("empty-campaign")
	os.remove(path)
	defer os.remove(path)

	testing.expect(t, save.write(path, {}))
	loaded, result := save.load(path, context.temp_allocator)
	testing.expect_value(t, result, save.Load_Result.Ok)
	testing.expect_value(t, len(loaded.completed), 0)
}

// The save must be somewhere the platform expects, not a dotfile dropped in the
// home directory. The exact location differs per OS; what is asserted here is
// that one is produced and that it names the game.
@(test)
test_save_path_is_platform_appropriate :: proc(t: ^testing.T) {
	path, ok := save.save_path(context.temp_allocator)
	if !ok {
		// No home directory -- valid, and the caller plays without saving.
		return
	}
	testing.expect(t, strings.contains(path, "cephsec"), "the path should name the game")
	testing.expect(t, strings.has_suffix(path, "progress.txt"))
	when ODIN_OS == .Linux {
		testing.expect(
			t,
			strings.contains(path, ".local/share") || strings.contains(path, "XDG") || len(os.get_env("XDG_DATA_HOME", context.temp_allocator)) > 0,
			"Linux saves belong under XDG_DATA_HOME or ~/.local/share",
		)
	}
}
