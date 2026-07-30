package shell

// The command table.
//
// One declarative entry per command, carrying its own help text and its own
// list of value-taking flags. `help` is generated from this table rather than
// written by hand, so it is structurally incapable of drifting out of date --
// the failure mode where documented flags no longer exist cannot happen.

Category :: enum u8 {
	Builtin,
	Filesystem,
	Recon,
	Access,
}

Command_Spec :: struct {
	name:     string,
	category: Category,
	usage:    string,
	summary:  string,

	// Short flags that consume the following token. See parse.odin -- this
	// cannot be inferred from syntax, because `-p 22` and `-sV` look alike.
	value_flags: []string,

	run: proc(s: ^Session, cmd: ^Command),
}

// Ordered for `help`: what you stand on, then what you look with, then what you
// move with.
COMMANDS := []Command_Spec {
	{name = "help", category = .Builtin, usage = "help [command]", summary = "list commands, or explain one", run = cmd_help},
	{name = "clear", category = .Builtin, usage = "clear", summary = "clear the terminal", run = cmd_clear},
	{name = "history", category = .Builtin, usage = "history", summary = "show recent commands", run = cmd_history},
	{name = "whoami", category = .Builtin, usage = "whoami", summary = "print the current user", run = cmd_whoami},
	{name = "hostname", category = .Builtin, usage = "hostname", summary = "print the current host", run = cmd_hostname},
	{name = "id", category = .Builtin, usage = "id", summary = "show user and access level", run = cmd_id},
	{name = "creds", category = .Builtin, usage = "creds", summary = "list credentials you hold", run = cmd_creds},
	{name = "exit", category = .Builtin, usage = "exit", summary = "leave the current shell", run = cmd_exit},

	{name = "pwd", category = .Filesystem, usage = "pwd", summary = "print the working directory", run = cmd_pwd},
	{name = "ls", category = .Filesystem, usage = "ls [-l] [path]", summary = "list directory contents", run = cmd_ls},
	{name = "cd", category = .Filesystem, usage = "cd [path]", summary = "change directory", run = cmd_cd},
	{name = "cat", category = .Filesystem, usage = "cat <file>", summary = "read a file", run = cmd_cat},

	{
		name = "nmap",
		category = .Recon,
		usage = "nmap [-sn|-sV] <target>",
		summary = "scan for live hosts and services",
		value_flags = {"p"},
		run = cmd_nmap,
	},

	{
		name = "curl",
		category = .Recon,
		usage = "curl <url>",
		summary = "fetch a page from a web server",
		run = cmd_curl,
	},

	{
		name = "ssh",
		category = .Access,
		usage = "ssh <user@host>",
		summary = "log in with a credential you hold",
		value_flags = {"p"},
		run = cmd_ssh,
	},
}

lookup :: proc(name: string) -> (Command_Spec, bool) {
	for spec in COMMANDS {
		if spec.name == name {
			return spec, true
		}
	}
	return {}, false
}

category_label :: proc(c: Category) -> string {
	switch c {
	case .Builtin:
		return "shell"
	case .Filesystem:
		return "files"
	case .Recon:
		return "recon"
	case .Access:
		return "access"
	}
	return ""
}
