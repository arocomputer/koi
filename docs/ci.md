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

## Dependency updates

The custom [Action updates workflow](../.github/workflows/deps.yml) runs on
Mondays at 09:00 UTC or manually on main. It replaces Dependabot and follows
Aft's separation of discovery, validation and publication. It maintains one
`chore/action-updates` PR and never merges it automatically.

`./x deps` is a read-only discovery command requiring Python 3 and an
authenticated GitHub CLI. Remote Actions must use a full commit SHA and a
`# vMAJOR` comment. The updater resolves that upstream major tag, follows
annotated tags, and rejects backward or divergent movements. Major versions,
Ghostty's pin, Zig and Xcode remain manual upgrades.

The discovery job has only repository read permission. It verifies candidate
SHA substitutions and runs portable regressions and catalog checks. A small
SHA map passes to the publishing job; no new artifact Actions or Python
packages are needed. The publisher checks out the same base commit and
revalidates the map against upstream before reconstructing just the pin edits.
If main or an upstream tag moved in the meantime, it fails for a fresh retry.

The publisher refuses branches without an owned PR, commits with non-bot
authorship or an unexpected title, and branch diffs beyond workflow pins. Updates
use a lease against the observed remote head. It creates a
draft (or withdraws an existing PR's readiness before pushing), watches the
normal PR-triggered CI run for the exact new commit, and marks it ready only
after success, checking the head before and after marking it ready. GitHub
does not offer an atomic readiness/head update; an observed race withdraws
readiness, and required CI remains the merge guard for later pushes. Failed
CI leaves a draft for the next
run to refresh. There is no duplicate manual CI dispatch.

### Publishing credential

Updating `.github/workflows/` requires **Workflows write** permission, which
the built-in `GITHUB_TOKEN` cannot request. See GitHub's
[workflow permission list](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#permissions)
and [additional authentication options](https://docs.github.com/en/actions/tutorials/authenticate-with-github_token#granting-additional-permissions).

Create a fine-grained personal access token restricted to this repository:

- Contents: read and write.
- Workflows: read and write.
- Pull requests: read and write.
- Actions: read (to watch CI).

Store it as the repository Actions secret `WORKFLOW_UPDATES_TOKEN` in GitHub
Settings → Secrets and variables → Actions. It is used only by the publisher,
never by candidate checks or PR CI. The workflow does not provision this credential.
With no updates, discovery succeeds without it; when updates exist but the
secret is missing, publication fails with a setup message. The PR is opened
as the token's user; commits use `github-actions[bot]` attribution. Renew the
token before it expires and retain the same account for existing update PRs.

### Dependency inventory

| Boundary | Count | Dependencies |
| --- | --- | --- |
| Direct external product code | 1 | libghostty-vt, pinned in `build-ghostty-vt.sh` |
| Remote Swift packages | 0 | GhosttyVt is locally built; CKoi/libkoi is Koi's own code |
| External libraries used through the pinned VT build | 4 | uucode, Wuffs, SIMDUTF, Highway |
| Distinct GitHub Actions | 3 | actions/checkout, mlugg/setup-zig, actions/cache |

These categories are not a complete runtime/build bill of materials. The
engine also uses build helpers such as translate-c and includes Unicode/color
data. Zig supplies its standard library and compiler/runtime support; the
Linux target uses musl and LLVM C++ runtimes. Apple SDK frameworks and the
Swift/Xcode toolchain are platform dependencies. Bundled logo artwork has
separate provenance. See [third-party notices](../THIRD_PARTY_NOTICES.md) for
the shipped components and licenses. The full Ghostty application's manifest
lists additional dependencies that Koi's VT-only build does not use.

Next priorities are native Linux tests, auditing omitted hosted integration
tests, and a release workflow with explicit signing/notarization and artifact
verification when Koi is ready to distribute. A merge queue, mandatory second
reviewer, and a new generic build framework add little value for the current
single-maintainer repository.
