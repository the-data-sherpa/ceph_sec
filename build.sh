#!/usr/bin/env bash
# Ceph.Sec build driver.
#
#   ./build.sh check          type-check every package + enforce sim purity
#   ./build.sh check-targets  type-check src for the platforms we cannot link
#   ./build.sh test           run the sim test suite
#   ./build.sh run            debug build, then launch from the repo root
#   ./build.sh debug          debug build only
#   ./build.sh release        optimised build
#   ./build.sh all            check + check-targets + test + debug build
set -euo pipefail

cd "$(dirname "$0")"
OUT_DIR="build"

# --- host -------------------------------------------------------------------
#
# Everything below that differs between platforms differs because of one of two
# facts: Windows executables carry an extension, and Windows does not link
# through clang. Both are decided once, here, rather than sprinkled through the
# targets.
case "$(uname -s)" in
    Linux)                HOST_OS=linux ;;
    Darwin)               HOST_OS=macos ;;
    MINGW*|MSYS*|CYGWIN*) HOST_OS=windows ;;
    *)                    HOST_OS=unknown ;;
esac

EXE=""
if [ "$HOST_OS" = windows ]; then
    EXE=".exe"
fi

ODIN="${ODIN:-odin}"
if ! command -v "$ODIN" >/dev/null 2>&1; then
    # MSYS/Git-bash usually resolves a bare `odin` to odin.exe, but that is a
    # property of the shell rather than something to rely on; probe explicitly
    # before falling back to the location README.md installs into. The `.exe`
    # candidate is tried on every host, not just a detected Windows one, so a
    # shell that reports an unrecognised uname still finds a working compiler.
    if command -v "$ODIN.exe" >/dev/null 2>&1; then
        ODIN="$ODIN.exe"
    elif [ -x "$HOME/.local/odin/odin$EXE" ]; then
        ODIN="$HOME/.local/odin/odin$EXE"
    elif [ -x "$HOME/.local/odin/odin.exe" ]; then
        ODIN="$HOME/.local/odin/odin.exe"
    elif [ -x "$HOME/.local/odin/odin" ]; then
        ODIN="$HOME/.local/odin/odin"
    else
        echo "error: 'odin' not found on PATH. See README.md for setup." >&2
        exit 1
    fi
fi

# Odin drives the system linker through clang on Linux and macOS. clang is not
# actually required for that job -- it is invoked as a linker frontend, and gcc
# accepts the same flags -- so fall back rather than making clang a hard
# dependency.
#
# Windows is excluded deliberately, and the exclusion is the whole point of the
# branch: there Odin drives link.exe (or lld) and never looks for clang, so a
# Windows host with neither clang nor gcc installed is entirely normal. Running
# this check there would have failed the build on a perfectly good toolchain.
if [ "$HOST_OS" != windows ]; then
    if [ -z "${ODIN_CLANG_PATH:-}" ] && ! command -v clang >/dev/null 2>&1; then
        if command -v gcc >/dev/null 2>&1; then
            export ODIN_CLANG_PATH=gcc
        else
            echo "error: neither clang nor gcc found; Odin needs one to link." >&2
            exit 1
        fi
    fi
fi

# Packages that must remain incapable of touching the outside world.
#
# This is the invariant that keeps "built off real-world scenarios, but not
# actual hacking" true by construction rather than by good intentions: these
# packages cannot open a socket, read a file or spawn a process, because they
# cannot even name the things that would let them.
#
# `shell` matters most: it is where the commands named nmap and ssh live, and
# therefore the one place where someone -- a contributor, a future me, a model
# -- might be tempted to make one of them real. `campaign` is level content,
# which must be as incapable of reaching a network as the engine running it.
#
# DENY BY DEFAULT. Every directory under src/ is inside the gate unless named
# here. The previous allowlist meant a package added later was ungated by
# accident and silently; naming an exemption is now a deliberate, reviewable act
# of granting something the ability to touch the outside world.
# src/ui talks to raylib; src/save is the one place allowed to touch the
# filesystem, and it knows nothing about the game -- it reads and writes a list
# of strings, so `campaign` never learns a filesystem exists.
GATE_EXEMPT="src/ui src/save"

gate_packages() {
    for d in src/*/; do
        d="${d%/}"
        case " $GATE_EXEMPT " in *" $d "*) continue ;; esac
        printf '%s\n' "$d"
    done
}

# Returns 0 clean, 1 violation. The explicit returns are load-bearing under
# `set -e`.
gate_scan() {
    local pkg="$1" violations=0
    [ -d "$pkg" ] || { echo "gate: $pkg does not exist" >&2; return 1; }

    # 1. foreign import binds a native library directly, with no import
    #    statement at all. This was a complete, working route from src/shell to
    #    socket(2) that every earlier version of this gate reported as clean --
    #    the `system:` alternative in rule 2 was dead code, because `system:`
    #    only ever appears inside a foreign import, which the `import` anchor
    #    excludes. The gate's whole claim rested on a check that did not fire.
    if grep -rnE '^[[:space:]]*foreign[[:space:]]+import' "$pkg" 2>/dev/null; then
        echo "  ^ $pkg must not foreign-import a native library" >&2
        violations=1
    fi

    # 2. Forbidden imports. core:fmt is deliberately allowed -- string
    #    formatting is pure -- but its printing procedures are not; see rule 3.
    #
    #    `import[^"]*"` matches any alias, digits included: the old
    #    `[a-zA-Z_]+` missed `import os7 "core:os"`. The trailing (/|") anchors
    #    the package name so core:c does not prefix-match core:container.
    if grep -rnE '^[[:space:]]*import[^"]*"(core:(net|os|sys|c|thread|prof|io|bufio|sync|dynlib|nbio|terminal|log|path/filepath)(/|")|vendor:|system:)' "$pkg" 2>/dev/null; then
        echo "  ^ $pkg must not import I/O, platform or vendor packages" >&2
        violations=1
    fi

    # 3. Printing is I/O even from an allowed package.
    #
    #    No trailing word boundary -- that is exactly what let fmt.printfln and
    #    fmt.eprintfln through. The impure families are print/eprint/fprint/
    #    wprint; aprint/bprint/caprint/sbprint/tprint/ctprint format into memory
    #    and stay allowed. No \b anywhere, so this behaves identically under
    #    BSD grep on a macOS runner.
    if grep -rnE '(^|[^A-Za-z0-9_.])fmt\.(e|f|w)?print' "$pkg" 2>/dev/null; then
        echo "  ^ $pkg must not print; emit an Event instead" >&2
        violations=1
    fi

    # 4. The logic/render seam. Redundant with rule 2, but gives a contributor
    #    the message they actually need.
    if grep -rnE '^[[:space:]]*import[^"]*"[^"]*/ui"' "$pkg" 2>/dev/null; then
        echo "  ^ $pkg must not know about the renderer" >&2
        violations=1
    fi

    return "$violations"
}

purity_gate() {
    local fail=0 pkg
    for pkg in $(gate_packages); do
        gate_scan "$pkg" || fail=1
    done
    if [ "$fail" -ne 0 ]; then
        echo "PURITY GATE FAILED" >&2
        exit 1
    fi
    echo "  purity gate ..... ok  ($(gate_packages | tr '\n' ',' | sed 's/,$//') are I/O-free)"
}

# The gate guards the project's central claim, so the gate itself is tested.
#
# Every class below is a route to the outside world that must be rejected. Four
# of them were accepted by the gate as shipped through M3 -- discovering that by
# writing this is the reason it exists rather than being trusted.
gate_selftest() {
    # Cleaned up explicitly rather than with a RETURN trap: bash does not scope
    # RETURN traps to the function unless functrace is set, so it fired later,
    # in a context where $tmp no longer existed -- which `set -u` then turned
    # into an error at the end of an otherwise clean build.
    local tmp rc=0
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/src/probe"

    must_reject() {
        local name="$1" body="$2"
        printf '%s\n' "$body" > "$tmp/src/probe/probe.odin"
        if (cd "$tmp" && gate_scan src/probe >/dev/null 2>&1); then
            echo "  gate self-test FAILED: accepted $name" >&2
            rc=1
        fi
    }
    must_accept() {
        local name="$1" body="$2"
        printf '%s\n' "$body" > "$tmp/src/probe/probe.odin"
        if (cd "$tmp" && gate_scan src/probe >/dev/null 2>&1); then :; else
            echo "  gate self-test FAILED: rejected legitimate $name" >&2
            rc=1
        fi
    }

    must_reject "core:net"            'package probe
import "core:net"'
    must_reject "core:os"             'package probe
import "core:os"'
    must_reject "aliased core:os"     'package probe
import os7 "core:os"'
    must_reject "core:thread"         'package probe
import "core:thread"'
    must_reject "core:io"             'package probe
import "core:io"'
    must_reject "core:dynlib"         'package probe
import "core:dynlib"'
    must_reject "vendor:raylib"       'package probe
import rl "vendor:raylib"'
    must_reject "the renderer"        'package probe
import "../ui"'
    must_reject "foreign import"      'package probe
foreign import libc "system:c"'
    must_reject "fmt.println"         'package probe
import "core:fmt"
f :: proc() { fmt.println("x") }'
    must_reject "fmt.printfln"        'package probe
import "core:fmt"
f :: proc() { fmt.printfln("x") }'
    must_reject "fmt.eprintfln"       'package probe
import "core:fmt"
f :: proc() { fmt.eprintfln("x") }'
    must_reject "fmt.fprintln"        'package probe
import "core:fmt"
f :: proc() { fmt.fprintln(nil, "x") }'

    # The formatting procedures the codebase depends on must keep working, or
    # the gate would be enforced by making the game unwritable.
    must_accept "fmt.tprintf"         'package probe
import "core:fmt"
f :: proc() -> string { return fmt.tprintf("%d", 1) }'
    must_accept "fmt.aprintf"         'package probe
import "core:fmt"
f :: proc() -> string { return fmt.aprintf("%d", 1) }'
    must_accept "core:strings"        'package probe
import "core:strings"'
    must_accept "core:mem/virtual"    'package probe
import "core:mem/virtual"'

    # The structural half of the gate: which directories are inside it at all.
    #
    # Everything above tests what a gated package may contain. Neither of these
    # did, and deny-by-default is the rule most likely to be quietly lost --
    # rewriting gate_packages as an explicit list is a one-line change that looks
    # like tidying. This milestone added src/replay, a hand-written parser for
    # files from strangers, which is exactly the package you would least like to
    # find outside the gate. It is inside it because every directory is, and this
    # is what proves that rather than restating it.
    mkdir -p "$tmp/src/brand_new" "$tmp/src/ui" "$tmp/src/save"
    listed=" $( (cd "$tmp" && gate_packages) | tr '\n' ' ') "
    case "$listed" in
        *" src/brand_new "*) : ;;
        *) echo "  gate self-test FAILED: a newly added package was not gated" >&2; rc=1 ;;
    esac
    case "$listed" in
        *" src/ui "*|*" src/save "*)
            echo "  gate self-test FAILED: an exempt package was gated anyway" >&2; rc=1 ;;
        *) : ;;
    esac

    rm -rf "$tmp"

    if [ "$rc" -ne 0 ]; then
        echo "GATE SELF-TEST FAILED" >&2
        exit 1
    fi
    echo "  gate self-test .. ok  (19 classes: 13 rejected, 4 allowed, 2 structural)"
}

do_check() {
    echo "checking:"
    "$ODIN" check src/input -no-entry-point
    echo "  src/input ....... ok"
    "$ODIN" check src/sim -no-entry-point
    echo "  src/sim ......... ok"
    "$ODIN" check src/campaign -no-entry-point
    echo "  src/campaign .... ok"
    "$ODIN" check src/replay -no-entry-point
    echo "  src/replay ...... ok"
    "$ODIN" check src/shell -no-entry-point
    echo "  src/shell ....... ok"
    "$ODIN" check src/save -no-entry-point
    echo "  src/save ........ ok"
    "$ODIN" check src/ui -no-entry-point
    echo "  src/ui .......... ok"
    "$ODIN" check src
    echo "  src ............. ok"
    "$ODIN" check tests -no-entry-point
    echo "  tests ........... ok"
    gate_selftest
    purity_gate
}

# The platforms this project claims to support but cannot produce a binary for
# from here.
#
# Cross-LINKING is refused outright: `odin build -target:windows_amd64` prints
# "Linking for cross compilation for this platform is not yet supported" -- and
# exits 0 while doing so, which is its own trap -- and a Linux Odin release
# ships an empty vendor/raylib/windows/, so there is nothing to link against
# either. Cross-CHECKING is a different matter: it runs the entire front end
# with the target's ODIN_OS and ODIN_ARCH, so every `when ODIN_OS ==` branch and
# every platform-sized type is compiled for real. It costs ~0.2s per target.
#
# That is not proof the game runs on a Mac. It is proof that the code someone
# will build on a Mac still type-checks, caught on this machine instead of in
# their terminal -- and it is the only cross-platform verification available
# without the hardware, so it runs every time rather than on request.
CHECK_TARGETS="windows_amd64 darwin_amd64 darwin_arm64 linux_arm64"

do_check_targets() {
    echo "cross-checking src:"
    local t
    for t in $CHECK_TARGETS; do
        "$ODIN" check src -target:"$t"
        printf '  %-14s .. ok\n' "$t"
    done
}

do_test() {
    mkdir -p "$OUT_DIR"
    "$ODIN" test tests -out:"$OUT_DIR/sim_tests$EXE"
}

do_build() {
    mkdir -p "$OUT_DIR"
    case "$1" in
        # -no-bounds-check is deliberately absent. It was here for speed that a
        # text-mode game at 60Hz does not need, and the binary now parses files
        # it did not write -- a save file, and soon more. An out-of-bounds index
        # on untrusted input should be a panic with a line number, not a silent
        # read of whatever was next in memory. -o:speed stays.
        release) "$ODIN" build src -out:"$OUT_DIR/cephsec$EXE" -o:speed ;;
        *)       "$ODIN" build src -out:"$OUT_DIR/cephsec$EXE" -debug ;;
    esac
    echo "built $OUT_DIR/cephsec$EXE ($1)"
}

# The stages below are sequenced by newline, never by `&&`, and that is not a
# style choice.
#
# `all) do_check && do_test` reads like it stops at the first failure. It does
# the opposite: bash suspends errexit for every command inside a function called
# from a && list, so a compiler error -- or a segfault -- inside do_check was
# swallowed, do_check returned the status of its last echo, and `./build.sh all`
# exited 0 on source that does not compile. `./build.sh check` was correct the
# whole time, which is why this survived: the one command a person actually
# types before pushing was the one that lied.
#
# As plain statements, errexit applies normally and the first failure stops the
# build.
case "${1:-all}" in
    check)
        do_check
        ;;
    # Standalone so it can run as a fast pre-commit hook, and so the gate itself
    # is testable without a compiler in the loop.
    gate)
        gate_selftest
        purity_gate
        ;;
    check-targets)
        do_check_targets
        ;;
    test)
        do_test
        ;;
    debug)
        do_build debug
        ;;
    release)
        do_build release
        ;;
    # The binary embeds its own assets, so this is only convenience.
    run)
        do_build debug
        ./"$OUT_DIR/cephsec$EXE"
        ;;
    all)
        do_check
        do_check_targets
        do_test
        do_build debug
        ;;
    *)
        echo "usage: $0 {check|gate|check-targets|test|run|debug|release|all}" >&2
        exit 2
        ;;
esac
