#!/usr/bin/env bash
#
# mayhem/test.sh — RUN libsndfile's own ctest suite (built by mayhem/build.sh into build-tests/) plus
# known-answer probes through the built sndfile-info/sndfile-convert/sndfile-cmp programs.
# ctest judges cases by exit code alone, so the probes are what makes the oracle behavioral: they assert
# exact decoded sample bytes and header fields, and fail when the programs are neutered.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

BT="$SRC/build-tests"
for b in ctest; do command -v "$b" >/dev/null || { echo "missing $b" >&2; emit_ctrf cmake-ctest 0 1 0; exit 1; }; done
for b in sndfile-info sndfile-convert sndfile-cmp; do
  [ -x "$BT/$b" ] || { echo "missing $BT/$b (mayhem/build.sh should have built it)" >&2; emit_ctrf cmake-ctest 0 1 0; exit 1; }
done

passed=0; failed=0

# 1) upstream's own suite (144 cases: every container format plus FLAC/Vorbis/Opus/MPEG)
out="$(cd "$BT" && ctest -j"$MAYHEM_JOBS" 2>&1)"; echo "$out" | tail -15
if summ="$(echo "$out" | grep -E 'tests passed, [0-9]+ tests failed out of [0-9]+' | tail -1)" && [ -n "$summ" ]; then
  tot="$(echo "$summ" | sed -E 's/.* out of ([0-9]+).*/\1/')"
  nf="$(echo "$summ" | sed -E 's/.*, ([0-9]+) tests failed.*/\1/')"
  passed=$((passed + tot - nf)); failed=$((failed + nf))
else
  echo "ctest produced no summary line" >&2; failed=$((failed + 1))
fi

# 2) known-answer probes: a hand-built WAV with fixed samples must round-trip through other formats
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
probes="$(BT="$BT" W="$W" python3 - <<'PY'
import os, struct, subprocess, wave
BT, W = os.environ["BT"], os.environ["W"]
vals = [0, 1000, -1000, 32767, -32768, 12345, -12345, 7]
pcm_le = struct.pack("<8h", *vals)
pcm_be = struct.pack(">8h", *vals)
src = os.path.join(W, "k.wav")
with wave.open(src, "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(8000); w.writeframes(pcm_le)

def run(*a):
    p = subprocess.run([os.path.join(BT, a[0])] + list(a[1:]), capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr

def check(name, ok):
    print(("PASS " if ok else "FAIL ") + name, flush=True)

rc, o = run("sndfile-info", src)
check("info wav: 8 frames, 8000 Hz, mono, PCM16",
      rc == 0 and "Frames      : 8" in o and "Sample Rate : 8000" in o
      and "Channels    : 1" in o and "Format      : 0x00010002" in o and "Signal Max  : 32768" in o)

au = os.path.join(W, "k.au")
rc, o = run("sndfile-convert", "-pcm16", src, au)
d = open(au, "rb").read() if os.path.exists(au) else b""
off = struct.unpack(">I", d[4:8])[0] if len(d) >= 8 else 0
check("wav -> au: .snd magic and exact big-endian samples", rc == 0 and d[:4] == b".snd" and d[off:] == pcm_be)

aif = os.path.join(W, "k.aiff")
rc, o = run("sndfile-convert", "-pcm16", src, aif)
d = open(aif, "rb").read() if os.path.exists(aif) else b""
i = d.find(b"SSND")
check("wav -> aiff: FORM/AIFF magic and exact SSND payload",
      rc == 0 and d[:4] == b"FORM" and d[8:12] == b"AIFF" and i > 0 and d[i + 16:] == pcm_be)

flac = os.path.join(W, "k.flac")
rc, o = run("sndfile-convert", "-pcm16", src, flac)
d = open(flac, "rb").read() if os.path.exists(flac) else b""
check("wav -> flac: fLaC magic", rc == 0 and d[:4] == b"fLaC")
rc, o = run("sndfile-info", flac)
check("info flac: 8 frames, 8000 Hz", rc == 0 and "Frames      : 8" in o and "Sample Rate : 8000" in o)
rc, o = run("sndfile-cmp", src, flac)
check("sndfile-cmp wav vs flac: identical audio", rc == 0 and o.strip() == "")
back = os.path.join(W, "back.wav")
rc, o = run("sndfile-convert", "-pcm16", flac, back)
with wave.open(back, "rb") as w:
    ok = rc == 0 and w.getnframes() == 8 and w.readframes(8) == pcm_le
check("flac -> wav: samples recovered exactly", ok)

other = os.path.join(W, "other.wav")
with wave.open(other, "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(8000); w.writeframes(struct.pack("<8h", *vals[:-1], 8))
rc, o = run("sndfile-cmp", src, other)
check("sndfile-cmp detects differing audio", rc != 0)
PY
)"
echo "$probes"
np="$(echo "$probes" | grep -c '^PASS ' || true)"; nfp="$(echo "$probes" | grep -c '^FAIL ' || true)"
if [ "$((np + nfp))" -lt 8 ]; then failed=$((failed + 1)); echo "KAT probes did not run to completion" >&2; fi
passed=$((passed + np)); failed=$((failed + nfp))

emit_ctrf cmake-ctest "$passed" "$failed" 0
