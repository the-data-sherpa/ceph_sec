package shell

import "core:strings"
import "../sim"

// A filesystem view over flat path strings.
//
// `Host.files` is a list of absolute paths; there are no directory nodes.
// Directories are *inferred* from the paths that exist, which is enough for
// `cd`/`ls`/`cat` to behave correctly and costs nothing to generate -- procgen
// emits paths, not trees.
//
// The tradeoff taken knowingly: an empty directory cannot exist, and there is
// nowhere to hang per-directory ownership or permissions. Both matter for the
// `Permission denied` mechanic, and both are reasons this becomes a real tree
// later if that mechanic earns its place.

// Resolves `path` against `cwd` and normalises it: collapses `//`, resolves `.`
// and `..`, strips any trailing slash. `..` at the root stays at the root,
// matching every real shell.
resolve_path :: proc(cwd, path: string, allocator := context.allocator) -> string {
	combined := path
	if len(path) == 0 {
		combined = cwd
	} else if path[0] != '/' {
		combined = strings.concatenate({cwd, "/", path}, context.temp_allocator)
	}

	parts := make([dynamic]string, 0, 8, context.temp_allocator)
	start := 0
	for i in 0 ..= len(combined) {
		if i == len(combined) || combined[i] == '/' {
			seg := combined[start:i]
			switch seg {
			case "", ".":
				// collapse
			case "..":
				if len(parts) > 0 {
					pop(&parts)
				}
			case:
				append(&parts, seg)
			}
			start = i + 1
		}
	}

	if len(parts) == 0 {
		return strings.clone("/", allocator)
	}

	sb := strings.builder_make(allocator)
	for p in parts {
		strings.write_byte(&sb, '/')
		strings.write_string(&sb, p)
	}
	return strings.to_string(sb)
}

Entry :: struct {
	name:  string,
	is_dir: bool,
	size:  int,
}

// Direct children of `dir` only.
//
// A file at `/etc/nginx/nginx.conf` contributes the entry `nginx/` when listing
// `/etc`, and `nginx.conf` when listing `/etc/nginx`. Directory entries are
// deduplicated, since many files can imply the same directory.
list_dir :: proc(
	h: ^sim.Host,
	dir: string,
	allocator := context.allocator,
) -> []Entry {
	out := make([dynamic]Entry, 0, 8, allocator)

	// Root is "/", everything else needs the separator appended so that
	// "/etc" does not also match "/etcetera/x".
	prefix := dir == "/" ? "/" : strings.concatenate({dir, "/"}, context.temp_allocator)

	for f in h.files {
		if len(f.path) <= len(prefix) || f.path[:len(prefix)] != prefix {
			continue
		}
		rest := f.path[len(prefix):]

		if slash := strings.index_byte(rest, '/'); slash >= 0 {
			name := rest[:slash]
			already := false
			for e in out {
				if e.is_dir && e.name == name {
					already = true
					break
				}
			}
			if !already {
				append(&out, Entry{name = name, is_dir = true})
			}
		} else {
			append(&out, Entry{name = rest, size = f.size})
		}
	}

	// Directories first, then alphabetical -- a stable order matters because
	// output is compared in tests and read by a human.
	for i in 1 ..< len(out) {
		e := out[i]
		j := i - 1
		for j >= 0 && entry_after(out[j], e) {
			out[j + 1] = out[j]
			j -= 1
		}
		out[j + 1] = e
	}

	return out[:]
}

@(private)
entry_after :: proc(a, b: Entry) -> bool {
	if a.is_dir != b.is_dir {
		return !a.is_dir // dirs sort first
	}
	return a.name > b.name
}

// True if any file lives under `dir`, which is what makes the directory exist.
dir_exists :: proc(h: ^sim.Host, dir: string) -> bool {
	if dir == "/" {
		return true
	}
	prefix := strings.concatenate({dir, "/"}, context.temp_allocator)
	for f in h.files {
		if len(f.path) > len(prefix) && f.path[:len(prefix)] == prefix {
			return true
		}
	}
	return false
}
