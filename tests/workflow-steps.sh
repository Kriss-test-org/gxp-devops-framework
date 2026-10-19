#!/bin/bash
# Workflow step tests: runs the `run:` steps of gxp-release.yml with test inputs and checks that they
# accept valid input and reject what they are meant to block. Steps that call the GitHub API, the
# OIDC endpoint, Docker or the container registry are covered by end-to-end runs, not here.
# Needs bash, git, jq, yq (mikefarah v4), python3, zip and GNU coreutils/findutils.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WF=$ROOT/.github/workflows/gxp-release.yml
APP=$ROOT/tests/fixtures/app
pass=0; fail=0
# Keep git settings for the test repositories away from the user's global configuration.
GIT_CONFIG_GLOBAL=$(mktemp)
export GIT_CONFIG_GLOBAL
git config --global user.email test@example.com
git config --global user.name tester
git config --global init.defaultBranch main

step() { yq -r "(.jobs.$1.steps[] | select(.name == \"$2\")).run" "$WF"; }
expect() { # expect <exit-code> <label> <command...>
  local want=$1 label=$2; shift 2
  local out; out=$("$@" 2>&1); local got=$?
  if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "PASS  $label"
  else fail=$((fail+1)); echo "FAIL  $label (exit $got, wanted $want)"; echo "$out" | sed 's/^/      /' | tail -20; fi
}
fresh() {
  RUNNER_TEMP=$(mktemp -d); GITHUB_OUTPUT=$(mktemp); GITHUB_STEP_SUMMARY=$(mktemp)
  export RUNNER_TEMP GITHUB_OUTPUT GITHUB_STEP_SUMMARY
  mkdir -p "$RUNNER_TEMP/gxp-intake"
}
export GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=Kriss-test-org/gxp-demo-app GITHUB_RUN_ID=1001 GITHUB_RUN_ATTEMPT=1 GITHUB_ACTOR=alice

# Application repository: main with release v0.1.0 (and an old rc tag on the same commit), stage two commits ahead.
rm -rf /tmp/repo && cp -r "$APP" /tmp/repo && cd /tmp/repo && git init -q && git add -A && git commit -qm base
git tag v0.1.0-rc.2 && git tag v0.1.0
git update-ref refs/remotes/origin/main HEAD
git switch -q -c stage
echo change > change.txt && git add change.txt && git commit -qm "Show the limits"
git commit -q --allow-empty -m "Merge pull request #2 from develop"
STAGE_TIP=$(git rev-parse HEAD)

echo "== Candidate"
CAND_STEP=$(step intake 'Collect the candidate')
cand() { env STAGE=stage PRODUCTION=main DIR="$RUNNER_TEMP/gxp-intake" GITHUB_REF="$1" bash -c "$CAND_STEP"; }
fresh; expect 0 "candidate collected from stage" cand refs/heads/stage
jq -c '{base_tag, commits: (.commits | length)}' "$RUNNER_TEMP/gxp-intake/candidate.json" | sed 's/^/      /'
expect 0 "previous release is v0.1.0, not an rc tag" jq -e '.base_tag == "v0.1.0"' "$RUNNER_TEMP/gxp-intake/candidate.json"
fresh; expect 1 "push to another branch rejected" cand refs/heads/develop
git switch -q main && git commit -q --allow-empty -m "hotfix on main" && git update-ref refs/remotes/origin/main HEAD && git switch -q stage
fresh; expect 1 "stage missing commits of main rejected" cand refs/heads/stage
git update-ref refs/remotes/origin/main "$STAGE_TIP"
fresh; expect 1 "nothing new on stage rejected" cand refs/heads/stage
git update-ref refs/remotes/origin/main v0.1.0

echo "== Decide what the release contains"
DECIDE_STEP=$(step intake 'Decide what the release contains')
D=/tmp/decide; rm -rf "$D"; mkdir -p "$D"
jq -n '{commit: "c2", base_tag: "v0.1.0", stage_branch: "stage", production_branch: "main",
        commits: [{sha: "c1aaaaaaaa", subject: "Show the limits"}, {sha: "c2bbbbbbbb", subject: "Merge pull request #2"}]}' > "$D/candidate.base.json"
jq -n '{
  commits: [{sha: "c1aaaaaaaa", subject: "Show the limits", pull_requests: [2]}, {sha: "c2bbbbbbbb", subject: "Merge pull request #2", pull_requests: [2]}],
  pull_requests: {"2": {number: 2, title: "Show the limits", url: "u/pull/2", author: "alice", merged_by: "alice",
    merged_at: "2026-10-20T10:00:00Z", head_sha: "h2", base: "stage", head: "develop", linked_issues: [1],
    commit_authors: ["alice"], reviews: [{login: "bob", state: "APPROVED", commit_id: "h2", submitted_at: "2026-10-20T09:00:00Z", url: "r"}]}},
  issues: {"1": {type: "Issue", number: 1, title: "Show the specification limits", url: "u/issues/1", state: "OPEN",
    requester: "alice", created_at: "2026-10-19T08:00:00Z", last_edited_at: null, body_sha256: "abc",
    comments: [{id: 11, url: "c11", author: "bob", created_at: "2026-10-19T09:00:00Z", last_edited_at: null,
      body: "/approve\nimpact: low\npath: targeted\ntype: feature\nrequirements: URS-005, URS-001\nreason: Display-only change"}]}}
}' > "$D/data.base.json"
# decide <label> <exit> [jq filter for intake data] [jq filter for the candidate]
decide() {
  local label=$1 want=$2 data_filter=${3:-.} cand_filter=${4:-.}
  fresh; local dir="$RUNNER_TEMP/gxp-intake"
  jq "$data_filter" "$D/data.base.json" > "$dir/intake-data.json"
  jq "$cand_filter" "$D/candidate.base.json" > "$dir/candidate.json"
  expect "$want" "$label" env DIR="$dir" PRODUCTION=main RUN_NUMBER=57 bash -c "$DECIDE_STEP"
}
printf 'schema: gxp-roles/v2\nchange_approvers: [bob]\nverifiers: [alice]\nrelease_approvers: [bob]\n' > .gxp/roles.yml
git switch -q main && git add .gxp/roles.yml && git commit -qm roles && git tag -f v0.1.0 >/dev/null && git update-ref refs/remotes/origin/main HEAD && git switch -q stage

decide "approved feature becomes 0.2.0-rc.57" 0
grep -E '^(version|label|code_authors)=' "$GITHUB_OUTPUT" | tr '\n' ' ' | sed 's/^/      /'; echo
expect 0 "scope records impact, path and requirements" jq -e \
  '.gxp_impact == "low" and .validation_path == "targeted" and .impacted_requirements == ["URS-001","URS-005"] and .change_requests[0].approved_by == "bob"' \
  "$RUNNER_TEMP/gxp-intake/change-requests.json"
APPROVAL='.issues["1"].comments[0].body'
decide "fix becomes 0.1.1" 0 "$APPROVAL |= sub(\"type: feature\"; \"type: fix\")"
grep -q '^version=0.1.1$' "$GITHUB_OUTPUT" || { fail=$((fail+1)); echo "FAIL  fix version is 0.1.1"; }
decide "breaking change becomes 1.0.0" 0 "$APPROVAL |= sub(\"type: feature\"; \"type: breaking\")"
grep -q '^version=1.0.0$' "$GITHUB_OUTPUT" || { fail=$((fail+1)); echo "FAIL  breaking version is 1.0.0"; }
decide "first release of a feature is 0.1.0" 0 . '.base_tag = ""'
grep -q '^version=0.1.0$' "$GITHUB_OUTPUT" || { fail=$((fail+1)); echo "FAIL  first version is 0.1.0"; }
decide "commit without a pull request rejected" 1 '.commits[0].pull_requests = []'
decide "pull request without a change request rejected" 1 '.pull_requests["2"].linked_issues = []'
decide "pull request without code review rejected" 1 '.pull_requests["2"].reviews = []'
decide "code review by the code author rejected" 1 '.pull_requests["2"].reviews[0].login = "alice"'
decide "code review of an earlier commit rejected" 1 '.pull_requests["2"].reviews[0].commit_id = "old"'
decide "change request without approval rejected" 1 '.issues["1"].comments = []'
decide "approval by the requester rejected" 1 '.issues["1"].requester = "bob"'
decide "approval by someone not listed rejected" 1 '.issues["1"].comments[0].author = "mallory"'
decide "edited approval comment rejected" 1 '.issues["1"].comments[0].last_edited_at = "2026-10-19T09:30:00Z"'
decide "request edited after approval rejected" 1 '.issues["1"].last_edited_at = "2026-10-19T10:00:00Z"'
decide "request edited before approval accepted" 0 '.issues["1"].last_edited_at = "2026-10-19T08:30:00Z"'
decide "high impact with targeted path rejected" 1 "$APPROVAL |= sub(\"impact: low\"; \"impact: high\")"
decide "approval without reason rejected" 1 "$APPROVAL |= sub(\"\\nreason: Display-only change\"; \"\")"
REJECT='{id: 12, url: "c12", author: "bob", created_at: "2026-10-19T09:10:00Z", last_edited_at: null, body: "/reject not now"}'
decide "rejected after approval rejected" 1 ".issues[\"1\"].comments += [$REJECT]"
decide "approved again after rejection accepted" 0 ".issues[\"1\"].comments = [$REJECT] + .issues[\"1\"].comments"
decide "closed change request rejected" 1 '.issues["1"].state = "CLOSED"'
decide "reference to a pull request rejected" 1 '.issues["1"] = {type: "PullRequest"}'
git switch -q main && printf 'schema: gxp-roles/v1\napprovers: [bob]\n' > .gxp/roles.yml && git commit -qam "old roles" && git update-ref refs/remotes/origin/main HEAD && git switch -q stage
decide "old roles schema rejected" 1
git update-ref refs/remotes/origin/main main~1

echo "== Unit test summary"
UT_STEP=$(step unit-tests 'Summarise results and requirement coverage')
mkdir -p /tmp/tr && cat > /tmp/tr/unit-tests.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<testsuites>
  <testcase name="[URS-001] inside is PASS" time="0.1" classname="test"/>
  <testcase name="[URS-005] limits are shown" time="0.1" classname="test"><failure message="boom"/></testcase>
  <testcase name="helper works" time="0.1" classname="test"/>
</testsuites>
XML
fresh; expect 1 "failing test stops the release" env RESULTS=/tmp/tr bash -c "$UT_STEP"
sed -i 's#<failure message="boom"/>##' /tmp/tr/unit-tests.xml
fresh; expect 0 "passing tests summarised per requirement" env RESULTS=/tmp/tr bash -c "$UT_STEP"
rm -rf /tmp/empty && mkdir -p /tmp/empty
fresh; expect 1 "missing test results stop the release" env RESULTS=/tmp/empty bash -c "$UT_STEP"

echo "== Evidence pack"
decide "scope for the evidence pack" 0
SCOPE="$RUNNER_TEMP/gxp-intake"
fresh; EV=$RUNNER_TEMP/evidence; mkdir -p "$EV"/gxp-intake "$EV"/gxp-build "$EV"/gxp-unit-tests "$EV"/gxp-staging
cp "$SCOPE/candidate.json" "$SCOPE/change-requests.json" "$EV"/gxp-intake/
echo '{"version":"v0.2.0-beta.1","workflow_ref":"Kriss-test-org/gxp-devops-framework/.github/workflows/gxp-release.yml@refs/tags/v0.2.0-beta.1","workflow_sha":"abc","prerelease":true}' > "$EV"/gxp-intake/framework.json
echo '{"image":"ghcr.io/kriss-test-org/gxp-demo-app","digest":"sha256:1111","reference":"ghcr.io/kriss-test-org/gxp-demo-app@sha256:1111","tags":["0.2.0-rc.57","sha-x"],"build_id":"1001.1","built_at":"t","dockerfile_sha256":"d"}' > "$EV"/gxp-build/build.json
cp /tmp/tr/unit-tests.json "$EV"/gxp-unit-tests/
echo '{"environment":"staging","reference":"r","result":"pass","checked_at":"t","checks":[{"check":"a","result":"pass","detail":"d"}]}' > "$EV"/gxp-staging/checks.json
EV_STEP=$(step evidence 'Assemble the release candidate record')
expect 0 "release candidate record assembled" env EVIDENCE="$EV" VERSION=0.2.0 TAG=0.2.0-rc.57 COMMIT="$STAGE_TIP" \
  STAGING_CONFIG=deploy/staging.env PRODUCTION_CONFIG=deploy/production.env bash -c "$EV_STEP"
expect 0 "record lists change requests, pull requests and code authors" jq -e \
  '.release.candidate == "0.2.0-rc.57" and .release.previous_release == "v0.1.0" and .impact_assessment.change_requests[0].number == 1
   and .pull_requests[0].number == 2 and .code_authors == ["alice"] and .evidence_artifact == "gxp-evidence-0.2.0-rc.57"' "$EV"/release-candidate.json
expect 0 "every evidence file listed in SHA256SUMS" bash -c "cd '$EV' && sha256sum --check --quiet SHA256SUMS"

echo "== Release record and report"
REC_STEP=$(step record 'Assemble the release record')
fresh; R=$RUNNER_TEMP/release; mkdir -p "$R"/gxp-verification "$R"/gxp-production
cp -r "$EV" "$R"/gxp-evidence-0.2.0-rc.57
echo '{"verifier":"alice","reference":"TR-0042","comment":"PASS TR-0042","state":"approved"}' > "$R"/gxp-verification/verification.json
echo '{"approver":"bob","comment":"","approved_before":"t","state":"approved"}' > "$R"/gxp-production/approval.json
echo '{"environment":"production","result":"pass","checked_at":"t","checks":[]}' > "$R"/gxp-production/checks.json
expect 0 "release record assembled" env DIR="$R" VERSION=0.2.0 TAG=0.2.0-rc.57 bash -c "$REC_STEP"
expect 0 "record is released with tag v0.2.0" jq -e '.schema == "gxp-release-record/v2" and .release_tag == "v0.2.0" and .production_approval.approver == "bob"' "$R"/release-record.json
echo '{"jobs":[{"name":"Release / 1 · Release intake","conclusion":"success","started_at":"2026-10-20T12:00:00Z","completed_at":"2026-10-20T12:00:10Z"},{"name":"Release / 8 · Release 0.2.0","conclusion":null,"started_at":"2026-10-20T12:05:00Z","completed_at":null}]}' > "$R"/run-jobs.json
PAGE_STEP=$(step record 'Generate the release report page')
expect 0 "release report page generated" env DIR="$R" PACK=gxp-evidence-0.2.0-rc.57 bash -c "$PAGE_STEP"
expect 0 "report shows change request, code review, verification and digest" bash -c "
  grep -q 'Show the specification limits' '$R/release-report.html' && grep -q 'Code review of' '$R/release-report.html' &&
  grep -q 'PASS TR-0042' '$R/release-report.html' && grep -q 'sha256:1111' '$R/release-report.html' &&
  grep -q 'in progress (this job)' '$R/release-report.html' && grep -q 'not suitable for GxP use' '$R/release-report.html'"
fresh; R2=$RUNNER_TEMP/release; cp -r "$R" "$R2"; rm -f "$R2"/release-record.json
echo tampered >> "$R2"/gxp-evidence-0.2.0-rc.57/gxp-staging/checks.json
expect 1 "tampered evidence stops the release" env DIR="$R2" VERSION=0.2.0 TAG=0.2.0-rc.57 bash -c "$REC_STEP"

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
