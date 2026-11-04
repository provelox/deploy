#!/usr/bin/env bash
# Runs scripts/deploy.sh against test/mock-api.mjs, which answers the way the Provelox API does, and checks what the
# step would do in a workflow: its exit code, the annotations it prints and the outputs it sets.
#   test/run-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.."

KEY=pvxk_test_secret
failures=0
checks=0

# run <scenario> [VAR=value ...] -> sets OUT (what the step printed), CODE (its exit code) and OUTPUTS (GITHUB_OUTPUT)
run() {
  local scenario="$1"
  shift
  local port=$((20000 + RANDOM % 20000)) outputs
  outputs="$(mktemp)"
  node test/mock-api.mjs "$port" "$scenario" >/dev/null &
  local mock=$!
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:${port}/" && break
    sleep 0.1
  done
  OUT="$(env -i PATH="$PATH" HOME="$HOME" GITHUB_OUTPUT="$outputs" \
    PROVELOX_SERVER_URL="http://127.0.0.1:${port}" PROVELOX_DEPLOY_KEY="$KEY" PROVELOX_IMAGE="acme/web:1" \
    PROVELOX_POLL_SECONDS=0.2 PROVELOX_REQUEST_SECONDS=2 PROVELOX_TIMEOUT=20 "$@" \
    bash scripts/deploy.sh 2>&1)"
  CODE=$?
  OUTPUTS="$(tr '\n' ' ' <"$outputs")"
  kill "$mock" 2>/dev/null
  wait "$mock" 2>/dev/null
  rm -f "$outputs"
}

# expect <name> <exit code> <text that must be in the output>...
expect() {
  local name="$1" code="$2"
  shift 2
  checks=$((checks + 1))
  local bad=""
  [[ "$CODE" == "$code" ]] || bad+=" exit was ${CODE}, wanted ${code};"
  for want in "$@"; do
    [[ "$OUT $OUTPUTS" == *"$want"* ]] || bad+=" missing \"${want}\";"
  done
  if [[ -z "$bad" ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name:$bad"
    echo "$OUT" | sed 's/^/       | /'
    failures=$((failures + 1))
  fi
}

run ok
expect "a healthy deploy succeeds and sets the outputs" 0 "Deploy of demo finished" "app=demo" "version=1" "image=acme/web:1" "Running: 2/2 instances."
run ok PROVELOX_WAIT=false
expect "wait=false returns after starting it, with the outputs" 0 "Deploying demo (version 1)" "version=1"
run ok PROVELOX_WAIT=False
expect "wait is not case sensitive" 0 "version=1"
run ok PROVELOX_SERVER_URL="http://127.0.0.1:1/" PROVELOX_IMAGE=acme/web:1
expect "an unreachable server is said plainly" 1 "::error::Could not reach"

run ok PROVELOX_DEPLOY_KEY=pvxk_wrong
expect "a wrong key says so on one line, with the API's own words" 1 "::error::Provelox did not accept the deploy key (401)" "Invalid API key"
[[ "$OUT" != *$'\n  "code"'* ]] || { echo "FAIL the error was printed as JSON"; failures=$((failures + 1)); }
run ok PROVELOX_IMAGE=other/thing:1
expect "an image of another repository is refused with the API's reason" 1 "::error::Provelox answered 403: This key or token can deploy another version"

run ok PROVELOX_IMAGE=
expect "a missing image is an annotation, not a shell error" 1 "::error::image is required"
run ok PROVELOX_SERVER_URL=provelox.example.com
expect "a server-url without a scheme is explained" 1 '::error::server-url must start with http'
run ok PROVELOX_TIMEOUT=ten
expect "a timeout that is not a number is explained" 1 "::error::timeout must be a whole number"

run rollback
expect "a rolled-back deploy fails the step, with Docker's reason" 1 "Docker rolled the update back" "::error::The deploy of demo failed"
run building PROVELOX_TIMEOUT=2
expect "a deploy that never settles fails at the timeout" 1 "::error::Gave up waiting after 2s"

run restarted
expect "a Provelox that forgot the deploy is NOT reported as a success" 1 "::error::Provelox no longer has a record of this deploy"
run replaced
expect "a deploy replaced by a newer one is not followed as if it were this one" 1 "::error::This deploy (version 1) was replaced by a newer one (version 2)"

run blip
expect "a short outage of the proxy in front of Provelox does not fail the deploy" 0 "Deploy of demo finished"
run gone PROVELOX_TIMEOUT=60
expect "a long outage gives up with a pointer to the console" 1 "::error::Lost touch with" "check demo in the console"
run revoked
expect "a key revoked during the deploy is said so" 1 "::error::Provelox stopped accepting the deploy key (401)"

run hang
expect "a server that never answers does not hold the step for ever" 1 "::error::Could not reach"

run ok PROVELOX_DEPLOY_KEY="$KEY"
[[ "$OUT" == *"::add-mask::${KEY}"* ]] && echo "ok   the key is masked before anything else is printed" || { echo "FAIL the key is not masked"; failures=$((failures + 1)); }
checks=$((checks + 1))

# An annotation is one line, with %, newlines and carriage returns encoded; the function is read out of the script so
# this is tested on whatever bash runs it (macOS ships 3.2, which treats quotes inside ${var//a/'b'} differently)
checks=$((checks + 1))
annotated="$(eval "$(sed -n '/^annotate()/,/^}/p' scripts/deploy.sh)"; annotate error $'100% sure\nsecond line\rend')"
if [[ "$annotated" == '::error::100%25 sure%0Asecond line%0Dend' ]]; then
  echo "ok   annotations encode %, newlines and carriage returns, with no stray quotes"
else
  echo "FAIL annotation encoding: got ${annotated}"
  failures=$((failures + 1))
fi

echo
echo "${checks} checks, ${failures} failed"
((failures == 0))
