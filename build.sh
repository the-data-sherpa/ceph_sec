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

# The sim must never touch the outside world.
#
# This is the invariant that keeps "built off real-world scenarios, but not
# actual hacking" true by construction rather than by good intentions: the
# simulation cannot open a socket, read a file or spawn a process, because it
# cannot even name the packages that would let it. It is also what makes the
# sim deterministic and testable.
#
# Enforced here rather than trusted to code review, because the cost of noticing
# late is a rewrite.
purity_gate() {
    local violations=0

    # Forbidden imports. core:fmt is deliberately allowed -- string formatting
    # is pure -- but its printing procedures are not, and are checked below.
    if grep -rnE '^[[:space:]]*import[[:space:]]+([a-zA-Z_]+[[:space:]]+)?"(core:(net|os|os/os2|sys|c|c/libc|thread|prof)|vendor:|system:)' src/sim/ 2>/dev/null; then
        echo "  ^ sim must not import I/O, platform or vendor packages" >&2
        violations=1
    fi

    # Printing is I/O even when it comes from an allowed package.
    if grep -rnE '\bfmt\.(print|println|printf|eprint|eprintln|eprintf)\b' src/sim/ 2>/dev/null; then
        echo "  ^ sim must not print; emit an Event instead" >&2
        violations=1
    fi

    # The sim/render seam. Odin already rejects import cycles, but this catches
    # the mistake with a useful message instead of a cycle error.
    if grep -rnE '^[[:space:]]*import[[:space:]]+([a-zA-Z_]+[[:space:]]+)?"[^"]*\bui\b' src/sim/ 2>/dev/null; then
        echo "  ^ sim must not know about the renderer" >&2
        violations=1
    fi

    if [ "$violations" -ne 0 ]; then
        echo "PURITY GATE FAILED" >&2
        exit 1
    fi
    echo "  purity gate ..... ok  (sim/ is I/O-free)"
}

do_check() {
    echo "checking:"
    "$ODIN" check src/sim -no-entry-point
    echo "  src/sim ......... ok"
    "$ODIN" check src/ui -no-entry-point
    echo "  src/ui .......... ok"
    "$ODIN" check src
    echo "  src ............. ok"
    "$ODIN" check tests -no-entry-point
    echo "  tests ........... ok"
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
    gate)    purity_gate ;;
    test)    do_test ;;
    debug)   do_build debug ;;
    release) do_build release ;;
    # Launched from the repo root so the relative asset paths resolve.
    run)     do_build debug && ./"$OUT_DIR/cephsec" ;;
    all)     do_check && do_test && do_build debug ;;
    *)       echo "usage: $0 {check|gate|test|run|debug|release|all}" >&2; exit 2 ;;
esac
