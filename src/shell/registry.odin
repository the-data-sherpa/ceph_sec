package shell

// The command table.
//
// One declarative entry per command, carrying its own help text and its own
// list of value-taking flags. `help` is generated from this table rather than
// written by hand, so it is structurally incapable of drifting out of date --
// the failure mode where documented flags no longer exist cannot happen.

Category :: enum u8 {
	Campaign,
	Builtin,
	Filesystem,
	Jobs,
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

	// Reaches across the network: takes sim time, occupies the terminal or a
	// slot, and can be interrupted. Everything else is a builtin, which happens
	// instantly on a box you already hold.
	job: bool,

	// May be suffixed with `&`. False for ssh: it moves the prompt, and a
	// backgrounded login would yank the terminal out from under whatever is
	// running in the foreground. That single declaration also means only a
	// foreground job can ever carry a pending move, which dissolves the hardest
	// concurrency problem in the milestone.
	backgroundable: bool,

	// Never touches a target, so it is free and stays free once trace exists.
	offline: bool,

	run: proc(s: ^Session, cmd: ^Command),
}

// Ordered for `help`: what you stand on, then what you look with, then what you
// move with.
COMMANDS := []Command_Spec {
	{name = "levels", offline = true, category = .Campaign, usage = "levels", summary = "list the campaign", run = cmd_levels},
	{name = "play", offline = true, category = .Campaign, usage = "play [n]", summary = "start a level", run = cmd_play},
	{name = "retry", offline = true, category = .Campaign, usage = "retry", summary = "restart this level", run = cmd_retry},
	{name = "objectives", offline = true, category = .Campaign, usage = "objectives", summary = "show this level's goals", run = cmd_objectives},
	{name = "techniques", offline = true, category = .Campaign, usage = "techniques", summary = "show ATT&CK coverage", run = cmd_techniques},

	{name = "help", offline = true, category = .Builtin, usage = "help [command]", summary = "list commands, or explain one", run = cmd_help},
	{name = "clear", offline = true, category = .Builtin, usage = "clear", summary = "clear the terminal", run = cmd_clear},
	{name = "history", offline = true, category = .Builtin, usage = "history", summary = "show recent commands", run = cmd_history},
	{name = "whoami", offline = true, category = .Builtin, usage = "whoami", summary = "print the current user", run = cmd_whoami},
	{name = "hostname", offline = true, category = .Builtin, usage = "hostname", summary = "print the current host", run = cmd_hostname},
	{name = "id", offline = true, category = .Builtin, usage = "id", summary = "show user and access level", run = cmd_id},
	{name = "creds", offline = true, category = .Builtin, usage = "creds", summary = "list credentials you hold", run = cmd_creds},
	{name = "trace", offline = true, category = .Builtin, usage = "trace", summary = "show attention you have drawn", run = cmd_trace},
	{name = "exit", offline = true, category = .Builtin, usage = "exit", summary = "leave the current shell", run = cmd_exit},

	{name = "jobs", category = .Jobs, usage = "jobs", summary = "list running jobs", offline = true, run = cmd_jobs},
	{name = "fg", category = .Jobs, usage = "fg [%n]", summary = "bring a job to the foreground", offline = true, run = cmd_fg},
	{name = "kill", category = .Jobs, usage = "kill [%n]", summary = "stop a running job", offline = true, run = cmd_kill},

	{name = "pwd", offline = true, category = .Filesystem, usage = "pwd", summary = "print the working directory", run = cmd_pwd},
	{name = "ls", offline = true, category = .Filesystem, usage = "ls [-l] [path]", summary = "list directory contents", run = cmd_ls},
	{name = "cd", offline = true, category = .Filesystem, usage = "cd [path]", summary = "change directory", run = cmd_cd},
	{name = "cat", offline = true, category = .Filesystem, usage = "cat <file>", summary = "read a file", run = cmd_cat},

	{
		name = "nmap",
		category = .Recon,
		usage = "nmap [-sn|-sV] [-T2] <t>",
		summary = "find live hosts and services",
		value_flags = {"p"},
		job = true,
		backgroundable = true,
		run = cmd_nmap,
	},

	{
		name = "curl",
		category = .Recon,
		usage = "curl <url>",
		summary = "fetch a page from a web server",
		job = true,
		backgroundable = true,
		run = cmd_curl,
	},

	{
		name = "ssh",
		category = .Access,
		usage = "ssh <user@host>",
		summary = "log in with a held credential",
		value_flags = {"p"},
		job = true,
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
	case .Campaign:
		return "campaign"
	case .Filesystem:
		return "files"
	case .Jobs:
		return "jobs"
	case .Recon:
		return "recon"
	case .Access:
		return "access"
	}
	return ""
}
