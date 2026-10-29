#!/usr/bin/env bash
# Publish a verified pin map as one draft PR; only exact-commit CI can make it ready.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${GITHUB_REPOSITORY:?This publisher runs inside GitHub Actions}"
: "${UPDATE_BASE:?Missing checked base commit}"
if [[ -z "${GH_TOKEN:-}" ]]; then
  echo 'Set WORKFLOW_UPDATES_TOKEN: a fine-grained token for this repository with Contents, Workflows and Pull requests write, plus Actions read. See docs/ci.md.' >&2
  exit 1
fi
branch=chore/action-updates
remote_ref="refs/heads/$branch"
actor=$(gh api user --jq .login)
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
  [[ "$pr_author" == "$actor" ]] || {
    echo 'Update PR belongs to another author; refusing to replace it.' >&2; exit 1;
  }
  [[ -n "$remote_sha" && "$pr_head" == "$remote_sha" ]] || {
    echo 'Update branch does not match its PR; refusing to replace it.' >&2; exit 1;
  }
  foreign=$(gh pr view "$pr_number" --repo "$GITHUB_REPOSITORY" --json commits --jq \
    '.commits[] | select(.messageHeadline != "chore: update Action pins" or (.authors | length) == 0 or any(.authors[]; .login != "github-actions[bot]")) | .oid')
  [[ -z "$foreign" ]] || { echo 'Update PR contains human changes; refusing to replace them.' >&2; exit 1; }
  git fetch --quiet origin "$remote_ref"
  [[ "$(git rev-parse FETCH_HEAD)" == "$remote_sha" ]] || { echo 'Update branch moved during inspection.' >&2; exit 1; }
  old_base=$(git merge-base "$UPDATE_BASE" "$remote_sha")
  python3 scripts/update-actions.py verify-branch "$old_base" "$remote_sha"
fi

# Reconstruct from trusted base files. The transferred map cannot alter YAML structure.
[[ "$(git rev-parse HEAD)" == "$UPDATE_BASE" ]] || { echo 'Unexpected checkout.' >&2; exit 1; }
summary="$RUNNER_TEMP/action-update-summary.md"
python3 scripts/update-actions.py apply > "$summary"
git add -- .github/workflows
git diff --cached --check
[[ -n "$(git diff --cached --name-only)" ]] || { echo 'No pin changes to publish.' >&2; exit 1; }
[[ -z "$(git diff --cached --summary)" ]] || { echo 'Refusing file additions, removals or mode changes.' >&2; exit 1; }
[[ "$(git ls-remote origin refs/heads/main | awk 'NR == 1 { print $1 }')" == "$UPDATE_BASE" ]] || {
  echo 'Main advanced after discovery; rerun the updater.' >&2; exit 1;
}
git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git -c core.hooksPath=/dev/null commit -m 'chore: update Action pins'
# Withdraw readiness before changing an existing PR's head.
if [[ -n "$pr_number" ]] && [[ "$(gh pr view "$pr_number" --repo "$GITHUB_REPOSITORY" --json isDraft --jq .isDraft)" == false ]]; then
  gh pr ready "$pr_number" --repo "$GITHUB_REPOSITORY" --undo
fi
# An empty expected SHA also protects a new branch against concurrent creation.
git push --force-with-lease="$remote_ref:$remote_sha" origin "HEAD:$remote_ref"
sha=$(git rev-parse HEAD)

# A draft tracks failed attempts so the next scheduled run can refresh them.
body="$RUNNER_TEMP/action-update-pr.md"
{
  echo 'Update pinned GitHub Actions within their existing major versions.'
  echo
  cat "$summary"
  echo
  echo "Validation pending for commit $sha. No automatic merge."
} > "$body"
if [[ -z "$pr_number" ]]; then
  gh pr create --repo "$GITHUB_REPOSITORY" --draft --base main --head "$branch" \
    --title 'chore: update Action pins' --body-file "$body"
  pr_number=$(gh pr view "$branch" --repo "$GITHUB_REPOSITORY" --json number --jq .number)
else
  gh pr edit "$pr_number" --repo "$GITHUB_REPOSITORY" --body-file "$body"
fi

# The PAT-created PR already triggers CI. Watch that merge test, avoiding a second full build.
run_id=''
for _ in $(seq 1 30); do
  run_id=$(gh run list --repo "$GITHUB_REPOSITORY" --workflow ci.yml --branch "$branch" --event pull_request \
    --limit 30 --json databaseId,headSha,createdAt --jq \
    "[.[] | select(.headSha == \"$sha\")] | sort_by(.createdAt) | last | .databaseId // empty")
  [[ -n "$run_id" ]] && break
  sleep 2
done
[[ -n "$run_id" ]] || { echo 'No PR CI run found for this commit; leaving the PR draft.' >&2; exit 1; }
# REST polling supports fine-grained PATs; gh run watch does not.
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
{
  echo
  echo "CI passed for $sha: https://github.com/$GITHUB_REPOSITORY/actions/runs/$run_id"
} >> "$body"
gh pr edit "$pr_number" --repo "$GITHUB_REPOSITORY" --body-file "$body"
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
