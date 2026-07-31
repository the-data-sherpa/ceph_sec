package tests

import "core:os"
import "core:strings"
import "core:testing"
import "../src/campaign"
import "../src/replay"
import "../src/shell"
import "../src/sim"

// The regression corpus: determinism as a corpus rather than as a claim.
//
// Every other determinism test in this suite is self-referential in some way.
// The golden digests pin three numbers, which is a real check but a narrow one:
// three runs, no interrupts, no level transitions, no waiting. The playthrough
// suite proves each level is winnable, but compares nothing against a committed
// value. What has never existed is a *recorded session* -- what someone actually
// did, at the ticks they did it, with the answers written down -- that this
// build can be asked to reproduce.
//
// That is what these files are. Each one is a session: commands at ticks,
// interrupts where they happened, level changes where they happened, and marks
// carrying the event digest and the world digest at that moment. Playing one
// back either reproduces it exactly or names the tick it stopped.
//
// They are the payoff of everything else in this milestone. A replay is only
// worth committing because the transition tick is no longer frame-quantised
// (the world would run a different number of ticks per run), because a
// transition names a level id rather than a position in a list (renumbering
// would silently retarget it), and because there is one digest implementation
// rather than two.
//
// REGENERATING. Set CEPHSEC_REGEN_REPLAYS=1 and run the suite; the corpus is
// rewritten from the scripts below by the same driver that verifies it, so a
// corpus file can never describe a run the player cannot reproduce. Doing that
// after a behaviour change is correct and should be its own reviewable line in a
// diff. Doing it because the test went red is how a corpus stops being one.

REPLAY_DIR :: "tests/replays"

Script_Step :: struct {
	at:   int, // ticks into this segment
	kind: replay.Kind,
	text: string,
}

Script_Segment :: struct {
	level: string,
	steps: []Script_Step,
}

// A recorded session, before the marks are in it.
Script :: struct {
	file:     string,
	progress: []string, // completed level ids at the moment recording began
	segments: []Script_Segment,
}

// The corpus, as scripts. Each is chosen for something a `--exec` string cannot
// express.
CORPUS := []Script {
	// Two levels and the transition between them. Covers the level id in a
	// Transition, the segment boundary, and progress changing underneath the
	// player -- `play 2` is refused as locked until level one is recorded
	// complete, which happens inside the tick loop.
	{
		file = "campaign-two-levels.replay",
		progress = {},
		segments = {
			{
				level = "recon-sweep",
				steps = {
					{at = 30, kind = .Cmd, text = "nmap -sn 10.0.4.0/24"},
					{at = 900, kind = .Cmd, text = "objectives"},
					{at = 960, kind = .Cmd, text = "play 2"},
				},
			},
			{
				level = "recon-versions",
				steps = {
					{at = 30, kind = .Cmd, text = "nmap -sV 10.0.7.0/24"},
					{at = 900, kind = .Cmd, text = "hint"},
					{at = 960, kind = .Cmd, text = "techniques"},
				},
			},
		},
	},

	// The combine level with the detection system live, played with an interrupt
	// and long gaps. This is the one that could not be a script:
	//
	//   - ^C has no command line, so `--exec` cannot express it at all.
	//   - The gaps are the content. Suspicion decays and the trace only advances
	//     while a segment sits above the alarm line, so twenty-five idle seconds
	//     between two scans is a different run from two scans back to back --
	//     and `--exec` dispatches as soon as the shell frees up, which makes the
	//     second one unwritable.
	//   - It starts from four completed levels, so it also covers a replay
	//     carrying its own progress.
	{
		file = "northwind-interrupted.replay",
		progress = {"recon-sweep", "recon-versions", "access-exposure", "lateral-reuse"},
		segments = {
			{
				level = "northwind",
				steps = {
					{at = 60, kind = .Cmd, text = "nmap -sV 10.0.4.0/24"},
					{at = 300, kind = .Intr}, // mid-scan, with the noise already charged
					{at = 900, kind = .Cmd, text = "trace"},
					{at = 2400, kind = .Cmd, text = "nmap -sn 10.0.4.0/24"},
					{at = 3000, kind = .Cmd, text = "curl http://10.0.4.11/"},
					{at = 3900, kind = .Cmd, text = "objectives"},
				},
			},
		},
	},
}

CORPUS_SEED :: 0xCEF5EC
CORPUS_GAME :: "m4-replay"

// Turns a script into the replay the driver takes as input: the same shape as a
// parsed file, with no marks in it yet.
@(private)
script_to_replay :: proc(sc: ^Script, rep: ^replay.Replay) {
	replay.init(rep, context.allocator)
	replay.set_game(rep, CORPUS_GAME)
	rep.catalogue = campaign.catalogue_digest()
	for id in sc.progress {
		replay.add_progress(rep, id)
	}
	for seg in sc.segments {
		s := replay.add_segment(rep, seg.level, CORPUS_SEED)
		for step in seg.steps {
			replay.add_entry(
				rep,
				s,
				replay.Entry{tick = sim.Tick(step.at), kind = step.kind, text = step.text},
			)
		}
	}
}

// Plays a replay through the real shell. `mode` decides whether the marks are
// checked or produced.
@(private)
corpus_play :: proc(
	rep: ^replay.Replay,
	mode: shell.Playback_Mode,
	journal: ^shell.Journal,
) -> shell.Playback {
	w: sim.World
	sim.world_init(&w, CORPUS_SEED)
	defer sim.world_destroy(&w)

	prog: campaign.Progress
	campaign.progress_init(&prog)
	defer campaign.progress_destroy(&prog)

	sess: shell.Session
	pb := shell.Playback {
		mode    = mode,
		journal = journal,
	}
	shell.replay_run(&w, &sess, &prog, rep, &pb)
	return pb
}

@(private)
corpus_path :: proc(file: string) -> string {
	return strings.concatenate({REPLAY_DIR, "/", file}, context.temp_allocator)
}

// --- the test ---------------------------------------------------------------

// Every committed replay reproduces, mark for mark.
//
// A failure here says one of three things: the simulation changed, the campaign
// content changed, or the replay machinery broke. The message names the tick and
// which of the two digests moved, and the catalogue check below distinguishes
// the second case from the other two.
@(test)
test_the_corpus_reproduces :: proc(t: ^testing.T) {
	for &sc in CORPUS {
		path := corpus_path(sc.file)
		data, read_err := os.read_entire_file(path, context.temp_allocator)
		// Deliberately a failure and not a skip. A corpus test that quietly
		// passes when the corpus is missing has stopped being a corpus test, and
		// nothing would ever tell you.
		if read_err != nil {
			testing.expectf(t, false, "could not read %s -- the regression corpus must be committed", path)
			continue
		}

		rep, perr, line := replay.parse(string(data), context.temp_allocator)
		if perr != .None {
			testing.expectf(t, false, "%s:%d: %s", path, line, replay.error_text(perr))
			continue
		}
		defer replay.destroy(&rep)

		testing.expectf(t, replay.mark_count(&rep) > 0, "%s carries no marks, so it verifies nothing", path)

		pb := corpus_play(&rep, .Verify, nil)
		testing.expectf(
			t,
			pb.ok,
			"%s diverged in segment %d (%s) at tick %d: %s (recorded %016x, got %016x); %d marks matched first",
			path,
			pb.segment,
			pb.level,
			u64(pb.tick),
			shell.divergence_text(pb.why),
			pb.want,
			pb.got,
			pb.marks_checked,
		)
	}
}

// The catalogue hash, checked separately so a content edit says so in its own
// words rather than surfacing as a digest mismatch three hundred ticks in.
@(test)
test_the_corpus_matches_the_catalogue :: proc(t: ^testing.T) {
	have := campaign.catalogue_digest()
	for &sc in CORPUS {
		path := corpus_path(sc.file)
		data, read_err := os.read_entire_file(path, context.temp_allocator)
		if read_err != nil {
			continue // reported by the test above
		}
		rep, perr, _ := replay.parse(string(data), context.temp_allocator)
		if perr != .None {
			continue
		}
		defer replay.destroy(&rep)

		testing.expectf(
			t,
			rep.catalogue == have,
			"%s was recorded against catalogue %016x, this build is %016x -- if the campaign content changed on purpose, regenerate with CEPHSEC_REGEN_REPLAYS=1",
			path,
			rep.catalogue,
			have,
		)
	}
}

// Regeneration, on request only.
//
// A test that rewrote the corpus every run would be a test that can never fail:
// it would record whatever the build does and then agree with itself. So it is
// behind an environment variable, and it is the *only* way the files are meant
// to be produced -- by the driver that verifies them, so a corpus file always
// describes something the player can actually do.
@(test)
test_regenerate_the_corpus_when_asked :: proc(t: ^testing.T) {
	if os.get_env("CEPHSEC_REGEN_REPLAYS", context.temp_allocator) != "1" {
		return
	}

	for &sc in CORPUS {
		input: replay.Replay
		script_to_replay(&sc, &input)
		defer replay.destroy(&input)

		j: shell.Journal
		shell.journal_init(&j, CORPUS_GAME, campaign.catalogue_digest(), sc.progress)
		defer shell.journal_destroy(&j)

		pb := corpus_play(&input, .Record, &j)
		if !testing.expectf(
			t,
			pb.ok,
			"%s: recording stopped in segment %d at tick %d: %s",
			sc.file,
			pb.segment,
			u64(pb.tick),
			shell.divergence_text(pb.why),
		) {
			continue
		}

		text, ferr := replay.format(shell.journal_replay(&j), context.temp_allocator)
		if !testing.expectf(t, ferr == .None, "%s: %s", sc.file, replay.error_text(ferr)) {
			continue
		}

		path := corpus_path(sc.file)
		werr := os.write_entire_file(path, transmute([]byte)text)
		testing.expectf(t, werr == nil, "could not write %s", path)
	}
}
