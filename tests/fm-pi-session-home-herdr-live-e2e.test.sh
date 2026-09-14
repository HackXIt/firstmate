#!/usr/bin/env bash
# Live Herdr/Pi topic-home recovery guard (live-harness-optin family).
#
# This test launches a real topic-scoped Pi session, observes the absolute
# session path reported by Herdr's installed Pi integration, restarts only a
# named non-default lab, and lets Herdr restore Pi without an FM_HOME or
# FM_ROOT_OVERRIDE in the restarted server environment.
# A global capture extension records the restored process before project
# extensions load and again at session_start, proving that the tracked
# Firstmate extensions recover the topic home before reading local state.
#
# Run explicitly after a Herdr or Pi integration upgrade, and before trusting a
# refreshed docs/verification/runtime-backends.md topic-home recovery entry.
# Every Herdr call, including calls made by bin/firstmate, is routed through
# bin/fm-herdr-lab.sh.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

if [ "${FM_PI_SESSION_HOME_HERDR_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PI_SESSION_HOME_HERDR_LIVE_E2E=1 to run the live Herdr/Pi topic-home recovery guard"
  exit 0
fi

for tool in git herdr jq pi python3; do
  command -v "$tool" >/dev/null 2>&1 \
    || fail "FM_PI_SESSION_HOME_HERDR_LIVE_E2E=1 but $tool is not installed"
done
[ -x "$LAB_HELPER" ] \
  || fail "FM_PI_SESSION_HOME_HERDR_LIVE_E2E=1 but the Herdr lab helper is not executable at $LAB_HELPER"

ORIGINAL_PATH=$PATH
REAL_PI=$(command -v pi)
SESSION=$("$LAB_HELPER" name herdr-topic-home-restore) \
  || fail "could not generate an isolated Herdr lab session name"
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-pi-session-home-herdr-live.XXXXXX")
PROJECT="$TMP_ROOT/firstmate"
TOPIC='herdr-topic-home-live'
TOPIC_BASE="$TMP_ROOT/topic-homes"
TOPIC_HOME="$TOPIC_BASE/$TOPIC"
PI_DIR="$TMP_ROOT/pi-agent"
CAPTURE="$TMP_ROOT/pi-startup.jsonl"
FAKEBIN="$TMP_ROOT/fakebin"
PANE=
CLEANED=0

helper() {
  env -u FM_HOME -u FM_ROOT_OVERRIDE \
    PATH="$ORIGINAL_PATH" \
    PI_CODING_AGENT_DIR="$PI_DIR" \
    FM_PI_HOME_RECOVERY_CAPTURE="$CAPTURE" \
    "$LAB_HELPER" "$@"
}

lab() {
  helper run "$SESSION" "$@"
}

cleanup_all() {
  local status=0
  [ "$CLEANED" -eq 0 ] || return 0
  CLEANED=1
  helper teardown "$SESSION" || status=$?
  rm -rf "$TMP_ROOT"
  return "$status"
}

cleanup_on_exit() {
  local status=$?
  trap - EXIT
  cleanup_all || status=1
  exit "$status"
}
trap cleanup_on_exit EXIT

mkdir -p "$PI_DIR/extensions" "$FAKEBIN"
helper provision "$SESSION" || fail "could not provision the isolated Herdr lab"

HERDR_STATUS=$(lab status --json) || fail "could not read the isolated Herdr client/server status"
HERDR_CLIENT_VERSION=$(printf '%s' "$HERDR_STATUS" | jq -er '.client.version') \
  || fail "Herdr status omitted the client version"
HERDR_CLIENT_PROTOCOL=$(printf '%s' "$HERDR_STATUS" | jq -er '.client.protocol') \
  || fail "Herdr status omitted the client protocol"
HERDR_SERVER_VERSION=$(printf '%s' "$HERDR_STATUS" | jq -er '.server.version') \
  || fail "Herdr status omitted the server version"
HERDR_SERVER_PROTOCOL=$(printf '%s' "$HERDR_STATUS" | jq -er '.server.protocol') \
  || fail "Herdr status omitted the server protocol"

INTEGRATION_STATUS=$(env -u FM_HOME -u FM_ROOT_OVERRIDE -u PI_CODING_AGENT_DIR \
  PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" integration status) \
  || fail "could not read Herdr integration status"
PI_INTEGRATION_VERSION=$(printf '%s\n' "$INTEGRATION_STATUS" \
  | sed -n 's/^pi: current (\(v[0-9][0-9]*\)).*/\1/p')
PI_INTEGRATION_PATH=$(printf '%s\n' "$INTEGRATION_STATUS" \
  | sed -n 's/^pi: current (v[0-9][0-9]*) (\(.*\))$/\1/p')
[ -n "$PI_INTEGRATION_VERSION" ] \
  || fail "Herdr did not report a current Pi integration"
[ -f "$PI_INTEGRATION_PATH" ] \
  || fail "Herdr reported a missing Pi integration path: ${PI_INTEGRATION_PATH:-<empty>}"
cp "$PI_INTEGRATION_PATH" "$PI_DIR/extensions/herdr-agent-state.ts"

cat > "$PI_DIR/extensions/topic-home-capture.ts" <<'TS'
import { appendFileSync } from "node:fs";

const capturePath = process.env.FM_PI_HOME_RECOVERY_CAPTURE;
if (!capturePath) throw new Error("FM_PI_HOME_RECOVERY_CAPTURE is required");

function record(phase: string, reason?: unknown): void {
  appendFileSync(capturePath, `${JSON.stringify({
    phase,
    reason: typeof reason === "string" ? reason : null,
    pid: process.pid,
    fm_home: process.env.FM_HOME ?? null,
    fm_root_override: process.env.FM_ROOT_OVERRIDE ?? null,
    argv: process.argv,
  })}\n`);
}

record("extension-load");

export default function (pi: any): void {
  pi.on("project_trust", () => ({ trusted: "yes", remember: false }));
  pi.on("session_start", (event: { reason?: unknown }) => {
    record("session-start", event?.reason);
  });
}
TS

git clone -q --no-hardlinks "$ROOT" "$PROJECT" \
  || fail "could not create the isolated Firstmate project copy"
git -C "$PROJECT" checkout -q --detach "$(git -C "$ROOT" rev-parse HEAD)" \
  || fail "could not align the isolated Firstmate project copy with the tested commit"

SESSION_ID=$(python3 -c 'import uuid; print(uuid.uuid4())') \
  || fail "could not generate a fresh Pi session id"
SESSION_PATH="$TOPIC_HOME/pi-sessions/session-$SESSION_ID.jsonl"
mkdir -p "$TOPIC_HOME/config" "$TOPIC_HOME/data" "$TOPIC_HOME/state" \
  "$TOPIC_HOME/projects" "$TOPIC_HOME/pi-sessions"
printf 'version=1\nhome=%s\nroot=%s\n' "$TOPIC_HOME" "$PROJECT" > "$TOPIC_HOME/.fm-topic-home"
chmod 600 "$TOPIC_HOME/.fm-topic-home"
umask 077
python3 - "$SESSION_PATH" "$SESSION_ID" "$PROJECT" <<'PY'
import datetime
import json
import pathlib
import sys

path, session_id, cwd = sys.argv[1:]
header = {
    "type": "session",
    "version": 3,
    "id": session_id,
    "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
    "cwd": cwd,
}
pathlib.Path(path).write_text(json.dumps(header, separators=(",", ":")) + "\n", encoding="utf-8")
PY

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
helper='$LAB_HELPER'
session='$SESSION'
real_path='$ORIGINAL_PATH'
pi_dir='$PI_DIR'
capture='$CAPTURE'
args=("\$@")
n=\${#args[@]}
if [ "\$n" -lt 2 ] || [ "\${args[\$((n-2))]}" != --session ]; then
  echo "wrapper requires trailing --session \$session" >&2
  exit 98
fi
[ "\${args[\$((n-1))]}" = "\$session" ] \
  || { echo "wrapper refused foreign session" >&2; exit 97; }
args=("\${args[@]:0:\$((n-2))}")
exec env -u FM_HOME -u FM_ROOT_OVERRIDE \
  PATH="\$real_path" \
  PI_CODING_AGENT_DIR="\$pi_dir" \
  FM_PI_HOME_RECOVERY_CAPTURE="\$capture" \
  "\$helper" run "\$session" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"
printf '#!/usr/bin/env bash\nexec %q --session %q "$@"\n' "$REAL_PI" "$SESSION_PATH" > "$FAKEBIN/pi"
chmod +x "$FAKEBIN/pi"

cat > "$TMP_ROOT/launch-topic.sh" <<EOF
#!/usr/bin/env bash
set -eu
export PATH='$FAKEBIN:$ORIGINAL_PATH'
export PI_CODING_AGENT_DIR='$PI_DIR'
export FM_PI_HOME_RECOVERY_CAPTURE='$CAPTURE'
export FIRSTMATE_HOME_BASE='$TOPIC_BASE'
exec '$PROJECT/bin/firstmate' '$TOPIC'
EOF
chmod +x "$TMP_ROOT/launch-topic.sh"

WORKSPACE_JSON=$(lab workspace create --cwd "$PROJECT" --label fm-topic-home-live --no-focus) \
  || fail "could not create the isolated topic-home workspace"
PANE=$(printf '%s' "$WORKSPACE_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
lab pane run "$PANE" "$TMP_ROOT/launch-topic.sh" >/dev/null \
  || fail "could not launch the topic-scoped Pi session"

wait_for_recorded_session() {
  local attempt agent path
  for attempt in $(seq 1 240); do
    agent=$(lab agent get "$PANE" 2>/dev/null || true)
    path=$(printf '%s' "$agent" | jq -r '
      .result.agent.agent_session
      | select(.kind == "path" and .source == "herdr:pi")
      | .value
      | select(type == "string" and length > 0)
    ' 2>/dev/null || true)
    if [ -n "$path" ]; then
      printf '%s\n' "$path"
      return 0
    fi
    sleep 0.25
  done
  return 1
}

RECORDED_SESSION_PATH=$(wait_for_recorded_session) || {
  AGENT_DEBUG=$(lab agent get "$PANE" 2>&1 || true)
  PANE_DEBUG=$(lab pane read "$PANE" --source recent --lines 200 2>&1 || true)
  fail "Herdr never recorded the topic Pi session path"$'\n'"--- agent ---"$'\n'"$AGENT_DEBUG"$'\n'"--- pane ---"$'\n'"$PANE_DEBUG"
}
[ "$RECORDED_SESSION_PATH" = "$SESSION_PATH" ] \
  || fail "Herdr recorded a different Pi session path: $RECORDED_SESSION_PATH"
case "$RECORDED_SESSION_PATH" in
  "$TOPIC_HOME"/pi-sessions/*) : ;;
  *) fail "Herdr recorded a Pi session outside the topic home: $RECORDED_SESSION_PATH" ;;
esac
[ "${RECORDED_SESSION_PATH#/}" != "$RECORDED_SESSION_PATH" ] \
  || fail "Herdr recorded a non-absolute Pi session path: $RECORDED_SESSION_PATH"
[ "$(realpath "$RECORDED_SESSION_PATH")" = "$RECORDED_SESSION_PATH" ] \
  || fail "Herdr recorded a non-canonical Pi session path: $RECORDED_SESSION_PATH"
pass "live Herdr records the exact absolute Pi session fixture under the isolated topic home"

wait_for_capture() {
  local predicate=$1 attempt
  for attempt in $(seq 1 240); do
    if [ -s "$CAPTURE" ] && jq -s -e "$predicate" "$CAPTURE" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

wait_for_capture 'any(.[]; .phase == "session-start")' \
  || fail "the initial Pi session never reached session_start"
INITIAL_PID=$(jq -sr '[.[] | select(.phase == "extension-load")][-1].pid // empty' "$CAPTURE")
case "$INITIAL_PID" in
  ''|*[!0-9]*) fail "the initial Pi extension load did not record a process id" ;;
esac
GUARD_MARKER="$TOPIC_HOME/state/.pi-turnend-extension-loaded"
WATCH_MARKER="$TOPIC_HOME/state/.pi-watch-extension-loaded"
[ "$(sed -n '2p' "$GUARD_MARKER" 2>/dev/null)" = "$INITIAL_PID" ] \
  || fail "the initial guard extension did not bind the topic home"
[ "$(sed -n '2p' "$WATCH_MARKER" 2>/dev/null)" = "$INITIAL_PID" ] \
  || fail "the initial watcher extension did not bind the topic home"

helper stop "$SESSION" >/dev/null \
  || fail "could not stop only the isolated Herdr lab before native recovery"
helper provision "$SESSION" \
  || fail "could not restart only the isolated Herdr lab for native recovery"

wait_for_capture "any(.[]; .phase == \"extension-load\" and .pid != $INITIAL_PID)" \
  || fail "Herdr did not start a replacement Pi process through native recovery"
RESTORED_PID=$(jq -sr --argjson initial "$INITIAL_PID" \
  '[.[] | select(.phase == "extension-load" and .pid != $initial)][-1].pid // empty' "$CAPTURE")
case "$RESTORED_PID" in
  ''|*[!0-9]*) fail "the restored Pi extension load did not record a process id" ;;
esac

jq -s -e --argjson pid "$RESTORED_PID" --arg session "$SESSION_PATH" '
  [.[] | select(.phase == "extension-load" and .pid == $pid)][-1] as $record
  | ([range(0; ($record.argv | length)) | select($record.argv[.] == "--session")] | .[0]) as $index
  | $record.fm_home == null
    and $record.fm_root_override == null
    and $index != null
    and $record.argv[$index + 1] == $session
    and ([range(0; ($record.argv | length)) | select($record.argv[.] == "--session")] | length) == 1
' "$CAPTURE" >/dev/null \
  || fail "Herdr native recovery did not start one exact Pi session without Firstmate home environment"
pass "native Herdr recovery starts the exact Pi session without FM_HOME or FM_ROOT_OVERRIDE"

wait_for_capture "any(.[]; .phase == \"session-start\" and .pid == $RESTORED_PID and .fm_home == \"$TOPIC_HOME\" and .fm_root_override == \"$PROJECT\")" \
  || fail "the restored Pi process did not reach session_start with the recovered topic home"
[ "$(sed -n '2p' "$GUARD_MARKER" 2>/dev/null)" = "$RESTORED_PID" ] \
  || fail "the restored guard extension did not write into the topic home"
[ "$(sed -n '2p' "$WATCH_MARKER" 2>/dev/null)" = "$RESTORED_PID" ] \
  || fail "the restored watcher extension did not write into the topic home"
[ ! -e "$PROJECT/state/.pi-turnend-extension-loaded" ] \
  || fail "the restored guard extension touched shared-project state"
[ ! -e "$PROJECT/state/.pi-watch-extension-loaded" ] \
  || fail "the restored watcher extension touched shared-project state"
RESTORED_SESSION_PATH=$(wait_for_recorded_session) \
  || fail "Herdr did not re-record the restored Pi session path"
[ "$RESTORED_SESSION_PATH" = "$SESSION_PATH" ] \
  || fail "Herdr restored a different Pi session: $RESTORED_SESSION_PATH"
pass "restored Firstmate extensions use the topic home and leave shared-project state untouched"

PI_VERSION=$(pi --version 2>/dev/null | head -1)
if ! cleanup_all; then
  trap - EXIT
  fail "isolated Herdr lab teardown failed or the default session changed"
fi
trap - EXIT
pass "isolated Herdr recovery lab is removed with the default session unchanged"
printf 'evidence: herdr-client=%s protocol=%s herdr-server=%s protocol=%s pi=%s integration=%s\n' \
  "$HERDR_CLIENT_VERSION" "$HERDR_CLIENT_PROTOCOL" \
  "$HERDR_SERVER_VERSION" "$HERDR_SERVER_PROTOCOL" \
  "$PI_VERSION" "$PI_INTEGRATION_VERSION"
