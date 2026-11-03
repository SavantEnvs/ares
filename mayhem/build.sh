#!/usr/bin/env bash
#
# mayhem/build.sh — build ares' fuzz harnesses, their -standalone reproducers and the i8080 test runner.
#
# Runs in /mayhem (SRC). ares' own build is CMake + Qt/SDL/etc. for the desktop app; none of that is
# needed here, so the libraries the harnesses exercise are compiled directly (the same translation units
# the CMake targets use). All intermediates live in $SRC/build (gitignored by upstream's `/*`).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
B="$SRC/build"
mkdir -p "$B/fuzz" "$B/test"

# ---- tiny job pool -------------------------------------------------------------------------------------
rm -f "$B/.fail"
pool_wait_slot() { while [ "$(jobs -rp | wc -l)" -ge "$MAYHEM_JOBS" ]; do wait -n || true; done; }
pool_drain() { wait || true; [ ! -e "$B/.fail" ] || { echo "a build job failed" >&2; exit 1; }; }
run() { pool_wait_slot; ( "$@" || { echo "FAILED: $*" >&2; touch "$B/.fail"; } ) & }

INC=(-I"$SRC/nall" -I"$SRC" -I"$SRC/ares" -I"$SRC/thirdparty" -I"$SRC/thirdparty/TZXFile" -I"$SRC/thirdparty/sljit/sljit_src")
DEF=(-DMIA_LIBRARY -DBUILD_PERFORMANCE -DPROFILE_PERFORMANCE -DSLJIT_HAVE_CONFIG_PRE=1 -DSLJIT_HAVE_CONFIG_POST=1)
# Instrumented flags: sanitizers + DWARF-3 + libFuzzer coverage in every project object (not only the harness).
FUZZ=($SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -O1 -w)
FUZZXX=(-std=c++20 "${FUZZ[@]}" "${INC[@]}" "${DEF[@]}")
FUZZC=("${FUZZ[@]}" "${INC[@]}" "${DEF[@]}")
# Plain flags: the project's normal build, for the code generator and the test runner.
PLAINXX=(-std=c++20 -O2 -w "${INC[@]}" "${DEF[@]}")

# ---- 1) resource generator (host tool, unsanitized) ----------------------------------------------------
run $CXX "${PLAINXX[@]}" -c nall/nall/nall.cpp -o "$B/test/nall.o"
run $CXX "${PLAINXX[@]}" -c nall/nall/main.cpp -o "$B/test/main.o"
pool_drain
$CXX "${PLAINXX[@]}" tools/sourcery/sourcery.cpp "$B/test/nall.o" "$B/test/main.o" -o "$B/sourcery" -lpthread -ldl
(cd ares/ares/resource && "$B/sourcery" resource.bml resource.cpp resource.hpp)
(cd mia/resource && "$B/sourcery" resource.bml resource.cpp resource.hpp)
sed -e 's/@ARES_NAME@/ares/;s/@ARES_VERSION@/0/;s/@ARES_LEGAL_COPYRIGHT_SHORT@/ares/;s/@ARES_WEBSITE@/ares-emu.net/' \
  ares/ares/ares.cpp.in > "$B/ares_main.cpp"

# ---- 2) sanitized project objects ----------------------------------------------------------------------
F="$B/fuzz"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o "$F/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$F/standalone_main.o"

run $CXX "${FUZZXX[@]}" -c nall/nall/nall.cpp -o "$F/nall.o"
run $CXX "${FUZZXX[@]}" -c "$B/ares_main.cpp" -o "$F/ares_main.o"
run $CXX "${FUZZXX[@]}" -c ares/ares/memory/fixed-allocator.cpp -o "$F/fixed.o"
run $CXX "${FUZZXX[@]}" -c ares/gb/gb.cpp -o "$F/gb.o"
run $CXX "${FUZZXX[@]}" -c ares/component/processor/sm83/sm83.cpp -o "$F/sm83.o"
run $CXX "${FUZZXX[@]}" -c ares/component/eeprom/m93lcx6/m93lcx6.cpp -o "$F/m93.o"
run $CXX "${FUZZXX[@]}" -c mia/mia.cpp -o "$F/mia.o"
run $CXX "${FUZZXX[@]}" -c mia/resource/resource.cpp -o "$F/miares.o"
run $CXX "${FUZZXX[@]}" -c thirdparty/sljitAllocator.cpp -o "$F/sljita.o"
run $CC "${FUZZC[@]}" -c libco/libco.c -o "$F/libco.o"
run $CC "${FUZZC[@]}" -c thirdparty/sljit/sljit_src/sljitLir.c -o "$F/sljit.o"
for f in thirdparty/TZXFile/*.cpp; do
  run $CXX "${FUZZXX[@]}" -c "$f" -o "$F/tzx_$(basename "$f" .cpp).o"
done

# libchdr (single-TU unity build; CRC verification off so mutated hunks reach the codecs)
run $CC "${FUZZC[@]}" -Ithirdparty/libchdr/include -DWANT_RAW_DATA_SECTOR=1 -DWANT_SUBCODE=1 -DVERIFY_BLOCK_CRC=0 \
  -c thirdparty/libchdr/unity.c -o "$F/chdr.o"
run $CC "${FUZZC[@]}" -Ithirdparty/libchdr/include -c thirdparty/libchdr/tests/fuzz.c -o "$F/fuzz_chd.o"

for h in zip png gzip bmp gb; do
  run $CXX "${FUZZXX[@]}" -c "mayhem/fuzz_$h.cpp" -o "$F/fuzz_$h.o"
done
pool_drain

# ---- 3) link: one fuzzer + one -standalone per harness -------------------------------------------------
GB_OBJS=("$F/ares_main.o" "$F/fixed.o" "$F/gb.o" "$F/sm83.o" "$F/m93.o" "$F/mia.o" "$F/miares.o" "$F/sljit.o" \
         "$F/sljita.o" "$F/libco.o" "$F/nall.o" "$F"/tzx_*.o)
LIBS=(-lpthread -ldl -lm)
link_pair() { # <name> <linker> <objs...>
  local name="$1" ld="$2"; shift 2
  run $ld $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link $LIB_FUZZING_ENGINE "$F/fuzz_$name.o" "$@" "$F/lsan_off.o" "${LIBS[@]}" -o "$SRC/fuzz_$name"
  run $ld $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link "$F/standalone_main.o" "$F/fuzz_$name.o" "$@" "$F/lsan_off.o" "${LIBS[@]}" -o "$SRC/fuzz_$name-standalone"
}
for h in zip png gzip bmp; do link_pair "$h" "$CXX" "$F/nall.o"; done
link_pair gb "$CXX" "${GB_OBJS[@]}"
link_pair chd "$CC" "$F/chdr.o"
pool_drain

# ---- 4) test oracle: ares' own i8080 CPU test harness, built with normal flags -------------------------
run $CXX "${PLAINXX[@]}" $COVERAGE_FLAGS -c "$B/ares_main.cpp" -o "$B/test/ares_main.o"
run $CXX "${PLAINXX[@]}" $COVERAGE_FLAGS -c ares/ares/memory/fixed-allocator.cpp -o "$B/test/fixed.o"
run $CXX "${PLAINXX[@]}" $COVERAGE_FLAGS -c ares/component/processor/i8080/i8080.cpp -o "$B/test/i8080_core.o"
run $CXX "${PLAINXX[@]}" $COVERAGE_FLAGS -c tests/i8080/i8080.cpp -o "$B/test/i8080_main.o"
pool_drain
$CXX $COVERAGE_FLAGS "$B/test/i8080_main.o" "$B/test/i8080_core.o" "$B/test/ares_main.o" "$B/test/fixed.o" \
  "$B/test/nall.o" "$B/test/main.o" -o "$SRC/i8080-test" -lpthread -ldl -lm

echo "build.sh: done"
ls -la "$SRC"/fuzz_* "$SRC/i8080-test"
