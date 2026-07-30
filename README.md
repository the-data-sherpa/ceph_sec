# Ceph.Sec

A hacking game in [Odin](https://odin-lang.org). Procedurally generated corporate
networks, real-time trace pressure, and a CRT terminal to work through.

The tools carry their real names — `nmap`, `ssh`, `hydra` — and the workflow is
the real one: recon, enumerate, exploit, pivot, exfil. Everything they act on is
simulated in-process. **The game cannot touch a network, and is built so that it
can't**: the simulation package is mechanically forbidden from importing any I/O,
platform, or vendor package, and `./build.sh gate` fails the build if that ever
changes.

> **Status: milestone 2 — the run can be lost.** Commands run in the background
> with `&` while the prompt stays live, and the network now notices you: every
> action costs attention in the segment it touches, and sustained noise brings a
> log review, credential rotation, someone hunting your footholds, and finally
> attribution. Win by recovering the objective; lose by being loud.

## Setup

Requires Odin. Odin drives the system linker through `clang` on Linux, but only
as a linker *frontend* — `build.sh` falls back to `gcc` via `ODIN_CLANG_PATH`
when clang is absent, so clang is optional.

```sh
curl -L -o /tmp/odin.tar.gz \
  https://github.com/odin-lang/Odin/releases/download/dev-2026-07a/odin-linux-amd64-dev-2026-07a.tar.gz
mkdir -p ~/.local/odin && tar -xzf /tmp/odin.tar.gz --strip-components=1 -C ~/.local/odin
ln -sf ~/.local/odin/odin ~/.local/bin/odin
```

`vendor:raylib` ships prebuilt inside that release, so there is no raylib build
step. `build.sh` falls back to `~/.local/odin/odin` if `odin` isn't on `PATH`,
and honours `ODIN=` if it lives elsewhere.

## Build

```sh
./build.sh check      # type-check every package + enforce sim purity
./build.sh gate       # purity gate alone (fast; suits a pre-commit hook)
./build.sh test       # sim test suite
./build.sh run        # debug build, then launch
./build.sh release    # optimised build
./build.sh all        # check + test + build
```

While running, type `help`. Suffix a command with `&` to background it, then
`jobs` / `fg` / `kill` to manage it, and `trace` to see how much attention you
have drawn. `^C` interrupts the foreground command, `PgUp`/`PgDn` scroll, `↑`/`↓`
walk history. Display: `F1` CRT on/off · `F2` curved/flat · `F3` theme · `F12`
screenshot · `ESC` quit.

```
nmap -sV -T2 10.0.4.0/24 &     a slow, quiet scan, running in the background
curl http://10.0.4.11/.env     ...while you work on something else
```

```sh
./build/cephsec --shot 12.5 frame.png            # run to a tick, capture, exit
./build/cephsec --exec "nmap -sV 10.0.4.0/24"    # run commands at startup
```

Because the sim is deterministic *and* the shader's time uniform is driven from
the sim clock rather than wall-clock, a given seed and tick count produce a
byte-identical PNG. That makes `--shot` a visual regression check, not just a
convenience — worth having early for a game whose look is carried by a shader.

Paths are resolved by raylib relative to the working directory; absolute paths
are not honoured.

## Layout

A directory is a package in Odin, and imports may only point downward.

```
src/sim/     simulation core — world, scheduler, events, trace. Pure, deterministic.
src/shell/   parsing, commands, jobs, tools. Pure — nmap and ssh live here.
src/input/   shared key vocabulary. No dependencies at all.
src/ui/      character grid, terminal, CRT pipeline — the only raylib consumer
src/main.odin  wires them together, owns the frame loop and the scenario
tests/       sim + shell suites (odin test)
assets/      crt.fs and future content
docs/        design.md — the systems bible
```

`sim ← shell ← main → ui`, with `input` as a shared leaf. Odin rejects import
cycles, so the direction is compiler-enforced.

### The three invariants

Established now because they cost nothing at this size and would be a rewrite
to retrofit once tools and gameplay exist.

1. **The sim and shell perform no I/O.** Enforced by `build.sh gate`, not
   convention. This matters most for `shell`: it is where the commands named
   `nmap` and `ssh` live, and therefore the one place someone might be tempted
   to make one of them real. The gate makes that a build failure.
2. **The sim does not render.** It appends to an event ring; the frontend drains
   it. Enforced by Odin's import rules.
3. **The sim is deterministic.** It advances only via `sim.tick()` at a fixed
   60 Hz and never reads a clock — real time is the *frontend* converting
   wall-clock delta into whole ticks. Same seed and tick count means a
   byte-identical world, which is what makes seeds shareable and replays real.

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

## Roadmap

| | |
| --- | --- |
| **M0** | engine foundation — sim core, scheduler, events, CRT pipeline ✅ |
| **M1** | terminal input, command parser, first tools ✅ |
| **M2** | background jobs and trace pressure — the run becomes losable ✅ |
| M3 | procedural network generation with attack-graph solvability proof |
| M4 | net map, exfil objectives, run-end |
| M5 | meta-progression between runs |

See `docs/design.md` for the systems design these build toward.
