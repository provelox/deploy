#!/usr/bin/env bash
# Starts a deploy through the Provelox CI endpoint and, unless told not to, follows it until it settles.
# Inputs arrive as environment variables so nothing from the workflow is ever interpolated into shell.
set -euo pipefail

# A GitHub annotation is one line: newlines, carriage returns and % are encoded the way workflow commands need.
annotate() { # level message
  # the replacements are in variables, not quoted inline: bash 3.2 (macOS) keeps quotes written in ${var//a/'b'}
  local msg="$2" pct='%25' cr='%0D' nl='%0A'
  msg="${msg//\%/$pct}"
  msg="${msg//$'\r'/$cr}"
  msg="${msg//$'\n'/$nl}"
  echo "::$1::${msg}"
}
fail() {
  annotate error "$1"
  exit 1
}

for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required on the runner (GitHub-hosted runners have it)."
done

SERVER="${PROVELOX_SERVER_URL:-}"
KEY="${PROVELOX_DEPLOY_KEY:-}"
IMAGE_WANTED="${PROVELOX_IMAGE:-}"
WAIT="$(tr '[:upper:]' '[:lower:]' <<<"${PROVELOX_WAIT:-true}")"
TIMEOUT="${PROVELOX_TIMEOUT:-600}"
# seconds between looks at the deploy, and how long one request may take; only the tests change these
POLL="${PROVELOX_POLL_SECONDS:-3}"
REQUEST_LIMIT="${PROVELOX_REQUEST_SECONDS:-30}"

[[ -n "$SERVER" ]] || fail "server-url is required."
[[ -n "$KEY" ]] || fail "deploy-key is required. Store the app's deploy key as a repository secret and pass it in."
[[ -n "$IMAGE_WANTED" ]] || fail "image is required, for example ghcr.io/acme/web:1.4.2."
[[ "$SERVER" =~ ^https?://[^/]+ ]] || fail "server-url must start with http:// or https:// (it is \"${SERVER}\")."
[[ "$WAIT" == "true" || "$WAIT" == "false" ]] || fail "wait must be true or false (it is \"${PROVELOX_WAIT:-}\")."
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || fail "timeout must be a whole number of seconds (it is \"${TIMEOUT}\")."
[[ "$POLL" =~ ^[0-9]+(\.[0-9]+)?$ ]] || fail "PROVELOX_POLL_SECONDS must be a number."
[[ "$REQUEST_LIMIT" =~ ^[0-9]+$ ]] || fail "PROVELOX_REQUEST_SECONDS must be a whole number."

BASE="${SERVER%/}/v1/ci"

echo "::add-mask::${KEY}"

# Sets STATUS (000 when nothing answered) and RESPONSE. It never exits: the caller decides what a failure means.
# Every request has a limit, so a server that accepts the connection and never answers cannot hold the step.
request() { # method path [json body]
  local method="$1" path="$2" body="${3:-}" out
  local args=(-sS --connect-timeout 10 --max-time "$REQUEST_LIMIT" -X "$method" -H "Authorization: Bearer ${KEY}" -w $'\n%{http_code}')
  if [[ -n "$body" ]]; then args+=(-H 'Content-Type: application/json' -d "$body"); fi
  if out="$(curl "${args[@]}" "${BASE}${path}")"; then
    STATUS="${out##*$'\n'}"
    RESPONSE="${out%$'\n'*}"
  else
    STATUS=000
    RESPONSE=""
  fi
}

# What Provelox said went wrong, on one line. Its errors are { "error": { "code", "message" } }; anything else (a
# proxy's page) is shown as it is, shortened.
problem() {
  local msg
  msg="$(jq -r '(if (.error | type) == "object" then .error.message else .error end) // .message // empty' <<<"$RESPONSE" 2>/dev/null || true)"
  [[ -n "$msg" ]] || msg="$(tr '\n' ' ' <<<"${RESPONSE:0:200}")"
  printf '%s' "$msg"
}

request POST /deploy "$(jq -nc --arg image "$IMAGE_WANTED" '{image: $image}')"
case "$STATUS" in
2*) ;;
000) fail "Could not reach ${SERVER}. Is the address right (it is the API, api.<your domain> by default, not the console), and can the runner reach the server?" ;;
401) fail "Provelox did not accept the deploy key (401). Check the secret, and that the key was not revoked: $(problem)" ;;
*) fail "Provelox answered ${STATUS}: $(problem)" ;;
esac

APP="$(jq -er .app <<<"$RESPONSE" 2>/dev/null)" || fail "Provelox answered, but not in the expected shape: $(problem)"
VERSION="$(jq -er '.version | tostring' <<<"$RESPONSE" 2>/dev/null)" || fail "Provelox answered without a deploy version."
IMAGE="$(jq -er .image <<<"$RESPONSE" 2>/dev/null)" || fail "Provelox answered without an image."
[[ "$VERSION" =~ ^[0-9]+$ ]] || fail "Provelox answered with a deploy version that is not a number (\"${VERSION}\")."
{
  echo "app=${APP}"
  echo "version=${VERSION}"
  echo "image=${IMAGE}"
} >>"${GITHUB_OUTPUT:-/dev/null}"
echo "Deploying ${APP} (version ${VERSION}) to ${IMAGE}"

[[ "$WAIT" == "true" ]] || exit 0

# Provelox follows one deploy per app, and says which (`version`). Follow only ours: a newer deploy replaces the one
# being followed, and a restart of Provelox forgets it, so neither may be read as "ours finished".
deadline=$((SECONDS + TIMEOUT))
shown=0
blips=0
MAX_BLIPS=20
while :; do
  request GET /deployment
  case "$STATUS" in
  2*) blips=0 ;;
  000 | 429 | 5*)
    # a proxy restarting, a dropped connection: the deploy goes on without us, so wait it out for a while
    blips=$((blips + 1))
    ((blips < MAX_BLIPS)) || fail "Lost touch with ${SERVER} while the deploy ran (last answer: ${STATUS}). The deploy may still be running: check ${APP} in the console."
    if ((SECONDS >= deadline)); then fail "Gave up waiting after ${TIMEOUT}s; the deploy may still be running"; fi
    sleep "$POLL"
    continue
    ;;
  401 | 403) fail "Provelox stopped accepting the deploy key (${STATUS}) while the deploy ran. The deploy may still be running: check ${APP} in the console." ;;
  *) fail "Provelox answered ${STATUS} while following the deploy: $(problem)" ;;
  esac

  seen="$(jq -r '.version // empty | tostring' <<<"$RESPONSE")"
  if [[ -z "$seen" ]]; then
    # no record at all: Provelox was restarted (an update, for one) and forgot the deploy, so it cannot be confirmed
    fail "Provelox no longer has a record of this deploy (it was probably restarted while the deploy ran), so it cannot say whether it worked. Check ${APP} in the console."
  elif [[ "$seen" != "$VERSION" ]]; then
    fail "This deploy (version ${VERSION}) was replaced by a newer one (version ${seen}) before it settled, so it cannot be followed. Check ${APP} in the console."
  fi

  total="$(jq '(.lines // []) | length' <<<"$RESPONSE")"
  if ((total > shown)); then jq -r ".lines[${shown}:][]" <<<"$RESPONSE"; fi
  shown=$total
  if [[ "$(jq -r .isFailed <<<"$RESPONSE")" == "true" ]]; then
    fail "The deploy of ${APP} failed"
  fi
  if [[ "$(jq -r .isBuilding <<<"$RESPONSE")" != "true" ]]; then
    echo "Deploy of ${APP} finished"
    exit 0
  fi
  if ((SECONDS >= deadline)); then
    fail "Gave up waiting after ${TIMEOUT}s; the deploy may still be running"
  fi
  sleep "$POLL"
done
