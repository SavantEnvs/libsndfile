#!/usr/bin/env bash
#
# mayhem/build.sh — builds, inside the commit image (as `mayhem`, in /mayhem):
#   1) libsndfile (static) with the fuzz sanitizers + DWARF 3 + SanCov  -> build-fuzz/
#   2) the three OSS-Fuzz harnesses from ossfuzz/, each as a libFuzzer binary and a -standalone reproducer
#   3) libsndfile + its programs + its own test suite with NORMAL flags -> build-tests/  (mayhem/test.sh runs it)
# Both build dirs match upstream's `/*[Bb]uild*/` .gitignore entry, so `git clean -ffdX` removes them.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# 1) Sanitized, SanCov-instrumented static library. The programs/examples/tests are not needed here.
# -fsanitize=fuzzer-no-link: the library has no LLVMFuzzer entry, but needs coverage counters to be fuzzable.
FUZZ_CFLAGS="-O1 $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
cmake -S . -B build-fuzz -G Ninja \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$FUZZ_CFLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_CFLAGS" \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_PROGRAMS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF \
  -DENABLE_CPACK=OFF -DENABLE_PACKAGE_CONFIG=OFF -DINSTALL_PKGCONFIG_MODULE=OFF
cmake --build build-fuzz -j"$MAYHEM_JOBS"

# External codecs the library links (FLAC, Vorbis, Opus, MPEG), resolved by name through pkg-config.
EXT_LIBS="$(pkg-config --libs flac vorbisenc vorbis ogg opus libmpg123) -lmp3lame -lm"

# 2) Harnesses (C++). The standalone driver is C, so compile it as C first to keep its linkage.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o build-fuzz/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -x c -c "$STANDALONE_FUZZ_MAIN" -o build-fuzz/standalone_main.o
for h in sndfile_fuzzer sndfile_alt_fuzzer sndfile_fmt_fuzzer; do
  $CXX -O1 $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE -Iinclude "ossfuzz/$h.cc" \
      build-fuzz/lsan_off.o build-fuzz/libsndfile.a $EXT_LIBS -o "/mayhem/$h"
  $CXX -O1 $SANITIZER_FLAGS $DEBUG_FLAGS -Iinclude "ossfuzz/$h.cc" build-fuzz/standalone_main.o \
      build-fuzz/lsan_off.o build-fuzz/libsndfile.a $EXT_LIBS -o "/mayhem/$h-standalone"
done

# 3) The project's own suite and programs, NORMAL flags (no sanitizers, no -gdwarf-3); test.sh only runs it.
cmake -S . -B build-tests -G Ninja \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS" \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_PROGRAMS=ON -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=ON \
  -DENABLE_CPACK=OFF -DENABLE_PACKAGE_CONFIG=OFF -DINSTALL_PKGCONFIG_MODULE=OFF
cmake --build build-tests -j"$MAYHEM_JOBS"
