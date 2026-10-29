# CI and repository maintenance

Koi borrows the shared `./x` command interface from
[ask](https://github.com/arocomputer/ask/blob/main/x) and
[aft](https://github.com/arocomputer/aft/blob/main/x). Commands remain small
wrappers around Koi's existing build and isolated test scripts. `./x check`
runs all local checks; it requires an Apple silicon Mac with Metal. Hosted
Actions uses the individual commands described below.

## Checks and selection

The [workflow](../.github/workflows/ci.yml) always starts for PRs, pushes to
`main` and manual runs. It never publishes or installs an app.

| Check | Work | PR selection |
| --- | --- | --- |
| Select checks | Compute the complete PR diff | Always |
| Script regressions | `./x scripts` on Linux | Always |
| Application catalog | `./x programs` on Linux | Always |
| Core tests (macOS) | `./x test-core`, native Zig tests | Core/build/CI or unknown inputs |
| App tests and bundle (macOS) | `./x test-app`, `./x bundle` | App/core/build inputs or packaged resources outside the program catalog |
| CI required | Verify all selected checks succeeded | Always, including failures |

Ordinary docs and program catalog/artwork changes skip native jobs. Catalog
checks cover schema, executable aliases, colors, SVGs, source records and
checksums. AppKit loading, SF Symbol availability and visual legibility still
need a Mac; see [Contributing](../CONTRIBUTING.md#program-icons). Changes to
packaged licenses or `THIRD_PARTY_NOTICES.md` run the app/bundle job.

Selection uses a NUL-delimited Git diff from the PR merge base, includes
deleted files and both sides of renames, and has no changed-file API limit.
Unknown paths or unavailable history run all native jobs. Main and manual
runs always run everything. Core tests run in parallel with the app job;
app tests and bundling share a runner to reuse their dependencies. Linux is
cross-compiled for the bundle; CI does not yet execute Linux core tests.

The final gate requires successful selection, script and catalog checks.
Each selected native job must succeed; an unselected job must be skipped.
Failures, cancellations, missing outputs and unexpected skips fail the gate.
Do not replace this with workflow-level path filters: skipped required
workflows can remain pending. See GitHub's
[required-check guidance](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-required-status-checks).

Hosted Swift checks use `scripts/koid test --headless`: the same checkout
lock, private server snapshot, temporary roots and process-verified cleanup
as the full suite. Its explicit allowlist is in `scripts/koid`; it is not
all non-GPU coverage. The full Metal/AppKit suite and benchmarks remain
required locally for code changes.

## Caches and performance

The initial successful hosted run took 22m05s: 16m15s for dependencies/core,
1m37s for core tests, 1m35s for Swift checks and 1m25s for the release bundle.
These are baseline measurements, not a promise about subsequent runs.

The workflow caches the completed Ghostty framework and core outputs
separately, using exact keys containing input hashes and actual Zig/Xcode/SDK
identities. The core cache contains both release server binaries and libkoi.
Build scripts always recheck their provenance stamps and required outputs
after restoration. A changed core source does not invalidate the separate
framework cache. Ghostty source is fetched at its pinned commit with shallow
history; core tests fetch source without compiling the Apple framework.

`setup-zig` also maintains compiler caches, with separate namespaces for the
core-test and app/bundle jobs. No broad fallback keys are used for finished
native outputs. Caches accelerate builds; they are not release artifacts.
PR caches are scoped by GitHub and do not seed the base branch. The first
successful full run on main seeds caches available to later PRs. See
[cache access restrictions](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching#restrictions-for-accessing-a-cache).

Measure cold and warm main/PR runs before adding a Swift `.build` cache or
splitting app tests and bundling into separate runners. Moving them without
sharing dependencies would duplicate the expensive preparation. Native Linux
test execution would add useful coverage; it should be introduced and tested
as a separate lane rather than describing a cross-build as Linux testing.

## Repository policy

The audit found no Koi branch rulesets or legacy protection on `main`.
The proposed [ruleset](../.github/rulesets/main.json) follows ask/aft with
one stable required gate and a narrower administrator bypass:

- PRs and resolved review threads; squash merging and linear history.
- No branch deletion or force pushes.
- `CI required`, from GitHub Actions, with the branch up to date before merging.
- Zero mandatory approvals while there is one maintainer. CODEOWNERS routes
  review requests without making solo work impossible.
- Administrator bypass only through a PR, not unrestricted direct pushes.

The JSON is an importable API payload, not an automatically applied policy.
Activate it only after the new `CI required` check has passed on GitHub.
Check live settings for actual enforcement. A future merge queue needs a
`merge_group` trigger and validation before it is enabled.

The [Dependabot configuration](../.github/dependabot.yml) groups weekly
GitHub Actions updates. Actions stay pinned to commits. Ghostty upgrades
remain deliberate pin changes with compatibility and license review; an
automatic engine updater or release publisher is not configured.

Next priorities are native Linux tests, auditing omitted hosted integration
tests, and a release workflow with explicit signing/notarization and artifact
verification when Koi is ready to distribute. A merge queue, mandatory second
reviewer, and a new generic build framework add little value for the current
single-maintainer repository.
