#!/bin/bash
# Workflow step tests: runs the `run:` steps of the framework workflows with test inputs and checks
# that they accept valid input and reject what they are meant to block. Steps that call the GitHub
# API, the OIDC endpoint or the container registry are covered by end-to-end runs, not here.
# Needs bash, git, jq, yq (mikefarah v4), python3, zip and GNU coreutils/findutils.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WF=$ROOT/.github/workflows
APP=$ROOT/tests/fixtures/app
CAND=$WF/gxp-candidate.yml
PROM=$WF/gxp-promote.yml
pass=0; fail=0
# Keep git settings for the test repositories away from the user's global configuration.
GIT_CONFIG_GLOBAL=$(mktemp)
export GIT_CONFIG_GLOBAL

step() { yq -r "(.jobs.$1.steps[] | select(.name == \"$2\")).run" "$3"; }
expect() { # expect <exit-code> <label> <command...>
  local want=$1 label=$2; shift 2
  local out; out=$("$@" 2>&1); local got=$?
  if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "PASS  $label"; else fail=$((fail+1)); echo "FAIL  $label (exit $got, wanted $want)"; echo "$out" | sed 's/^/      /' | tail -20; fi
}
fresh() {
  export RUNNER_TEMP=$(mktemp -d) GITHUB_OUTPUT=$(mktemp) GITHUB_STEP_SUMMARY=$(mktemp)
  mkdir -p "$RUNNER_TEMP/gxp-intake" "$RUNNER_TEMP/gxp-approval"
}
export GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=Kriss-test-org/gxp-demo-app GITHUB_RUN_ID=1001 GITHUB_RUN_ATTEMPT=1
git config --global user.email t@example.com; git config --global user.name tester; git config --global init.defaultBranch main

# ---------- app repo with the impact assessment committed ----------
rm -rf /tmp/repo && cp -r "$APP" /tmp/repo && cd /tmp/repo && git init -q && git add -A && git commit -qm base
export COMMIT=$(git rev-parse HEAD)

echo "== Impact assessment validation"
IA_STEP=$(step intake 'Validate the impact assessment' $CAND)
fresh; expect 0 "valid impact assessment accepted" env VERSION=0.1.0 bash -c "$IA_STEP"
grep -q '^change_commit=' "$GITHUB_OUTPUT" && echo "      outputs: $(tr '\n' ' ' < "$GITHUB_OUTPUT")"
fresh; expect 1 "missing impact assessment rejected" env VERSION=9.9.9 bash -c "$IA_STEP"
cp validation/0.1.0/impact-assessment.yml /tmp/ia.bak
yq -i '.validation_path = "targeted"' validation/0.1.0/impact-assessment.yml
fresh; expect 1 "high impact with targeted path rejected" env VERSION=0.1.0 bash -c "$IA_STEP"
cp /tmp/ia.bak validation/0.1.0/impact-assessment.yml; yq -i 'del(.change_control_id) | .version = "0.2.0"' validation/0.1.0/impact-assessment.yml
fresh; out=$(env VERSION=0.1.0 bash -c "$IA_STEP" 2>&1); echo "$out" | grep -c '::error' | xargs -I{} echo "      {} errors reported for missing CC id + wrong version:"; echo "$out" | sed 's/^/        /'
cp /tmp/ia.bak validation/0.1.0/impact-assessment.yml

echo "== Roles check"
ROLES_STEP=$(step intake 'Check that the initiator may start releases' $CAND)
fresh; expect 1 "placeholder roles rejected" env INITIATOR=alice bash -c "$ROLES_STEP"
printf 'schema: gxp-roles/v1\ninitiators: [alice]\napprovers: [bob]\n' > .gxp/roles.yml
fresh; expect 0 "listed initiator accepted" env INITIATOR=alice bash -c "$ROLES_STEP"
fresh; expect 1 "unlisted initiator rejected" env INITIATOR=mallory bash -c "$ROLES_STEP"

echo "== Unit test summary (python)"
UT_STEP=$(step unit-tests 'Summarise results and requirement coverage' $CAND)
mkdir -p /tmp/tr && cat > /tmp/tr/unit-tests.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<testsuites>
  <testcase name="[URS-001] inside is PASS" time="0.1" classname="test"/>
  <testcase name="[URS-002] outside is OOS" time="0.1" classname="test"><failure message="boom"/></testcase>
  <testcase name="helper works" time="0.1" classname="test"/>
</testsuites>
XML
fresh; expect 1 "failing test reported as fail" env RESULTS=/tmp/tr bash -c "$UT_STEP" ; jq -c '{result,total,passed,failed,traceability}' /tmp/tr/unit-tests.json | sed 's/^/      /'
sed -i 's#<failure message="boom"/>##' /tmp/tr/unit-tests.xml
fresh; expect 0 "passing tests summarised" env RESULTS=/tmp/tr bash -c "$UT_STEP"; sed 's/^/      /' "$GITHUB_STEP_SUMMARY"

echo "== Evidence assembly"
fresh; EV=$RUNNER_TEMP/evidence; mkdir -p $EV/gxp-intake $EV/gxp-build $EV/gxp-unit-tests $EV/gxp-staging
echo '{"version":"v0.1.0-beta.1","workflow_ref":"Kriss-test-org/gxp-devops-framework/.github/workflows/gxp-candidate.yml@refs/tags/v0.1.0-beta.1","workflow_sha":"abc","prerelease":true}' > $EV/gxp-intake/framework.json
yq -o=json '.' validation/0.1.0/impact-assessment.yml > $EV/gxp-intake/impact-assessment.json
echo '{"pull_request":1,"url":"https://github.com/x/pull/1","approvers":[{"login":"bob","submitted_at":"2026-10-19T10:00:00Z","url":"u","state":"APPROVED"}]}' > $EV/gxp-intake/impact-approval.json
echo '{"image":"ghcr.io/kriss-test-org/gxp-demo-app","digest":"sha256:1111","reference":"ghcr.io/kriss-test-org/gxp-demo-app@sha256:1111","tags":["v0.1.0-rc.1","sha-x"],"build_id":"1001.1","built_at":"t","dockerfile_sha256":"d"}' > $EV/gxp-build/build.json
cp /tmp/tr/unit-tests.json $EV/gxp-unit-tests/
echo '{"environment":"staging","reference":"r","result":"pass","checked_at":"t","checks":[{"check":"a","result":"pass","detail":"d"},{"check":"b","result":"pass","detail":"d"}]}' > $EV/gxp-staging/checks.json
EV_STEP=$(step evidence 'Assemble the release candidate record' $CAND)
expect 0 "release candidate record assembled" env EVIDENCE=$EV VERSION=0.1.0 TAG=v0.1.0-rc.1 INITIATOR=alice STAGING_CONFIG=deploy/staging.env PRODUCTION_CONFIG=deploy/production.env bash -c "$EV_STEP"
jq -c '{release, framework: .framework.version, digest: .artifact.digest, ia: .impact_assessment | {change_control_id, approval}, unit: .automated_verification.unit_tests.passed}' $EV/release-candidate.json | sed 's/^/      /'
(cd $EV && sha256sum --check --quiet SHA256SUMS) && echo "      SHA256SUMS verifies ($(wc -l < $EV/SHA256SUMS) files)"

echo "== Release branch + verification template"
rm -rf /tmp/origin.git && git clone -q --bare /tmp/repo /tmp/origin.git && rm -rf /tmp/clone && git clone -q /tmp/origin.git /tmp/clone
RB_STEP=$(step release-pr 'Commit the release record to a release branch' $CAND)
(cd /tmp/clone && expect 0 "release branch pushed" env EVIDENCE=$EV VERSION=0.1.0 TAG=v0.1.0-rc.1 bash -c "$RB_STEP")
git -C /tmp/origin.git log --oneline release/v0.1.0-rc.1 -1 | sed 's/^/      /'
git -C /tmp/origin.git show release/v0.1.0-rc.1:validation/0.1.0/verification.md | sed 's/^/      | /'

echo "== Promotion: locate record, candidate checks, verification, evidence comparison"
cd /tmp/repo && git tag v0.1.0-rc.1 && BEFORE=$(git rev-parse HEAD)
git fetch -q /tmp/origin.git release/v0.1.0-rc.1 && git merge -q --no-ff FETCH_HEAD -m "Merge release PR"
export GITHUB_SHA=$(git rev-parse HEAD)
LOC_STEP=$(step approval 'Locate the release record' $PROM)
fresh; expect 0 "release record located" env BEFORE=$BEFORE bash -c "$LOC_STEP"; sed 's/^/      /' "$GITHUB_OUTPUT"
CUR_STEP=$(step approval 'Check that this is the current, unreleased candidate' $PROM)
fresh; expect 0 "current candidate accepted" env VERSION=0.1.0 TAG=v0.1.0-rc.1 COMMIT=$COMMIT bash -c "$CUR_STEP"
git tag v0.1.0-rc.2 HEAD
fresh; expect 1 "superseded candidate rejected" env VERSION=0.1.0 TAG=v0.1.0-rc.1 COMMIT=$COMMIT bash -c "$CUR_STEP"
git tag -d v0.1.0-rc.2 >/dev/null; git tag v0.1.0 "$COMMIT"
fresh; expect 1 "already released version rejected" env VERSION=0.1.0 TAG=v0.1.0-rc.1 COMMIT=$COMMIT bash -c "$CUR_STEP"
git tag -d v0.1.0 >/dev/null
VER_STEP=$(step approval 'Check the verification record' $PROM)
fresh; expect 1 "PENDING verification rejected" env VERSION=0.1.0 bash -c "$VER_STEP"
sed -i 's/^Overall result: PENDING$/Overall result: PASS/' validation/0.1.0/verification.md
fresh; expect 0 "PASS verification accepted" env VERSION=0.1.0 bash -c "$VER_STEP"
CMP_STEP=$(step approval 'Compare the release record with the evidence' $PROM)
fresh; expect 0 "unchanged record matches evidence" env RECORD=validation/0.1.0/release-candidate.json EVIDENCE=$EV bash -c "$CMP_STEP"
jq '.artifact.digest = "sha256:2222"' validation/0.1.0/release-candidate.json > /tmp/rec && cp /tmp/rec validation/0.1.0/release-candidate.json
fresh; expect 1 "edited digest detected" env RECORD=validation/0.1.0/release-candidate.json EVIDENCE=$EV bash -c "$CMP_STEP"
cp $EV/release-candidate.json validation/0.1.0/release-candidate.json
echo tampered >> $EV/gxp-staging/checks.json
fresh; expect 1 "tampered evidence file detected" env RECORD=validation/0.1.0/release-candidate.json EVIDENCE=$EV bash -c "$CMP_STEP"

echo "== Finalize: release record"
fresh; R=$RUNNER_TEMP/release; mkdir -p $R/gxp-approval/candidate-evidence $R/gxp-production
cp $EV/release-candidate.json $R/gxp-approval/candidate-evidence/
echo '{"version":"v0.1.0-beta.1","workflow_ref":"x","workflow_sha":"y","prerelease":true}' > $R/gxp-approval/framework.json
echo '{"pull_request":{"number":2,"url":"u"},"verified_by":["alice"],"approved_by":[{"login":"bob"}],"candidate_run":{"id":1001}}' > $R/gxp-approval/approval.json
echo '{"environment":"production","result":"pass","checks":[]}' > $R/gxp-production/checks.json
FIN_STEP=$(step finalize 'Assemble the release record' $PROM)
expect 0 "release record assembled" env DIR=$R VERSION=0.1.0 bash -c "$FIN_STEP"
jq -c '{schema, status, release_tag, approval, promotion: .promotion.framework.version}' $R/release-record.json | sed 's/^/      /'
ls $R | sed 's/^/      /'

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
