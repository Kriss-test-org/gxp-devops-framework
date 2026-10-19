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
export GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=Kriss-test-org/gxp-demo-app GITHUB_RUN_ID=1001 GITHUB_RUN_ATTEMPT=1

# Application repository with the impact assessment committed on main.
rm -rf /tmp/repo && cp -r "$APP" /tmp/repo && cd /tmp/repo && git init -q && git add -A && git commit -qm base
COMMIT=$(git rev-parse HEAD); export COMMIT
git update-ref refs/remotes/origin/main HEAD

echo "== Release candidate tag"
TAG_STEP=$(step intake 'Check the release candidate tag')
tag_env() { env GITHUB_REF_TYPE=tag GITHUB_REF_NAME="$1" GITHUB_SHA="$2" DEFAULT_BRANCH=main bash -c "$TAG_STEP"; }
git tag v0.1.0-rc.1
fresh; expect 0 "valid candidate tag accepted" tag_env v0.1.0-rc.1 "$COMMIT"
grep -q '^image=ghcr.io/kriss-test-org/gxp-demo-app$' "$GITHUB_OUTPUT" && echo "      image name lower-cased"
fresh; expect 1 "tag without -rc.N rejected" tag_env v0.1.0 "$COMMIT"
git switch -q -c side && git commit -q --allow-empty -m "not on main" && SIDE=$(git rev-parse HEAD) && git switch -q main
fresh; expect 1 "commit not on main rejected" tag_env v0.1.0-rc.2 "$SIDE"
git tag v0.1.0 "$COMMIT"
fresh; expect 1 "already released version rejected" tag_env v0.1.0-rc.1 "$COMMIT"
git tag -d v0.1.0 >/dev/null

echo "== Impact assessment"
IA_STEP=$(step intake 'Validate the impact assessment')
fresh; expect 0 "valid impact assessment accepted" env VERSION=0.1.0 bash -c "$IA_STEP"
fresh; expect 1 "missing impact assessment rejected" env VERSION=9.9.9 bash -c "$IA_STEP"
cp validation/0.1.0/impact-assessment.yml /tmp/ia.bak
yq -i '.validation_path = "targeted"' validation/0.1.0/impact-assessment.yml
fresh; expect 1 "high impact with targeted path rejected" env VERSION=0.1.0 bash -c "$IA_STEP"
cp /tmp/ia.bak validation/0.1.0/impact-assessment.yml
yq -i 'del(.change_control_id)' validation/0.1.0/impact-assessment.yml
fresh; expect 1 "missing change control ID rejected" env VERSION=0.1.0 bash -c "$IA_STEP"
cp /tmp/ia.bak validation/0.1.0/impact-assessment.yml

echo "== Roles"
ROLES_STEP=$(step intake 'Check that the initiator may start releases')
fresh; expect 1 "placeholder roles rejected" env INITIATOR=alice bash -c "$ROLES_STEP"
printf 'schema: gxp-roles/v1\ninitiators: [alice]\nverifiers: [alice]\napprovers: [bob]\n' > .gxp/roles.yml
fresh; expect 0 "listed initiator accepted" env INITIATOR=alice bash -c "$ROLES_STEP"
fresh; expect 1 "unlisted initiator rejected" env INITIATOR=mallory bash -c "$ROLES_STEP"
printf 'schema: gxp-roles/v1\ninitiators: [alice]\napprovers: [bob]\n' > .gxp/roles.yml
fresh; expect 1 "roles without verifiers rejected" env INITIATOR=alice bash -c "$ROLES_STEP"

echo "== Unit test summary"
UT_STEP=$(step unit-tests 'Summarise results and requirement coverage')
mkdir -p /tmp/tr && cat > /tmp/tr/unit-tests.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<testsuites>
  <testcase name="[URS-001] inside is PASS" time="0.1" classname="test"/>
  <testcase name="[URS-002] outside is OOS" time="0.1" classname="test"><failure message="boom"/></testcase>
  <testcase name="helper works" time="0.1" classname="test"/>
</testsuites>
XML
fresh; expect 1 "failing test stops the release" env RESULTS=/tmp/tr bash -c "$UT_STEP"
sed -i 's#<failure message="boom"/>##' /tmp/tr/unit-tests.xml
fresh; expect 0 "passing tests summarised per requirement" env RESULTS=/tmp/tr bash -c "$UT_STEP"
rm -rf /tmp/empty && mkdir -p /tmp/empty
fresh; expect 1 "missing test results stop the release" env RESULTS=/tmp/empty bash -c "$UT_STEP"

echo "== Evidence pack"
fresh; EV=$RUNNER_TEMP/evidence; mkdir -p "$EV"/gxp-intake "$EV"/gxp-build "$EV"/gxp-unit-tests "$EV"/gxp-staging
echo '{"version":"v0.1.0-beta.2","workflow_ref":"Kriss-test-org/gxp-devops-framework/.github/workflows/gxp-release.yml@refs/tags/v0.1.0-beta.2","workflow_sha":"abc","prerelease":true}' > "$EV"/gxp-intake/framework.json
yq -o=json '.' validation/0.1.0/impact-assessment.yml > "$EV"/gxp-intake/impact-assessment.json
echo '{"pull_request":1,"url":"https://github.com/x/pull/1","approvers":[{"login":"bob","submitted_at":"2026-10-19T10:00:00Z","url":"u","state":"APPROVED"}]}' > "$EV"/gxp-intake/impact-approval.json
echo '{"image":"ghcr.io/kriss-test-org/gxp-demo-app","digest":"sha256:1111","reference":"ghcr.io/kriss-test-org/gxp-demo-app@sha256:1111","tags":["v0.1.0-rc.1","sha-x"],"build_id":"1001.1","built_at":"t","dockerfile_sha256":"d"}' > "$EV"/gxp-build/build.json
cp /tmp/tr/unit-tests.json "$EV"/gxp-unit-tests/
echo '{"environment":"staging","reference":"r","result":"pass","checked_at":"t","checks":[{"check":"a","result":"pass","detail":"d"}]}' > "$EV"/gxp-staging/checks.json
EV_STEP=$(step evidence 'Assemble the release candidate record')
expect 0 "release candidate record assembled" env EVIDENCE="$EV" VERSION=0.1.0 TAG=v0.1.0-rc.1 INITIATOR=alice \
  STAGING_CONFIG=deploy/staging.env PRODUCTION_CONFIG=deploy/production.env bash -c "$EV_STEP"
expect 0 "every evidence file listed in SHA256SUMS" bash -c "cd '$EV' && sha256sum --check --quiet SHA256SUMS"
jq -c '{release, digest: .artifact.digest, cc: .impact_assessment.change_control_id, unit: .automated_verification.unit_tests.passed}' "$EV"/release-candidate.json | sed 's/^/      /'

echo "== Release record"
REC_STEP=$(step record 'Assemble the release record')
fresh; R=$RUNNER_TEMP/release; mkdir -p "$R"/gxp-verification "$R"/gxp-production
cp -r "$EV" "$R"/gxp-evidence-v0.1.0-rc.1
echo '{"verifier":"alice","reference":"TR-0042","comment":"PASS TR-0042","state":"approved"}' > "$R"/gxp-verification/verification.json
echo '{"approver":"bob","comment":"","approved_before":"t","state":"approved"}' > "$R"/gxp-production/approval.json
echo '{"environment":"production","result":"pass","checked_at":"t","checks":[]}' > "$R"/gxp-production/checks.json
expect 0 "release record assembled" env DIR="$R" VERSION=0.1.0 TAG=v0.1.0-rc.1 bash -c "$REC_STEP"
jq -c '{schema, status, release_tag, verification, approver: .production_approval.approver}' "$R"/release-record.json | sed 's/^/      /'
fresh; R2=$RUNNER_TEMP/release; cp -r "$R" "$R2" 2>/dev/null || true; rm -f "$R2"/release-record.json "$R2"/evidence-*.zip "$R2"/SHA256SUMS
echo tampered >> "$R2"/gxp-evidence-v0.1.0-rc.1/gxp-staging/checks.json
expect 1 "tampered evidence stops the release record" env DIR="$R2" VERSION=0.1.0 TAG=v0.1.0-rc.1 bash -c "$REC_STEP"

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
