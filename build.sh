#!/usr/bin/env bash
# Ceph.Sec build driver.
#
#   ./build.sh check     type-check every package + enforce sim purity
#   ./build.sh test      run the sim test suite
#   ./build.sh run       debug build, then launch from the repo root
#   ./build.sh debug     debug build only
#   ./build.sh release   optimised build
#   ./build.sh all       check + test + debug build
set -euo pipefail

cd "$(dirname "$0")"
ODIN="${ODIN:-odin}"
OUT_DIR="build"

if ! command -v "$ODIN" >/dev/null 2>&1; then
    if [ -x "$HOME/.local/odin/odin" ]; then
        ODIN="$HOME/.local/odin/odin"
    else
        echo "error: 'odin' not found on PATH. See README.md for setup." >&2
        exit 1
    fi
fi

# Odin drives the system linker through clang on Linux. clang is not actually
# required for that job -- it is invoked as a linker frontend, and gcc accepts
# the same flags -- so fall back rather than making clang a hard dependency.
if [ -z "${ODIN_CLANG_PATH:-}" ] && ! command -v clang >/dev/null 2>&1; then
    if command -v gcc >/dev/null 2>&1; then
        export ODIN_CLANG_PATH=gcc
    else
        echo "error: neither clang nor gcc found; Odin needs one to link." >&2
        exit 1
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
GATE_EXEMPT="src/ui"

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

    rm -rf "$tmp"

    if [ "$rc" -ne 0 ]; then
        echo "GATE SELF-TEST FAILED" >&2
        exit 1
    fi
    echo "  gate self-test .. ok  (17 classes: 13 rejected, 4 allowed)"
}

do_check() {
    echo "checking:"
    "$ODIN" check src/input -no-entry-point
    echo "  src/input ....... ok"
    "$ODIN" check src/sim -no-entry-point
    echo "  src/sim ......... ok"
    "$ODIN" check src/campaign -no-entry-point
    echo "  src/campaign .... ok"
    "$ODIN" check src/shell -no-entry-point
    echo "  src/shell ....... ok"
    "$ODIN" check src/ui -no-entry-point
    echo "  src/ui .......... ok"
    "$ODIN" check src
    echo "  src ............. ok"
    "$ODIN" check tests -no-entry-point
    echo "  tests ........... ok"
    gate_selftest
    purity_gate
}

do_test() {
    mkdir -p "$OUT_DIR"
    "$ODIN" test tests -out:"$OUT_DIR/sim_tests"
}

do_build() {
    mkdir -p "$OUT_DIR"
    case "$1" in
        release) "$ODIN" build src -out:"$OUT_DIR/cephsec" -o:speed -no-bounds-check ;;
        *)       "$ODIN" build src -out:"$OUT_DIR/cephsec" -debug ;;
    esac
    echo "built $OUT_DIR/cephsec ($1)"
}

case "${1:-all}" in
    check)   do_check ;;
    # Standalone so it can run as a fast pre-commit hook, and so the gate itself
    # is testable without a compiler in the loop.
    gate)    gate_selftest && purity_gate ;;
    test)    do_test ;;
    debug)   do_build debug ;;
    release) do_build release ;;
    # The binary embeds its own assets, so this is only convenience.
    run)     do_build debug && ./"$OUT_DIR/cephsec" ;;
    all)     do_check && do_test && do_build debug ;;
    *)       echo "usage: $0 {check|gate|test|run|debug|release|all}" >&2; exit 2 ;;
esac
