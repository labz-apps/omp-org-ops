# Performance work SOP

The standard operating procedure for the oh-my-pi performance programme:
research, code experiments, benchmarks, pull requests, merges, and publication.

This document is the process of record. When it disagrees with a habit, the
habit is wrong. When it disagrees with reality, reality wins and this document
is wrong — fix it in the same pull request that discovers the problem.

The programme's whole output is a public, checkable claim: *oh-my-pi got faster,
here is the measurement, here is the pull request that did it*. Every rule below
exists to keep that claim true.

## Scope

Applies to anyone changing `labz-apps/oh-my-pi` for speed or latency, and to
anyone producing numbers that end up on the public leaderboard.

It does not cover correctness bug fixes or features. A fix that happens to make
things faster still needs before/after numbers, because otherwise nobody can
tell whether the regression it introduced was paid for.

## The org map

| Repository | Holds | Owner concern |
| --- | --- | --- |
| `labz-apps/oh-my-pi` | The fork. Agent code, the benchmark harness, the agent CHANGELOG. | The change under test |
| `labz-apps/omp-leaderboard` | The public site. Result files, generator, Pages workflows. | The public record |
| `labz-apps/omp-org-ops` | This repository. Runbooks, org scripts, CI. | The process |

Three repositories, one direction of travel: the fork produces a measurement,
the leaderboard stores and renders it, ops holds the rules. Nothing flows
backwards, and no number is ever typed by hand anywhere.

## The five rules

These are not style. Breaking one invalidates the public record.

1. **Nothing is delivered from a local disk.** Work lands as a branch, a pull
   request, and a merge on GitHub. A number that exists only on someone's disk
   is not a result.
2. **One change per pull request.** One hypothesis, one measurement, one delta.
   Bundled changes cannot be attributed and will not be merged.
3. **Baseline before the change.** A pull request with an "after" and no "before"
   is rejected without reading. Re-measure the baseline in the same session on
   the same machine; do not reuse a number from last week.
4. **No hand-entered numbers.** Every value on the leaderboard is read from a
   harness result file. Deltas are computed at build time and are never stored.
   See `docs/measurement-contract.md` for the file contract.
5. **Never trade correctness or responsiveness for a frame.** A faster number
   with a wrong answer, a dropped keystroke, or a visibly janky UI is a
   regression, not an improvement. Reject the change and say why.

## Stage 0 — research

Do not open a pull request until you can name the cost centre.

1. **Sync first.** Measure the fork against upstream
   (`git fetch upstream && git rev-list --count HEAD..upstream/main`). Optimising
   stale code produces a number that is meaningless after the next sync. If the
   fork is behind, stop and land the sync (OHM-1).
2. **Read the repo's own rules.** `labz-apps/oh-my-pi/AGENTS.md` and
   `CONTRIBUTING.md` are binding on the fork, including its bans on inline
   imports, `any`, and ad-hoc helpers that already exist centrally.
3. **Measure, then read.** Run the harness on the unmodified commit first. The
   profile tells you where the milliseconds are; guessing is how you spend a day
   on a two-millisecond path.
4. **Write the hypothesis down** in the issue, before you touch code: which
   stage of startup or which part of the render path, why you believe it costs
   the time, and what you expect the delta to be. A wrong hypothesis is a fine
   outcome; an unstated one is not.

For oh-my-pi specifically the usual cost centres are eager imports, top-level
await, synchronous filesystem walks, repeated config reads, plugin and skill
scanning, and bundling more than is needed. For time-to-render they are
synchronous layout on the hot path, unthrottled redraws, O(n) scans of the
message list, re-parsing on every keystroke, and blocking I/O inside the render
path.

**Stop rule.** If a hypothesis survives a profile and produces no measurable
delta at full mode, close it with the numbers attached. A documented negative
result is a contribution; a merged change with noise-level improvement is not.

## Stage 1 — code experiment

Keep experiments cheap and reversible. A pull request is the unit of
attribution, so the experiment has to fit in one.

1. Branch from an up-to-date `main`. Name it `perf/<what-it-changes>`, for
   example `perf/lazy-plugin-scan`.
2. Change one thing. Resist the drive to also tidy the surrounding code in the
   same pull request; that belongs in a separate `refactor/` pull request.
3. Run the local gates before you push:

   ```bash
   bun run setup          # once, on a fresh clone
   bun run check          # oxlint + oxfmt + types, tools and workspaces
   bun run ci:test:smoke  # the CLI entrypoint still starts
   ```

   Run the narrow test suite for the package you touched, not the whole repo.
   `bun run ci:test:full` is the honest gate before you ask for a review, not
   the gate before you push.
4. State the correctness argument in the draft, not in your head: what could
   this break, and what test or observation would catch it.

## Stage 2 — benchmark

The full protocol, including what must be held constant, how the machine is
identified, and the two rules the schema enforces by field name — build type,
and the state of the tree and the machine during the run — is in
`docs/measurement-contract.md`. In short:

```bash
# quick mode: local iteration, indicative only, never published
bun scripts/bench/cold-start.ts --quick

# full mode: the numbers that get published
bun scripts/bench/cold-start.ts --runs 20 --json > ~/cold-start-<sha>.json
bun scripts/bench/time-to-render.ts --runs 200 --json > ~/ttr-<sha>.json
```

Rules for the person holding the stopwatch:

- Full mode only. A quick-mode number never reaches the leaderboard.
- Same machine, same runtime version, same terminal, same terminal font, no other
  load. The machine id is derived from those facts and runs are only ever
  compared within one machine id.
- Compare the baseline and the change back to back in one session. Machine
  state drifts more than most optimizations save.
- Report p50 and p95 for both. A mean is not a metric here; a p95 regression with
  an unchanged p50 is exactly the bug this programme exists to catch.
- Keep the JSON. It is the evidence. A delta quoted without its run ids is a
  claim, not a measurement.

## Stage 3 — pull request

Target `labz-apps/oh-my-pi`. Use the repository's template and preserve its
sections and checklist.

The body must carry, in addition to what/why/testing:

```markdown
## Measurement

| run | commit | machine | cold start p50 / p95 (ms) | time-to-render p50 / p95 (ms) |
| --- | --- | --- | --- | --- |
| baseline | <sha> | <machine id> | <p50> / <p95> | <p50> / <p95> |
| change   | <sha> | <machine id> | <p50> / <p95> | <p50> / <p95> |

- harness: `bun scripts/bench/cold-start.ts --runs 20`
- run ids: `<id>`, `<id>`
- comparability: same machine, same runtime, same session
- delta: <x> ms cold start, <y> ms time-to-render (positive is slower)
```

Then:

- Tick `bun check` only if it passed. Explain skipped or inapplicable checks in
  `Testing` instead of quietly unticking them.
- Update the agent CHANGELOG for user-facing changes, following the attribution
  rules in `CONTRIBUTING.md`.
- Read the published body back after creating the pull request. A body that
  rendered wrong is a body nobody will trust.

CI is the referee. `labz-apps/oh-my-pi` runs lint, type check, Rust validation
through bazel, native addon builds, and the TypeScript test shards. Do not merge
around a red check; fix the branch or, if the failure is pre-existing on `main`,
say so explicitly with the failing job and the commit that introduced it.

## Stage 4 — merge and publish

1. **Merge when CI is green.** Employees are empowered to merge their own pull
   requests when CI is green and the change is a measured improvement. No
   per-pull-request approval is required for that case. This is the standing
   delivery rule from OHM-7.
2. **Record the number.** From the merged commit, in the leaderboard repository:

   ```bash
   npm run import-result -- --file ~/cold-start-<sha>.json --pr <number>
   npm run verify
   ```

   Or let CI do it: the `record-result` workflow runs the harness, imports the
   output, and opens the pull request for you.
3. **Never edit a result file to make it look better.** The build rejects
   hand-written deltas, unprovenanced rows, and synthetic results. If the build
   fails, fix the run, not the file.
4. **Merging a result file publishes the site.** `validate.yml` runs the
   identical gate on the pull request; `pages.yml` publishes on `main`. Verify
   the live site serves the new row before calling the issue done.
5. **Update the running total** on the tracking issue as each pull request lands,
   with the pull request link.

## Definition of done

A performance change is done when all of these are true.

- [ ] A baseline and a change were measured in full mode, back to back.
- [ ] The pull request carries both numbers, the machine, the harness command,
      and the run ids.
- [ ] The smallest verification that proves the change passes: `bun run check`,
      the touched package's tests, and `bun run ci:test:smoke`.
- [ ] CI is green on the pull request and the change is merged.
- [ ] The result is in `labz-apps/omp-leaderboard/data/results/` through the
      importer, referencing the merged pull request number.
- [ ] The leaderboard build passes `npm run verify` and the published site shows
      the row.
- [ ] The CHANGELOG entry and the running total are updated.

## Anti-patterns

| Anti-pattern | Why it is rejected |
| --- | --- |
| Quoting a delta from a previous session as the "before" | Machine state drifts; the comparison is not a measurement |
| Publishing a quick-mode number | Indicative only, not comparable with published runs |
| One pull request that both speeds up startup and refactors config | Two changes, no attributable delta |
| A p50 win that regresses p95 | The user feels the p95. It is a regression |
| Editing a leaderboard result file by hand | Breaks the chain from harness to page |
| A result file with no pull request number | Imports, but never becomes a leaderboard row |
| Comparing a compiled binary run with a source run | Different programs. `harness.build` is in the series key, so there is no delta |
| A baseline taken before a rebase landed in the shared checkout | `commit.shaAtFinish` will not match `commit.sha`; re-measure on one commit |
| A run taken while another run of the same benchmark was on the machine | `machine.concurrentRuns` is above 1: kept as evidence, never published |
| Measuring a fork that is behind upstream | The number dies at the next sync |
| "Feels much faster" with no harness run | Not evidence, and never will be |

## Quick reference

| Task | Command |
| --- | --- |
| Local gates in the fork | `bun run check && bun run ci:test:smoke` |
| Quick benchmark | `bun scripts/bench/cold-start.ts --quick` |
| Publishable benchmark | `bun scripts/bench/cold-start.ts --runs 20 --json` |
| Verify the leaderboard build | `npm run verify` |
| Import a measurement | `npm run import-result -- --file <file> --pr <number>` |
| Keep this document honest | `bash scripts/check-sop-links.sh` |

`scripts/check-sop-links.sh` runs in CI. It fails when a local path quoted in
these docs disappears, when a local markdown link breaks, or when a required
section is renamed. When it fails after an intentional rename, fix the document
in the same pull request.
