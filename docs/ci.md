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
| Core tests (macOS / Linux) | `./x test-core`, native Zig tests | Core/build/CI or unknown inputs |
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
app tests and bundling share a runner to reuse their dependencies. Linux core tests execute natively with musl (the shipped server libc) on
Ubuntu 24.04, in addition to the Linux
server cross-build used by the Mac bundle. Both core matrix entries must pass.

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
sharing dependencies would duplicate the expensive preparation. The Linux and macOS core jobs run independently and retain their own compiler caches.

## Repository policy

The [ruleset](../.github/rulesets/main.json) follows ask/aft with
one stable required gate and a narrower administrator bypass:

- PRs and resolved review threads; squash merging and linear history.
- No branch deletion or force pushes.
- `CI required`, from GitHub Actions, with the branch up to date before merging.
- Zero mandatory approvals while there is one maintainer. CODEOWNERS routes
  review requests without making solo work impossible.
- Administrator bypass only through a PR, not unrestricted direct pushes.

The JSON is an importable API payload, not an automatically applied policy.
The matching main protection is active; check live settings for actual enforcement. A future merge queue needs a
`merge_group` trigger and validation before it is enabled.

## Dependency updates

The custom [Dependency updates workflow](../.github/workflows/deps.yml) runs on
Mondays at 09:00 UTC or manually on main. It maintains one
`chore/dependency-updates` PR authored by `github-actions[bot]` and never merges
it automatically. It uses GitHub's built-in workflow token.

`./x deps` discovers a forward stable Ghostty tag within the current major
version. Discovery checks ancestry, the tagged manifest and unchanged Zig
requirements. A development pin ahead of the newest stable release is left
alone. Major engine changes, Zig, Xcode and Action pins receive manual review.
The scheduled run reports available same-major Action pins in its summary;
`python3 scripts/check-actions.py` runs that read-only report locally.
Both commands require Python 3 and an authenticated GitHub CLI.

Discovery runs with read permission. Publication reconstructs only the
Ghostty commit pin at the same base, rechecks upstream and only creates an absent automation branch. An existing
PR is left untouched, preserving all commits and maintainer notes. The publisher
opens a draft, explicitly dispatches CI, and marks the PR ready
only when that exact commit passes. Failed validation leaves the PR draft for maintainer review. After merging,
the repository deletes its branch so the next update can be proposed.
An observed head change withdraws readiness; required CI still guards merges.

Engine updates also require the full `scripts/koid test` suite on an Apple
silicon Mac with Metal and `scripts/bundle.sh`, at the proposed commit, before
manual merge. Hosted checks do not replace that gate. Review the engine diff
and packaged notices with the test results.

## Release drafts

[Release draft](../.github/workflows/release.yml) is a manual main-branch workflow.
It accepts an existing stable tag matching `build.zig.zon`, requires successful
main CI for that commit, and records the maintainer's exact-commit full Metal
suite attestation. Read-only build and test work completes before a separate
job signs the bundle, submits it for notarization, staples the accepted ticket,
and validates an installation extracted into a private directory.

The output is a Developer ID signed archive, checksum file and **draft** GitHub
release. Missing signing configuration or failed verification stops the run.
Publication remains a separate maintainer action; the workflow never installs
into Applications or launches the app. Development bundles continue to use the
ordinary `scripts/bundle.sh` signing behavior.
