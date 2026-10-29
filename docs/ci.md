# CI and repository maintenance

Koi borrows the shared `./x` command interface from
[ask](https://github.com/arocomputer/ask/blob/main/x) and
[aft](https://github.com/arocomputer/aft/blob/main/x). Commands remain small
wrappers around Koi's existing build and isolated test scripts. `./x check`
runs all local checks; it requires an Apple silicon Mac with Metal. Hosted
Actions uses the individual commands described below.

## Runners

The repository is [arocomputer/koi](https://github.com/arocomputer/koi).
Transferring ownership preserved its history, open PRs and active main-branch
ruleset. Local clones should use the organization URL:

```sh
git remote set-url origin https://github.com/arocomputer/koi.git
```

CI and Action-update jobs use the organization's Namespace integration.
Runner labels keep the configuration in the workflows, without dashboard
profiles or a Namespace token in repository secrets:

| Jobs | `runs-on` label |
| --- | --- |
| Selection, script/catalog checks, final gate and Action updates | `nscloud-ubuntu-24.04-amd64-2x4` |
| Native tests and packaging | `nscloud-macos-tahoe-arm64-6x14` |

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
IDs and the `CI required` gate unchanged so branch protection continues to
work. Validate a PR run before merging a runner change. Do not disable or
weaken required checks to work around a queued or failing runner.

## Checks and selection

The [workflow](../.github/workflows/ci.yml) runs on PRs, main pushes and manual
requests. It has three jobs:

| Job | Work |
| --- | --- |
| Portable checks | Complete PR diff, script regressions and catalog validation on Linux |
| Native checks | Selected core tests, optimized Swift tests and/or packaging on one Mac |
| CI required | Require the portable job and every selected native step to pass |

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

Hosted Swift tests run in release mode through the isolated runner. They
include existing private-server checks for session persistence, command/watch
round trips, the stdio relay, link authentication and link lifetime. They
exclude benchmarks and the rest of the serialized UI/GPU fixtures; use
focused local tests for those changes. The entire test target still compiles.

Routine Swift PRs do not cross-compile a Linux server or assemble a signed
bundle. Release-mode tests exercise optimized Swift; production packaging
still runs for relevant changes and on main. SwiftPM can recompile when
changing testability flags, so release tests do not promise a reusable
production binary. Linux is cross-compiled for packaging, not executed as a
native Linux test lane.

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

## Caches and performance

The first successful Namespace run took about eight minutes. Its 105 selected
Swift tests executed in 0.275 seconds; preparation and compilation dominated:
64 seconds for Ghostty, 109 seconds for native outputs, 46 seconds for the
Swift test build and 28 seconds for the production Swift build. A separate
71-second core job and a Mac handoff added to elapsed time. These cold-run
figures are a baseline, not a claim about the revised or warmed workflow.

The workflow keeps three completed-output caches: Ghostty, macOS
server/library, and Linux server. Keys use actual Zig/Xcode/SDK identities and
relevant source/build hashes; there are no broad fallback keys. Each build
script rechecks input stamps and required outputs after a restore. The
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
- `CI required`, from GitHub Actions, with the branch up to date before merging.
- Zero mandatory approvals while there is one maintainer. CODEOWNERS routes
  review requests without making solo work impossible.
- Administrator bypass only through a PR, not unrestricted direct pushes.

The JSON is an importable API payload, not an automatically applied policy.
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
| GitHub Action repositories | 3 | actions/checkout, mlugg/setup-zig, actions/cache (restore/save) |

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
