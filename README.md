# Ceph.Sec

A cybersecurity **learning game** in [Odin](https://odin-lang.org): a campaign of
levels structured around [MITRE ATT&CK](https://attack.mitre.org/), played through
a CRT terminal. Each level teaches one technique, and completing it permanently
unlocks the tool it taught.

The tools carry their real names — `nmap`, `ssh`, `hydra` — and the workflow is
the real one: recon, enumerate, exploit, pivot, exfil. Everything they act on is
simulated in-process. **The game cannot touch a network, and is built so that it
can't**: the simulation package is mechanically forbidden from importing any I/O,
platform, or vendor package, and `./build.sh gate` fails the build if that ever
changes.

> **Status: milestone 3 — the campaign framework**, plus the infrastructure the
> next fifty-five levels need. Five levels play end to end, from a first host
> sweep to a full engagement. Tools unlock as you earn them, objectives tick off
> as you meet them, and each level ends by naming the technique you just used and
> how a defender stops it. Progress persists, the binary is self-contained, and
> sessions can be recorded and replayed — so determinism is now a committed
> corpus rather than a claim. The remaining levels are content to be authored
> against a framework that is finished and tested.

## Setup

Requires Odin. Odin drives the system linker through `clang` on Linux and macOS,
but only as a linker *frontend* — `build.sh` falls back to `gcc` via
`ODIN_CLANG_PATH` when clang is absent, so clang is optional. On Windows Odin
links through MSVC and never looks for clang, so that check is skipped there.

```sh
curl -L -o /tmp/odin.tar.gz \
  https://github.com/odin-lang/Odin/releases/download/dev-2026-07a/odin-linux-amd64-dev-2026-07a.tar.gz
mkdir -p ~/.local/odin && tar -xzf /tmp/odin.tar.gz --strip-components=1 -C ~/.local/odin
ln -sf ~/.local/odin/odin ~/.local/bin/odin
```

`vendor:raylib` ships prebuilt inside that release, so there is no raylib build
step. `build.sh` falls back to `~/.local/odin/odin` (or `odin.exe`) if `odin`
isn't on `PATH`, and honours `ODIN=` if it lives elsewhere. On Windows, run
`build.sh` from Git Bash or MSYS2 — it detects the host and appends `.exe` to
everything it produces.

## Build

```sh
./build.sh check          # type-check every package + enforce sim purity
./build.sh gate           # purity gate alone (fast; suits a pre-commit hook)
./build.sh check-targets  # type-check src for windows/darwin/linux-arm64
./build.sh test           # sim test suite
./build.sh run            # debug build, then launch
./build.sh release        # optimised build
./build.sh all            # check + check-targets + test + build
```

Odin refuses to cross-*link* (`vendor/raylib/windows/` is empty in a Linux
release, and it says so), but it will cross-*check* in about 0.2s per target, so
`check-targets` runs the whole front end for `windows_amd64`, `darwin_amd64`,
`darwin_arm64` and `linux_arm64` on every build. That catches a platform-
conditional branch that no longer compiles; it is not a claim the game has been
run on those platforms. CI builds and links on Linux, macOS and Windows, but
only Linux actually opens a window and renders a frame.

Progress is saved as each level is completed, so the campaign survives closing
the game — under `$XDG_DATA_HOME/cephsec` on Linux, `Application Support` on
macOS, `%APPDATA%` on Windows. `--no-save` plays without reading or writing it.

While running: `levels` lists the campaign, `play <n>` starts one, `objectives`
shows your goals, `hint` gives an escalating nudge, `retry` restarts, and
`techniques` shows your ATT&CK coverage.
`help` lists what you can run — including what you *cannot* yet, and which level
teaches it.

Suffix a command with `&` to background it, then `jobs` / `fg` / `kill`; `trace`
shows how much attention you have drawn. `^C` interrupts the foreground command,
`PgUp`/`PgDn` scroll, `↑`/`↓` walk history. Display: `F1` CRT on/off · `F2`
curved/flat · `F3` theme · `F12` screenshot · `ESC` quit.

```
nmap -sV -T2 10.0.4.0/24 &     a slow, quiet scan, running in the background
curl http://10.0.4.11/.env     ...while you work on something else
```

```sh
./build/cephsec --shot 12.5 frame.png            # run to a tick, capture, exit
./build/cephsec --exec "nmap -sV 10.0.4.0/24"    # run commands at startup
./build/cephsec --record run.replay              # write down what you did
./build/cephsec --replay run.replay              # play it back and check it
```

### Replays

`--record` writes a plain-text file of what you did and when; `--replay` plays it
back **headlessly** — no window, exit code 0 if it reproduced and 1 if it did
not — and checks the digests recorded along the way.

A replay is not a script, and this is why `--exec` was not enough:

- **Timing is content.** Trace decay, suspicion cooldown and the hunt are all
  functions of elapsed ticks. `--exec` dispatches each command as soon as the
  shell frees up, so *scan, wait forty seconds, scan again* cannot be written
  down — and every decay, grace and hunt bug lives exactly there.
- **`^C` has no command line**, so an interrupt cannot be scripted at all.
- **Progress changes what commands do**, so a replay carries the completed
  levels it was recorded against.
- **A replay knows the right answer.** Every few seconds it records a *mark*:
  the digest of everything the world has said, and the digest of everything that
  is true. `--exec` has no notion of a correct outcome, only of having run.

```
segment northwind cef5ec
at 60 cmd nmap -sV 10.0.4.0/24
at 300 mark 9891251a38b05a52 fd46865e917ee650
at 300 intr
at 2400 cmd nmap -sn 10.0.4.0/24
```

Line-based, so it pastes into an issue and diffs there. `#` starts a comment only
as the first character of a line, and an **unknown verb is an error** — silently
skipping one is how a replay quietly stops testing anything.

It is also the project's first untrusted external input, in a binary people are
encouraged to point at files from strangers, so it is parsed accordingly: every
field length-checked, every number hand-parsed with an explicit overflow check,
every bound checked before the allocation, and nothing half-parsed ever returned.
`tests/replay_test.odin` is mostly negative cases.

`tests/replays/` holds the committed regression corpus, played by the test suite
and again by CI through the optimised binary. That is the payoff: determinism
stops being a claim and becomes a corpus.

Because the sim is deterministic *and* the shader's time uniform is driven from
the sim clock rather than wall-clock, a given seed and tick count produce a
byte-identical PNG. That makes `--shot` a visual regression check, not just a
convenience — worth having early for a game whose look is carried by a shader.

Paths are resolved by raylib relative to the working directory; absolute paths
are not honoured.

The binary is self-contained — the CRT shader is compiled into it — so it runs
from anywhere with no assets alongside it. CI proves that by copying it to an
empty directory and rendering a frame.

## Layout

A directory is a package in Odin, and imports may only point downward.

```
src/sim/       simulation core — world, scheduler, events, trace, digests.
src/campaign/  ATT&CK catalogue, level definitions, progress. Pure content.
src/replay/    the replay file format — parsing and formatting, no file I/O.
src/save/      progress persistence — the one package allowed to touch disk.
src/shell/     parsing, commands, jobs, tools, the tick loop, record and replay.
src/input/     shared key vocabulary. No dependencies at all.
src/ui/        character grid, terminal, CRT pipeline — the only raylib consumer
src/main.odin  wires them together, owns the frame loop and level transitions
tests/         engine, campaign and playthrough suites (odin test)
tests/replays/ the committed replay regression corpus
assets/        crt.fs
docs/          design.md — the systems bible
```

`sim ← campaign ← shell ← main → ui`, with `input` as a shared leaf and `replay`
alongside `campaign`. Odin rejects import cycles, so the direction is
compiler-enforced.

### The three invariants

Established now because they cost nothing at this size and would be a rewrite
to retrofit once tools and gameplay exist.

1. **The sim, shell and campaign perform no I/O.** Enforced by `build.sh gate`,
   not convention. This matters most for `shell`: it is where the commands named
   `nmap` and `ssh` live, and therefore the one place someone might be tempted
   to make one of them real. The gate makes that a build failure, and it covers
   level content too.

   The gate is **deny-by-default** — every directory under `src/` is inside it
   unless explicitly exempted, so a package added later cannot be ungated by
   accident. That rule is now itself tested rather than trusted, which matters
   because `src/replay` — a hand-written parser for files from strangers — is
   the package you would least like to find outside the gate. And the gate is
   tested: `build.sh gate` runs a self-test of 21 classes before it runs. That
   is not ceremony. Through M3 the gate accepted
   `foreign import libc "system:c"` — a complete route to `socket(2)` needing no
   import statement at all — along with `fmt.printfln`, aliased imports like
   `import os7 "core:os"`, and any newly added package. Writing the self-test is
   how those were found. The exemption list itself is pinned to a literal for
   the same reason: until I3 it was not, so adding `src/sim` to `GATE_EXEMPT`
   left the whole gate reporting `ok`, and the only signal was a shorter package
   list on a line nobody reads.
2. **The sim does not render.** It appends to an event ring; the frontend drains
   it. Enforced by Odin's import rules.
3. **The sim is deterministic.** It advances only via `sim.tick()` at a fixed
   60 Hz and never reads a clock — real time is the *frontend* converting
   wall-clock delta into whole ticks. The same commands at the same ticks mean a
   byte-identical world, which is what makes replays real.

   **Seeds are not yet shareable, and this README used to say they were.**
   Nothing in `src/` draws from `w.rng`: all five levels are hand-authored, so
   two different seeds produce byte-identical runs today. A replay records its
   seed because doing so is free and the generator will eventually matter, but
   sharing one buys you nothing at present and claiming otherwise would be a
   promise the code does not keep.

   Concurrency does not weaken this. There are no threads — background jobs are
   timers interleaving on the tick loop, and the purity gate's ban on
   `core:thread` is what guarantees it stays that way. Anything that gates a
   decision is a pure function of `w.now` rather than a latched flag, so the
   tick a command dispatches on cannot depend on the frame rate. All trace
   arithmetic is integer, with the sub-divisor remainder carried between ticks,
   so batching cannot change a total.

The PRNG (PCG32) is hand-rolled rather than taken from `core:math/rand` for the
same reason: `core:math/rand` may change algorithm between Odin releases, which
would silently invalidate every seed ever shared without breaking a build.
`tests/sim_test.odin` pins it against the reference PCG32 vector.

## The campaign

Levels follow ATT&CK's tactics in kill-chain order, in blocks of roughly four:
**teach → teach → apply → combine**. Techniques are not tools — `T1078 Valid
Accounts` and `T1110 Brute Force` both yield credentials — so only some levels
grant a new command; the rest teach a technique using what you already hold.

| # | Level | Technique | Unlocks |
| --- | --- | --- | --- |
| 1 | Knock and see who answers | T1595.001 Scanning IP Blocks | `nmap` |
| 2 | What is it running? | T1595.002 Vulnerability Scanning | — |
| 3 | Left in the open | T1552.001 Credentials In Files | `curl` |
| 4 | The same password, twice | T1078.003 Valid Accounts | `ssh` |
| 5 | Northwind Logistics | *combine* — and the detection system arrives | — |

Briefs state the goal and which tool applies, never the exact invocation — the
command lives behind `hint`, which escalates from a nudge to the answer and
skips past steps you have already solved. Using hints is recorded and never
penalised; finishing without them is noted in the debrief. That opt-in *is* the
difficulty setting.

**Levels are compiled-in Odin data**, so a level referencing a missing
prerequisite or an uncatalogued technique fails to build. A validator test
proves the prerequisite graph is acyclic, that no level offers a tool the player
cannot have by then, and that every objective points at something the level
actually builds. A second suite finishes every level through its own walkthrough
— the authored-content equivalent of proving a generated network solvable.

## Roadmap

| | |
| --- | --- |
| **M0** | engine foundation — sim core, scheduler, events, CRT pipeline ✅ |
| **M1** | terminal input, command parser, first tools ✅ |
| **M2** | background jobs and trace pressure — the run becomes losable ✅ |
| **M3** | campaign framework, ATT&CK curriculum, first five levels ✅ |
| M4 | the remaining tactic blocks, as content |
| M5 | par scoring |

Procedural generation is no longer planned. Authored levels are what a teaching
game needs, and a generated network cannot carry a lesson. If it returns it will
be a post-campaign endless mode, reusing the validator to prove solvability.

See `docs/design.md` for the systems design these build on.
