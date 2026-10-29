# CI and repository maintenance

Koi borrows the shared `./x` command interface from
[ask](https://github.com/arocomputer/ask/blob/main/x) and
[aft](https://github.com/arocomputer/aft/blob/main/x). Commands remain small
wrappers around Koi's existing build and isolated test scripts. `./x check`
runs all local correctness checks; it requires an Apple silicon Mac with Metal. Hosted
Actions uses the individual commands described below.

## Runners

The repository is [arocomputer/koi](https://github.com/arocomputer/koi).
Transferring ownership preserved its history, open PRs and active main-branch
ruleset. Local clones should use the organization URL:

```sh
git remote set-url origin https://github.com/arocomputer/koi.git
```

CI, dependency-update and release jobs use the organization's Namespace integration.
Runner labels keep the configuration in the workflows, without dashboard
profiles or a Namespace token in repository secrets:

| Jobs | `runs-on` label |
| --- | --- |
| Selection, script/catalog checks, Linux core tests, final gate and dependency updates | `nscloud-ubuntu-24.04-amd64-2x4` |
| Native tests, packaging and release drafts | `nscloud-macos-tahoe-arm64-6x14` |

The macOS jobs explicitly select
`/Applications/Xcode_26.3.app/Contents/Developer`. The image was inspected
with the Namespace CLI: Xcode 26.3 includes Swift 6.2.4, the macOS 26.2 SDK
and the Metal toolchain. Xcode 26.6 was not installed. `setup-zig` installs
the pinned Zig version; it is not assumed to be in the base image.
Workflow logs record the selected toolchain, and native output caches include
its actual identity. The existing Actions checkout/cache steps remain in use.

For runner debugging, install `brew install namespacelabs/namespace/nsc`,
run `nsc login` and select **Aro Computer Company**. CLI authentication stays
in your local Namespace keychain. It is not needed by the workflow, which
uses the organization's installed Namespace GitHub app. See
[Namespace runner labels](https://namespace.so/docs/reference/github-actions/runner-configuration).

To move providers again, change `runs-on` and verify the selected Xcode path
exists on the replacement image. GitHub-hosted equivalents are `ubuntu-latest`
and `macos-26`; select an installed Xcode explicitly on the latter. Keep job
IDs and the `Required` gate unchanged so branch protection continues to
work. Validate a PR run before merging a runner change. Do not disable or
weaken required checks to work around a queued or failing runner.

## Checks and selection

The [workflow](../.github/workflows/ci.yml) runs on PRs, main pushes and manual
requests. It has four jobs:

| Job | Work |
| --- | --- |
| Portable checks | Complete PR diff, script regressions and catalog validation on Linux |
| Native checks | Selected core tests, Swift tests and/or packaging on one Mac |
| Linux core tests | Selected core tests natively on Linux with musl, the shipped server's libc |
| Required | Require the portable job and every selected native step to pass |

Portable checks finish before a Mac is requested. The Mac steps share one
checkout, toolchain and dependency preparation, so a one-Mac workspace no
longer queues a second native job behind the first.

| Changed inputs in a PR | Core tests | Swift tests | Bundle/Linux cross-build |
| --- | --- | --- | --- |
| Docs, catalog, portable maintenance scripts/tests | No | No | No |
| App Swift source or Swift tests | No | Yes | No |
| Packaged licenses/notices | No | No | Yes |
| Other app resources or Package.swift | No | Yes | Yes |
| Core, build scripts, workflow or unknown inputs | Yes | Yes | Yes |

Main pushes select changed inputs too, adding packaging for app Swift edits.
Manual runs select everything. Selection reads the complete
NUL-delimited diff from the PR merge base, including deleted files and both
sides of renames, without the API's changed-file limit. Missing history
falls back to all checks. Catalog-only checks cover schema, aliases, SVGs
and provenance; review runtime artwork on a Mac when changing it.
The isolation regression is a portable-test exception: edits also select
the Mac lane to verify its Darwin process-ownership path.

Hosted Swift tests run in debug mode through the isolated runner. They
include existing private-server checks for session persistence, command/watch
round trips, the stdio relay, link authentication and link lifetime. They
exclude benchmarks and the rest of the serialized UI/GPU fixtures; use
focused local tests for those changes. The entire test target still compiles.

Routine Swift PRs do not cross-compile a Linux server or assemble a signed
bundle. Production packaging runs for relevant changes and on main. Tests
use development resource lookup, which production release builds intentionally
omit. When core tests are selected, a separate Linux job also runs them
natively against musl, alongside the Linux server cross-build used for
packaging.

The final gate checks both the Mac job result and each selected step's
outcome. A green job with a skipped selected test/bundle step fails the gate.
Missing outputs, cancellations and unexpected skips also fail. Keep this
stable check instead of workflow-level path filters, which can leave required
checks pending. See GitHub's
[required-check guidance](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-required-status-checks).

## Development checks

Use `./x test FILTER` or `./x test-core FILTER` while editing. They retain the
checkout lock, private paths, server snapshot and process-verified cleanup;
direct compiler/test commands do not provide the same isolation. Swift tests
prepare only the macOS server/library. Core-only tests fetch the pinned
engine source without building the Apple framework or release servers.

`./x check` runs portable checks and the full correctness suite. `./x bench`
is separate and opt-in; timing bounds should not interrupt ordinary UI or
correctness work. Run `./x bundle` when changing packaging, native build inputs
or toolchains, and for release validation. Do not repeat passing checks in an
unchanged checkout merely because another step finished.

Zig 0.17 prints `failed command: ./.zig-cache/o/.../test --listen=-` whenever a
test writes to stderr, and Koi's suites do that routinely (server and CLI
diagnostics). The line appears on passing runs too: trust the exit status and
the `Build Summary: N/N steps succeeded; N/N tests passed` line, not that
message. Test isolation is unaffected — the suite also passes with
`HOME=/nonexistent` and a private `KOI_DIR`.

CI pins Xcode 26.3 (Swift 6.2.4) and Zig 0.17.0; a local Xcode or Zig that
differs is the first thing to check when a native failure does not reproduce
in CI, or the reverse. `./x`, not the raw compiler, is the supported entry
point because it is what CI runs.

## Caches and performance

The first successful Namespace run took about eight minutes. Its 105 selected
Swift tests executed in 0.275 seconds; preparation and compilation dominated:
64 seconds for Ghostty, 109 seconds for native outputs, 46 seconds for the
Swift test build and 28 seconds for the production Swift build. A separate
71-second core job and a Mac handoff added to elapsed time. These cold-run
figures are a baseline, not a claim about the revised or warmed workflow.

The workflow keeps three caches: pinned Ghostty source/framework, macOS
server/library, and Linux server. Keys use actual Zig/Xcode/SDK identities and
relevant source/build hashes; there are no broad fallback keys. Each build
script rechecks input stamps and required outputs after a restore. The
Ghostty restore precedes core tests so they reuse its pinned source checkout
instead of fetching it again on each fresh runner. Tracked source changes
are rejected by the same build validation used locally. The
macOS and Linux stamps are independent, so missing/stale Linux output cannot
force a macOS rebuild or let a macOS-only preparation satisfy packaging.

Restore and save are explicit steps. A successfully prepared artifact is
saved immediately, before downstream Swift failures can discard that work.
Failed preparation never publishes a cache. These are input-provenance
checks, not content-integrity attestations or distributable release artifacts.
The Zig compiler cache is shared by the native steps in the same job.

GitHub's branch cache scope still applies: a PR does not seed the main
branch. The first successful main run seeds caches available to later PRs.
See [cache access restrictions](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching#restrictions-for-accessing-a-cache).
Measure cold and warm runs before adding persistent Swift build caches or
more runner/caching infrastructure.

## Repository policy

The private organization repository has an active **Main protections**
ruleset. Its checked-in [payload](../.github/rulesets/main.json) follows
ask/aft with one stable required gate and a narrower administrator bypass:

- PRs and resolved review threads; squash merging and linear history.
- No branch deletion or force pushes.
- `Required`, from GitHub Actions, with the branch up to date before merging.
- Zero mandatory approvals while there is one maintainer. CODEOWNERS routes
  review requests without making solo work impossible.
- Administrator bypass only through a PR, not unrestricted direct pushes.

The JSON is an importable API payload, not an automatically applied policy.
Check live settings for actual enforcement. A future merge queue needs a
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
the repository deletes its branch so the next update can be proposed. Opening
the PR with the built-in token needs the repository setting **Allow GitHub
Actions to create and approve pull requests**; if creation fails, the publisher
deletes the branch it just pushed so the next run is not blocked.
An observed head change withdraws readiness; required CI still guards merges.

Engine updates also require the full `scripts/koid test` suite on an Apple
silicon Mac with Metal and `scripts/bundle.sh`, at the proposed commit, before
manual merge. Hosted checks do not replace that gate. Review the engine diff
and packaged notices with the test results.

## Release drafts

[Release draft](../.github/workflows/release.yml) is a manual main-branch workflow.
It accepts an existing stable tag matching `build.zig.zon`, requires successful
main CI for that commit (its push run, or a manual run on main when a later
merge cancelled that), and records the maintainer's exact-commit full Metal
suite attestation. Read-only build and test work completes before a separate
job signs the bundle, submits it for notarization, staples the accepted ticket,
and validates an installation extracted into a private directory.

The output is a Developer ID signed archive, checksum file and **draft** GitHub
release. Signing secrets live in the `release` environment, which only the
signing job uses. Missing signing configuration or failed verification stops
the run; a rerun replaces a draft an earlier attempt left behind.
Publication remains a separate maintainer action; the workflow never installs
into Applications or launches the app. Development bundles continue to use the
ordinary `scripts/bundle.sh` signing behavior.

### Dependency inventory

| Boundary | Count | Dependencies |
| --- | --- | --- |
| Direct external product code | 1 | libghostty-vt, pinned in `build-ghostty-vt.sh` |
| Remote Swift packages | 0 | GhosttyVt is locally built; CKoi/libkoi is Koi's own code |
| External libraries used through the pinned VT build | 4 | uucode, Wuffs, SIMDUTF, Highway |
| GitHub Action repositories | 5 | actions/checkout, mlugg/setup-zig, actions/cache (restore/save), actions/upload-artifact, actions/download-artifact |

These categories are not a complete runtime/build bill of materials. The
engine also uses build helpers such as translate-c and includes Unicode/color
data. Zig supplies its standard library and compiler/runtime support; the
Linux target uses musl and LLVM C++ runtimes. Apple SDK frameworks and the
Swift/Xcode toolchain are platform dependencies. Bundled logo artwork has
separate provenance. See [third-party notices](../THIRD_PARTY_NOTICES.md) for
the shipped components and licenses. The full Ghostty application's manifest
lists additional dependencies that Koi's VT-only build does not use.

Next priorities are auditing omitted hosted integration tests and a first
live run of the release workflow's signing and notarization. A merge queue, mandatory second
reviewer, and a new generic build framework add little value for the current
single-maintainer repository.
