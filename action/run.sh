#!/usr/bin/env bash
# Runs upkeep for the GitHub Action.
#
# scan:   writes a Markdown job summary and a JSON report, then exits with
#         upkeep's own exit code so the job fails on blocking findings.
# fix-pr: applies the automatic fixes and opens or updates a pull request whose
#         body is the fix plan, including the to-dos that still need a person.
#         Only exit code 2 (could not run, refused, rolled back) fails the job:
#         to-dos are the pull request's content, not a failure.
set -uo pipefail

path="${UPKEEP_PATH:-.}"
command="${UPKEEP_COMMAND:-scan}"
branch="${UPKEEP_BRANCH:-upkeep/fixes}"
report="${RUNNER_TEMP:-/tmp}/upkeep-report.json"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
strict=()
[[ "${UPKEEP_FAIL_ON_AT_RISK:-false}" == "true" ]] && strict=(--fail-on-at-risk)

echo "report=$report" >> "$GITHUB_OUTPUT"

# Surfaces a failure as a workflow annotation, where it is visible without
# opening the log.
fail() {
  echo "::error title=upkeep::$1"
  echo "exit-code=${2:-2}" >> "$GITHUB_OUTPUT"
  exit "${2:-2}"
}

# Runs a command; on failure, reports its last output lines as an annotation.
must() {
  local out
  if ! out="$("$@" 2>&1)"; then
    echo "$out"
    fail "$(printf '%s' "$*" | head -c 80) failed: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
  fi
  echo "$out"
}

case "$command" in
  scan)
    upkeep scan -p "$path" --format markdown "${strict[@]}" >> "$summary"
    upkeep scan -p "$path" --format json "${strict[@]}" > "$report"
    jq -e '.schemaVersion' "$report" > /dev/null || fail "upkeep did not produce a valid JSON report"
    upkeep scan -p "$path" --no-color "${strict[@]}"
    code=$?
    echo "exit-code=$code" >> "$GITHUB_OUTPUT"
    exit "$code"
    ;;

  fix-pr)
    body="${RUNNER_TEMP:-/tmp}/upkeep-pr.md"
    base="$(git rev-parse --abbrev-ref HEAD)"

    must git switch -C "$branch"

    # The plan names every file an automatic fix touches. Only those are
    # committed, so nothing else in the workspace can leak into the pull request.
    upkeep fix -p "$path" --format json > "$report" || true
    # An unreadable plan must never read as "nothing to fix".
    jq -e '.schemaVersion' "$report" > /dev/null || fail "upkeep did not produce a valid fix plan: $(head -c 200 "$report")"
    mapfile -t files < <(jq -r '.automatic[].file' "$report")

    upkeep fix --apply -p "$path" --format markdown > "$body"
    code=$?
    echo "exit-code=$code" >> "$GITHUB_OUTPUT"
    cat "$body" >> "$summary"

    if [[ "$code" == "2" ]]; then
      cat "$body"
      fail "upkeep fix --apply did not complete: $(grep -v '^#' "$body" | tr '\n' ' ' | head -c 300)"
    fi

    changed=()
    for file in "${files[@]}"; do
      [[ -n "$file" ]] && changed+=("$path/$file")
    done
    # pub regenerates the lockfile; it belongs in the commit only if the
    # repository already tracks it.
    if git ls-files --error-unmatch "$path/pubspec.lock" > /dev/null 2>&1; then
      changed+=("$path/pubspec.lock")
    fi

    if [[ ${#changed[@]} -eq 0 ]] || git diff --quiet -- "${changed[@]}"; then
      echo "upkeep found nothing it could change automatically."
      exit 0
    fi

    git config user.name "upkeep[bot]"
    git config user.email "upkeep-bot@users.noreply.github.com"
    must git add -- "${changed[@]}"
    must git commit -m "Apply upkeep fixes" -m "$(head -c 60000 "$body")"
    must git push --force origin "$branch"

    title="upkeep: dependency and build fixes"
    # Command substitutions run in a subshell, where fail() cannot end the
    # script, so these two check their own status.
    if ! existing="$(gh pr list --head "$branch" --state open --json url --jq '.[0].url' 2>&1)"; then
      fail "gh pr list failed: $existing"
    fi
    if [[ -n "$existing" ]]; then
      must gh pr edit "$existing" --body-file "$body" > /dev/null
      url="$existing"
    else
      if ! created="$(gh pr create --base "$base" --head "$branch" --title "$title" --body-file "$body" 2>&1)"; then
        fail "gh pr create failed: $(printf '%s' "$created" | tail -n 3 | tr '\n' ' ')"
      fi
      url="$(printf '%s' "$created" | tail -n 1)"
    fi
    echo "pull-request=$url" >> "$GITHUB_OUTPUT"
    echo "Pull request: $url"
    exit 0
    ;;

  *)
    echo "upkeep action: unknown command '$command'. Use scan or fix-pr." >&2
    echo "exit-code=2" >> "$GITHUB_OUTPUT"
    exit 2
    ;;
esac
