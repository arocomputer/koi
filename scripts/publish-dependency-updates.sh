#!/usr/bin/env bash
# Publish a verified Ghostty pin as one draft PR; only exact-commit CI can make it ready.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${GITHUB_REPOSITORY:?This publisher runs inside GitHub Actions}"
: "${UPDATE_BASE:?Missing checked base commit}"
if [[ -z "${GH_TOKEN:-}" ]]; then
  echo 'Missing workflow token.' >&2
  exit 1
fi
branch=chore/dependency-updates
remote_ref="refs/heads/$branch"
gh auth setup-git

# Inspect ownership before touching an existing automation branch or PR.
prs=$(gh pr list --repo "$GITHUB_REPOSITORY" --state open --base main --head "$branch" --json number,author,headRefOid)
read -r pr_count pr_number pr_author pr_head < <(python3 -c '
import json, sys
prs = json.load(sys.stdin)
pr = prs[0] if prs else {}
print(len(prs), pr.get("number", "-"), pr.get("author", {}).get("login", "-"), pr.get("headRefOid", "-"))
' <<< "$prs")
[[ "$pr_number" != - ]] || pr_number=''
remote_sha=$(git ls-remote origin "$remote_ref" | awk 'NR == 1 { print $1 }')
if [[ "$pr_count" -gt 1 ]] || [[ "$pr_count" -eq 0 && -n "$remote_sha" ]]; then
  echo 'Reserved update branch has ambiguous ownership; refusing to replace it.' >&2
  exit 1
fi
if [[ -n "$pr_number" ]]; then
  [[ "$pr_author" == "github-actions[bot]" || "$pr_author" == "app/github-actions" ]] || {
    echo 'Update PR belongs to another author; refusing to replace it.' >&2; exit 1;
  }
  [[ -n "$remote_sha" && "$pr_head" == "$remote_sha" ]] || {
    echo 'Update branch does not match its PR; refusing to replace it.' >&2; exit 1;
  }
  echo "Dependency PR #$pr_number is already open; leaving its commits and description unchanged."
  exit 0
fi

# Reconstruct only the Ghostty pin from the checked base.
[[ "$(git rev-parse HEAD)" == "$UPDATE_BASE" ]] || { echo 'Unexpected checkout.' >&2; exit 1; }
summary="$RUNNER_TEMP/dependency-update-summary.md"
python3 scripts/update-dependencies.py apply > "$summary"
git add -- scripts/build-ghostty-vt.sh
git diff --cached --check
[[ -n "$(git diff --cached --name-only)" ]] || { echo 'No pin changes to publish.' >&2; exit 1; }
[[ -z "$(git diff --cached --summary)" ]] || { echo 'Refusing file additions, removals or mode changes.' >&2; exit 1; }
[[ "$(git ls-remote origin refs/heads/main | awk 'NR == 1 { print $1 }')" == "$UPDATE_BASE" ]] || {
  echo 'Main advanced after discovery; rerun the updater.' >&2; exit 1;
}
git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git -c core.hooksPath=/dev/null commit -m 'chore: update dependencies'
# Only create a branch observed to be absent; never refresh an existing PR.
git push --force-with-lease="$remote_ref:" origin "HEAD:$remote_ref"
sha=$(git rev-parse HEAD)

# A failed validation remains a draft for maintainer review.
body="$RUNNER_TEMP/dependency-update-pr.md"
{
  echo 'Update the pinned Ghostty engine to a forward stable release.'
  echo
  cat "$summary"
  echo
  echo "Validation pending for commit $sha. Full Metal/AppKit tests on this commit remain required before manual merge."
} > "$body"
gh pr create --repo "$GITHUB_REPOSITORY" --draft --base main --head "$branch" \
  --title 'chore: update dependencies' --body-file "$body"
pr_number=$(gh pr view "$branch" --repo "$GITHUB_REPOSITORY" --json number --jq .number)

# Dispatch resolves a branch, so recheck it and accept only a run at our commit.
[[ "$(git ls-remote origin "$remote_ref" | awk 'NR == 1 { print $1 }')" == "$sha" ]] || {
  echo 'Update branch moved before CI dispatch; leaving it draft.' >&2; exit 1;
}
# Bot pushes do not start CI; explicitly dispatch the read-only workflow.
gh workflow run ci.yml --repo "$GITHUB_REPOSITORY" --ref "$branch"
run_id=''
for _ in $(seq 1 30); do
  run_id=$(gh run list --repo "$GITHUB_REPOSITORY" --workflow ci.yml --branch "$branch" --event workflow_dispatch \
    --limit 30 --json databaseId,headSha,createdAt --jq \
    "[.[] | select(.headSha == \"$sha\")] | sort_by(.createdAt) | last | .databaseId // empty")
  [[ -n "$run_id" ]] && break
  sleep 2
done
[[ -n "$run_id" ]] || { echo 'No dispatched CI run found for this commit; leaving the PR draft.' >&2; exit 1; }
# Poll the run for this exact commit using the built-in workflow token.
ci_state=''
for _ in $(seq 1 300); do
  read -r checked_sha ci_state ci_conclusion < <(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$run_id" \
    --jq '[.head_sha, .status, (.conclusion // "-")] | @tsv')
  [[ "$checked_sha" == "$sha" ]] || { echo 'CI run belongs to another commit.' >&2; exit 1; }
  if [[ "$ci_state" == completed ]]; then
    [[ "$ci_conclusion" == success ]] || { echo "CI finished with $ci_conclusion; leaving the PR draft." >&2; exit 1; }
    break
  fi
  sleep 10
done
[[ "$ci_state" == completed ]] || { echo 'Timed out waiting for CI; leaving the PR draft.' >&2; exit 1; }
# Keep the original body untouched: maintainers may have added notes during CI.
echo "CI passed for $sha: https://github.com/$GITHUB_REPOSITORY/actions/runs/$run_id"
[[ "$(gh pr view "$pr_number" --repo "$GITHUB_REPOSITORY" --json headRefOid --jq .headRefOid)" == "$sha" ]] || {
  echo 'PR changed during validation; leaving it draft.' >&2; exit 1;
}
gh pr ready "$pr_number" --repo "$GITHUB_REPOSITORY"
# GitHub readiness has no atomic expected-head parameter. Correct any observed race;
# required CI remains the merge guard for pushes after this final observation.
if [[ "$(gh pr view "$pr_number" --repo "$GITHUB_REPOSITORY" --json headRefOid --jq .headRefOid)" != "$sha" ]]; then
  gh pr ready "$pr_number" --repo "$GITHUB_REPOSITORY" --undo
  echo 'PR changed while marking it ready; readiness withdrawn.' >&2
  exit 1
fi
