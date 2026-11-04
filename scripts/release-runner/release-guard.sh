#!/bin/bash
# Job-started hook for the release-only runner. Fails closed: only a manual
# dispatch of release.yml on main in diamondplated/mac-apps by the owner runs.
set -u
want_repo=diamondplated/mac-apps
want_wf="$want_repo/.github/workflows/release.yml@refs/heads/main"
actor=${GITHUB_TRIGGERING_ACTOR:-${GITHUB_ACTOR:-}}
reject() {
    echo "release-runner guard: refusing job ($*)" >&2
    # None of these are secret; printing them makes a lockout debuggable.
    echo "  saw repository=${GITHUB_REPOSITORY:-unset} event=${GITHUB_EVENT_NAME:-unset} ref=${GITHUB_REF:-unset}" >&2
    echo "  saw workflow_ref=${GITHUB_WORKFLOW_REF:-unset} actor=${actor:-unset}" >&2
    exit 1
}
[ "${GITHUB_REPOSITORY:-}" = "$want_repo" ] || reject "repository=${GITHUB_REPOSITORY:-unset}"
[ "${GITHUB_EVENT_NAME:-}" = workflow_dispatch ] || reject "event=${GITHUB_EVENT_NAME:-unset}"
[ "${GITHUB_REF:-}" = refs/heads/main ] || reject "ref=${GITHUB_REF:-unset}"
[ "${GITHUB_WORKFLOW_REF:-}" = "$want_wf" ] || reject "workflow=${GITHUB_WORKFLOW_REF:-unset}"
[ "$actor" = diamondplated ] || reject "actor=${actor:-unset}"
echo "release-runner guard: allowed release.yml on main, dispatched by $actor"
