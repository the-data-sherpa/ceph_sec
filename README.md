# Ceph.Sec

A hacking game in [Odin](https://odin-lang.org). Procedurally generated corporate
networks, real-time trace pressure, and a CRT terminal to work through.

The tools carry their real names — `nmap`, `ssh`, `hydra` — and the workflow is
the real one: recon, enumerate, exploit, pivot, exfil. Everything they act on is
simulated in-process. **The game cannot touch a network, and is built so that it
can't**: the simulation package is mechanically forbidden from importing any I/O,
platform, or vendor package, and `./build.sh gate` fails the build if that ever
changes.

> **Status: milestone 0 — engine foundation.** The simulation core, fixed-tick
> scheduler, event pipeline and CRT renderer are live and tested. There is no
> command input yet, so there is nothing to play. It compiles, and it glows.

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

While running: `F1` CRT on/off · `F2` curved/flat · `F3` theme · `F12` screenshot
· `ESC` quit.

```sh
./build/cephsec --shot 12.5 frame.png   # run to a fixed tick, capture, exit
```

Because the sim is deterministic *and* the shader's time uniform is driven from
the sim clock rather than wall-clock, a given seed and tick count produce a
byte-identical PNG. That makes `--shot` a visual regression check, not just a
convenience — worth having early for a game whose look is carried by a shader.

Paths are resolved by raylib relative to the working directory; absolute paths
are not honoured.

## Layout

A directory is a package in Odin, and imports may only point downward:
`sim ← ui ← main`. Odin rejects import cycles outright, so the architecture is
compiler-enforced rather than documented and hoped for.

```
src/sim/     simulation core — pure, deterministic, no I/O, no raylib
src/ui/      character grid, terminal, CRT pipeline — the only raylib consumer
src/main.odin  wires the two together and owns the frame loop
tests/       sim test suite (odin test)
assets/      crt.fs and future content
docs/        design.md — the systems bible
```

### The three invariants

Established now because they cost nothing at this size and would be a rewrite
to retrofit once tools and gameplay exist.

1. **The sim performs no I/O.** Enforced by `build.sh gate`, not convention.
2. **The sim does not render.** It appends to an event ring; the frontend drains
   it. Enforced by Odin's import rules.
3. **The sim is deterministic.** It advances only via `sim.tick()` at a fixed
   60 Hz and never reads a clock — real time is the *frontend* converting
   wall-clock delta into whole ticks. Same seed and tick count means a
   byte-identical world, which is what makes seeds shareable and replays real.

The PRNG (PCG32) is hand-rolled rather than taken from `core:math/rand` for the
same reason: `core:math/rand` may change algorithm between Odin releases, which
would silently invalidate every seed ever shared without breaking a build.
`tests/sim_test.odin` pins it against the reference PCG32 vector.

## Roadmap

| | |
| --- | --- |
| **M0** | engine foundation — sim core, scheduler, events, CRT pipeline ✅ |
| M1 | terminal input, command parser, first tools |
| M2 | async jobs and trace pressure — the run becomes losable |
| M3 | procedural network generation with attack-graph solvability proof |
| M4 | net map, exfil objectives, run-end |
| M5 | meta-progression between runs |

See `docs/design.md` for the systems design these build toward.
