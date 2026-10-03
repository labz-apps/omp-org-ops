# Measurement contract

How a number gets from a process launch to a public page, and what must be true
at each hop for the claim to mean anything.

This is the shared boundary between the benchmark harness (which produces
measurements inside the fork) and the leaderboard (which only renders them).
Nobody edits a number in between.

```text
harness run (fork, exact commit, named machine)
  -> JSON on stdout
    -> import-result (validates against the schema)
      -> data/results/<benchmark>-<runId>.json in labz-apps/omp-leaderboard
        -> npm run build (computes deltas, refuses stored deltas)
          -> dist/ -> GitHub Pages
```

A stage that cannot prove which commit, machine, and command it came from is
not a stage. That is the whole contract.

## What is measured

| Benchmark | Interval | Reported as |
| --- | --- | --- |
| `cold-start` | Process launch to first interactive frame: spawn the binary, wait for the TUI to accept input, and paint a frame that responds to it. | p50, p95 in ms |
| `time-to-render` | An input event submitted in a live TUI session, timed until the resulting frame is painted. | p50, p95 in ms |

Both are wall-clock milliseconds from a monotonic clock. Both must report p50
*and* p95 over many samples. A mean is not acceptable: a change that leaves the
median alone and doubles the tail is a regression the user feels, and a mean is
the statistic most likely to hide it.

## What must be held constant

Results are comparable within a **series**: one benchmark on one machine id.
Nothing else is comparable, and the site refuses to pretend otherwise.

Hold constant across a comparison:

| Held constant | Why |
| --- | --- |
| Machine (cpu model, physical cores, memory) | Enters the machine id. Different hardware is a different series. |
| OS and architecture | Different syscall and terminal paths. |
| Runtime and runtime version | A different runtime version is a different program. |
| Terminal emulator, size, and font | Terminal size changes layout and paint cost. |
| Build type | Source run, npm bundle, and compiled binary are different programs. |
| Working set (config, plugins, skills, session size) | Startup cost scales with it. Do not enable plugins between runs. |
| Background load | Close everything else. Record a noisy run, do not publish it. |

Measure the baseline and the change **back to back in one session**. Machine
state drifts by more than most optimizations save, so a "before" from last week
is not a baseline.

## Harness command

The harness lands in the fork under `labz-apps/oh-my-pi/scripts/bench/` with
OHM-3. Until it is merged, these commands are the agreed contract rather than a
runnable fact:

```bash
# quick mode: local iteration. Indicative only, never published.
bun scripts/bench/cold-start.ts --quick

# full mode: the numbers that may be published. --json is required.
bun scripts/bench/cold-start.ts --runs 20 --json > cold-start-<sha>.json
bun scripts/bench/time-to-render.ts --runs 200 --json > ttr-<sha>.json
```

One documented command runs the whole suite, and it is:

```bash
bun scripts/bench/run-all.ts --full --json > results-<sha>.json
```

Quick mode is for deciding whether an idea is worth a full run. Full mode is
the only thing that reaches the leaderboard. A result file records which mode
produced it, so the two can never be silently mixed.

## The result file

Enforced at import time and again at every build, by
`labz-apps/omp-leaderboard/src/schema.mjs`. A file that violates it fails the
build; it is never skipped quietly.

```jsonc
{
  "schemaVersion": 1,
  "runId": "cold-start-2026-01-05T090412Z-3f9a1c",  // harness run identifier
  "benchmark": "cold-start",                       // or "time-to-render"
  "startedAt": "2026-01-05T09:00:00.000Z",
  "finishedAt": "2026-01-05T09:04:12.000Z",
  "commit": {
    "sha": "1111111...",                            // exactly what was measured
    "repo": "labz-apps/oh-my-pi",
    "message": "perf(coding-agent): drop the startup animation"
  },
  "pr": {                                          // null until the PR merges
    "number": 42,
    "url": "https://github.com/labz-apps/oh-my-pi/pull/42",
    "title": "perf(coding-agent): drop the startup animation",
    "mergedAt": "2026-01-05T09:03:00.000Z"
  },
  "machine": {                                     // the comparison basis
    "id": "linux-x86-8c",                          // stable; series never mix machines
    "cpuModel": "AMD EPYC 7B12",
    "physicalCores": 8,
    "memoryGb": 16,
    "os": "Ubuntu 24.04",
    "arch": "x86_64"
  },
  "versions": { "ohMyPi": "18.4.9", "runtime": "bun", "runtimeVersion": "1.2.21" },
  "harness": {
    "version": "1",                                // bump when semantics change
    "command": "bun scripts/bench/cold-start.ts --runs 20",
    "config": { "runs": 20, "warmupRuns": 2, "coldCache": true }
  },
  "metrics": {
    "firstInteractiveFrameMs": {
      "unit": "ms",
      "p50": 1180.4,
      "p95": 1642.9,
      "samples": 20,
      "min": 1042.1,
      "max": 1701.6
    }
  }
}
```

Required provenance, with nothing optional except `commit.message` and
`pr`: `commit.sha`, `commit.repo`, `machine.id` and the rest of the machine
block, `versions`, `harness.version`, and `harness.command`. A metric must carry
`unit: "ms"`, `p50`, `p95`, and `samples`, and `p95` must be at least `p50`.

| Rule | What happens if it is broken |
| --- | --- |
| Missing provenance | Build fails |
| `p95 < p50`, or no `samples` | Build fails |
| `"synthetic": true` | Build fails |
| A `delta` field anywhere in the file | Build fails. Deltas are computed, never stored. |
| `finishedAt` before `startedAt` | Build fails |
| `pr` is null | Accepted, but rendered under "awaiting merge", never as a row |
| `pr.url` is not https, or `mergedAt` is not a timestamp | Accepted, but not a leaderboard row |

## How deltas are computed

Inside a series, ordered by finish time, each run is compared against **the
immediately preceding run in that same series**. Positive is slower; negative
is faster. The first run in a series has no baseline and shows no delta rather
than being compared against itself.

This is deliberately the only comparison the site makes. One row claims exactly
one comparison, between two runs of the same benchmark on the same machine. It
does not claim a percentage against some unrelated default, because that number
would depend on a machine nobody can verify.

## Importing and verifying

```bash
npm run import-result -- --stdin --pr <number>   # from a harness run
npm run import-result -- --file ~/cold-start-<sha>.json --pr <number>
npm run verify                                  # the full gate, 13 checks
npm test                                        # unit tests only
```

The importer also takes `--repo`, `--pr-title`, and `--pr-merged-at`. Those
three exist because pull-request provenance is *recorded*, never measured: the
harness cannot know whether the commit it just measured will be merged, so the
importer attaches it from the merged pull request. Fill them from the pull
request itself, not from memory.

`npm run verify` is the local stand-in for "the Pages site serves". It runs the
unit tests, builds from fixtures, asserts that every row traces to a merged
pull request, asserts that no result file carries a hand-written delta, asserts
that local asset references are relative, mounts the build under a project
Pages base path over real HTTP, proves the empty state degrades gracefully, and
proves that a synthetic or unprovenanced result fails the build.

Verify it before every result pull request. It is fast, offline, and it is the
same gate CI runs.

## Failure modes to recognise

| Symptom | Cause | Fix |
| --- | --- | --- |
| p50 flat, p95 much worse | Tail work: redraw storms, GC, unthrottled IO | Profile the tail, not the median |
| Cold start varies by hundreds of ms between identical runs | Warm caches, or a background process | Cold-cache runs, quieter machine, more samples |
| A change wins on one machine and loses on another | Machine id changed, or the series mixes builds | Keep one series per machine id and build type |
| Site renders no row | The run has no merged pull request | Re-import with `--pr <number>` after the merge |
| Build fails on a result file | Schema or provenance violation | Fix the run and re-import. Never edit the file. |
