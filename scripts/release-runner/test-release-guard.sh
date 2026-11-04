#!/bin/bash
# Checks that the release runner's job-started guard admits only a dispatch of
# release.yml on main by the owner, and fails closed on anything else.
set -u
guard="$(cd "$(dirname "$0")" && pwd)/release-guard.sh"
ok=diamondplated/mac-apps/.github/workflows/release.yml@refs/heads/main
failures=0
run() { env -i PATH="$PATH" "$@" bash "$guard" >/dev/null 2>&1; }
expect() {
    local want=$1 name=$2; shift 2
    run "$@"; local rc=$?
    if { [ "$want" = allow ] && [ $rc -eq 0 ]; } || { [ "$want" = deny ] && [ $rc -ne 0 ]; }; then
        echo "ok   $name"
    else
        echo "FAIL $name (rc=$rc)"; failures=$((failures + 1))
    fi
}
base=(GITHUB_REPOSITORY=diamondplated/mac-apps GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/main "GITHUB_WORKFLOW_REF=$ok" GITHUB_TRIGGERING_ACTOR=diamondplated)
expect allow "owner dispatch of release.yml on main" "${base[@]}"
expect allow "falls back to GITHUB_ACTOR" GITHUB_REPOSITORY=diamondplated/mac-apps GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/main "GITHUB_WORKFLOW_REF=$ok" GITHUB_ACTOR=diamondplated
expect deny "empty environment"
expect deny "pull_request event" "${base[@]}" GITHUB_EVENT_NAME=pull_request
expect deny "pull_request_target event" "${base[@]}" GITHUB_EVENT_NAME=pull_request_target
expect deny "push event" "${base[@]}" GITHUB_EVENT_NAME=push
expect deny "branch ref" "${base[@]}" GITHUB_REF=refs/heads/feature
expect deny "other workflow on main" "${base[@]}" GITHUB_WORKFLOW_REF=diamondplated/mac-apps/.github/workflows/ci.yml@refs/heads/main
expect deny "release.yml from a branch" "${base[@]}" GITHUB_WORKFLOW_REF=diamondplated/mac-apps/.github/workflows/release.yml@refs/heads/feature
expect deny "other repository" "${base[@]}" GITHUB_REPOSITORY=someone/mac-apps
expect deny "other actor" "${base[@]}" GITHUB_TRIGGERING_ACTOR=someone-else
[ $failures -eq 0 ] && echo "release guard: all cases pass" || { echo "release guard: $failures failing"; exit 1; }
