#!/usr/bin/env bash
# Live Firstmate topic recovery and worker-placement guard.
#
# The operator path begins by running `fm <topic>` in one real Herdr pane.
# A global capture extension appends a provider-free completed exchange so the
# primary and two real Pi worker processes persist the same way real work does.
# The primary starts each worker through the real fm-spawn.sh path, so the test covers launcher
# identity, topic-home session storage, tab placement, native Herdr recovery,
# worker recovery, and a post-recovery spawn as one observable contract.
#
# Every Herdr command, including those issued by Firstmate, is routed through
# bin/fm-herdr-lab.sh and its named non-default session tripwire.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

fm_live_gate opt-in FM_PI_SESSION_HOME_HERDR_LIVE_E2E git herdr jq pi python3 treehouse

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$LAB_HELPER" ] || { echo "not ok - Herdr lab helper is not executable at $LAB_HELPER" >&2; exit 1; }

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

ORIGINAL_PATH=$PATH
REAL_PI=$(command -v pi)
SESSION=$("$LAB_HELPER" name firstmate-herdr-topic-recovery) \
  || fail "could not generate an isolated Herdr lab session name"
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-pi-session-home-herdr-live.XXXXXX")
LAB_HOME="$TMP_ROOT/home"
PROJECT="$TMP_ROOT/firstmate"
SCRATCH_PROJECT="$TMP_ROOT/project"
PI_DIR="$TMP_ROOT/pi-agent"
CAPTURE="$TMP_ROOT/pi-startup.jsonl"
PHASE="$TMP_ROOT/phase"
FAKEBIN="$TMP_ROOT/fakebin"
TOPIC=herdr-topic-home-live
TOPIC_HOME="$LAB_HOME/.local/share/firstmate/$TOPIC"
SPAWN_SCRIPT="$TMP_ROOT/spawn-worker.sh"
LAUNCH_SCRIPT="$TMP_ROOT/launch-topic.sh"
CLEANED=0

helper() {
  env -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_TASK_ID \
    HOME="$LAB_HOME" PATH="$ORIGINAL_PATH" \
    PI_CODING_AGENT_DIR="$PI_DIR" \
    FM_PI_HOME_RECOVERY_CAPTURE="$CAPTURE" \
    FM_PI_HOME_RECOVERY_PHASE="$PHASE" \
    FM_PI_HOME_RECOVERY_SPAWN="$SPAWN_SCRIPT" \
    FM_PI_HOME_RECOVERY_FAKEBIN="$FAKEBIN" \
    FM_PI_HOME_RECOVERY_ORIGINAL_PATH="$ORIGINAL_PATH" \
    "$LAB_HELPER" "$@"
}

lab() {
  helper run "$SESSION" "$@"
}

cleanup_all() {
  local status=0
  [ "$CLEANED" -eq 0 ] || return 0
  CLEANED=1
  helper teardown "$SESSION" || status=1
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

mkdir -p "$LAB_HOME" "$PI_DIR/extensions" "$FAKEBIN"
helper provision "$SESSION" || fail "could not provision the isolated Herdr lab"

HERDR_STATUS=$(lab status --json) || fail "could not read isolated Herdr status"
HERDR_CLIENT_VERSION=$(printf '%s' "$HERDR_STATUS" | jq -er '.client.version') \
  || fail "Herdr status omitted the client version"
HERDR_CLIENT_PROTOCOL=$(printf '%s' "$HERDR_STATUS" | jq -er '.client.protocol') \
  || fail "Herdr status omitted the client protocol"
HERDR_SERVER_VERSION=$(printf '%s' "$HERDR_STATUS" | jq -er '.server.version') \
  || fail "Herdr status omitted the server version"
HERDR_SERVER_PROTOCOL=$(printf '%s' "$HERDR_STATUS" | jq -er '.server.protocol') \
  || fail "Herdr status omitted the server protocol"
INTEGRATION_STATUS=$(env -u PI_CODING_AGENT_DIR PATH="$ORIGINAL_PATH" \
  "$LAB_HELPER" run "$SESSION" integration status) \
  || fail "could not read Herdr integration status"
PI_INTEGRATION_VERSION=$(printf '%s\n' "$INTEGRATION_STATUS" \
  | sed -n 's/^pi: current (\(v[0-9][0-9]*\)).*/\1/p')
PI_INTEGRATION_PATH=$(printf '%s\n' "$INTEGRATION_STATUS" \
  | sed -n 's/^pi: current (v[0-9][0-9]*) (\(.*\))$/\1/p')
[ -n "$PI_INTEGRATION_VERSION" ] || fail "Herdr did not report a current Pi integration"
[ -f "$PI_INTEGRATION_PATH" ] || fail "Herdr reported a missing Pi integration path"
cp "$PI_INTEGRATION_PATH" "$PI_DIR/extensions/herdr-agent-state.ts"

git clone -q --no-hardlinks "$ROOT" "$PROJECT" \
  || fail "could not create the isolated Firstmate project copy"
git -C "$PROJECT" checkout -q --detach "$(git -C "$ROOT" rev-parse HEAD)" \
  || fail "could not align the isolated Firstmate project copy"
git -C "$ROOT" diff --binary HEAD | git -C "$PROJECT" apply \
  || fail "could not overlay the tested Firstmate worktree changes"
while IFS= read -r untracked; do
  [ -n "$untracked" ] || continue
  mkdir -p "$PROJECT/$(dirname "$untracked")"
  cp "$ROOT/$untracked" "$PROJECT/$untracked"
done < <(git -C "$ROOT" ls-files --others --exclude-standard)
mkdir -p "$SCRATCH_PROJECT"
git -C "$SCRATCH_PROJECT" init -q
git -C "$SCRATCH_PROJECT" config user.name 'Firstmate Tests'
git -C "$SCRATCH_PROJECT" config user.email 'tests@example.invalid'
printf '# live recovery fixture\n' > "$SCRATCH_PROJECT/README.md"
git -C "$SCRATCH_PROJECT" add README.md
git -C "$SCRATCH_PROJECT" commit -qm initial
git clone -q --bare "$SCRATCH_PROJECT" "$TMP_ROOT/project.origin.git"
git -C "$SCRATCH_PROJECT" remote add origin "file://$TMP_ROOT/project.origin.git"

cat > "$PI_DIR/extensions/zz-topic-home-capture.ts" <<'TS'
import { appendFileSync, readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";

const capturePath = process.env.FM_PI_HOME_RECOVERY_CAPTURE!;
const phasePath = process.env.FM_PI_HOME_RECOVERY_PHASE!;
const spawnScript = process.env.FM_PI_HOME_RECOVERY_SPAWN!;
const fakebin = process.env.FM_PI_HOME_RECOVERY_FAKEBIN!;
const originalPath = process.env.FM_PI_HOME_RECOVERY_ORIGINAL_PATH!;
process.env.PATH = `${fakebin}:${originalPath}`;

function role(): string {
  return process.env.FM_TASK_ID ? `worker-${process.env.FM_TASK_ID}` : "primary";
}

function record(phase: string, reason: unknown = null, sessionFile: unknown = null): void {
  appendFileSync(capturePath, `${JSON.stringify({
    phase,
    reason: typeof reason === "string" ? reason : null,
    role: role(),
    pid: process.pid,
    fm_home: process.env.FM_HOME ?? null,
    fm_root_override: process.env.FM_ROOT_OVERRIDE ?? null,
    fm_task_id: process.env.FM_TASK_ID ?? null,
    herdr_session: process.env.HERDR_SESSION ?? null,
    herdr_workspace: process.env.HERDR_WORKSPACE_ID ?? null,
    herdr_tab: process.env.HERDR_TAB_ID ?? null,
    herdr_pane: process.env.HERDR_PANE_ID ?? null,
    session_file: typeof sessionFile === "string" ? sessionFile : null,
    argv: process.argv,
  })}\n`);
}

record("extension-load");

export default function (pi: any): void {
  pi.on("project_trust", () => ({ trusted: "yes", remember: false }));
  pi.on("session_start", (event: any, ctx: any) => {
    if (event?.reason === "startup") {
      ctx?.sessionManager?.appendMessage?.({
        role: "user",
        content: `Provider-free live recovery fixture for ${role()}`,
        timestamp: Date.now(),
      });
      ctx?.sessionManager?.appendMessage?.({
        role: "assistant",
        content: [{ type: "text", text: "Fixture session is ready." }],
        api: "provider-free-live-fixture",
        provider: "provider-free-live-fixture",
        model: "provider-free-live-fixture",
        usage: {
          input: 0,
          output: 0,
          cacheRead: 0,
          cacheWrite: 0,
          totalTokens: 0,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
        },
        stopReason: "stop",
        timestamp: Date.now(),
      });
    }
    const sessionFile = ctx?.sessionManager?.getSessionFile?.();
    record("session-start", event?.reason, sessionFile);
    if (role() !== "primary") return;
    let spawnPhase = "";
    try {
      spawnPhase = readFileSync(phasePath, "utf8").trim();
    } catch {
      return;
    }
    if (spawnPhase !== "before" && spawnPhase !== "after") return;
    try {
      execFileSync(spawnScript, [spawnPhase], { stdio: "ignore", timeout: 120000 });
      record("spawn-complete", spawnPhase, sessionFile);
    } catch (error) {
      record("spawn-failed", String(error), sessionFile);
      throw error;
    }
  });
}
TS

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
helper='$LAB_HELPER'
session='$SESSION'
real_path='$ORIGINAL_PATH'
lab_home='$LAB_HOME'
pi_dir='$PI_DIR'
capture='$CAPTURE'
phase='$PHASE'
spawn_script='$SPAWN_SCRIPT'
fakebin='$FAKEBIN'
args=("\$@")
n=\${#args[@]}
if [ "\$n" -eq 2 ] && [ "\${args[0]}" = status ] && [ "\${args[1]}" = --json ]; then
  : # fm_backend_herdr_version_check's machine-owned client probe
elif [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "\$session" ] \
    || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session \$session" >&2
  exit 98
fi
exec env -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_TASK_ID \
  HOME="\$lab_home" PATH="\$real_path" PI_CODING_AGENT_DIR="\$pi_dir" \
  FM_PI_HOME_RECOVERY_CAPTURE="\$capture" FM_PI_HOME_RECOVERY_PHASE="\$phase" \
  FM_PI_HOME_RECOVERY_SPAWN="\$spawn_script" FM_PI_HOME_RECOVERY_FAKEBIN="\$fakebin" \
  FM_PI_HOME_RECOVERY_ORIGINAL_PATH="\$real_path" \
  "\$helper" run "\$session" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

cat > "$FAKEBIN/pi" <<EOF
#!/usr/bin/env bash
set -euo pipefail
args=("\$@")
n=\${#args[@]}
if [ "\$n" -gt 0 ] && [[ "\${args[\$((n-1))]}" == *launch-brief:* ]]; then
  args=("\${args[@]:0:\$((n-1))}")
fi
exec '$REAL_PI' "\${args[@]}"
EOF
chmod +x "$FAKEBIN/pi"

cat > "$SPAWN_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail
phase=\${1:?}
id="live-\$phase"
marker='$TMP_ROOT/spawn-'"\$phase"'.done'
[ ! -e "\$marker" ] || exit 0
mkdir -p '$TOPIC_HOME/data/'"\$id" '$TOPIC_HOME/state'
cat > '$TOPIC_HOME/data/'"\$id"'/brief.md' <<BRIEF
# Task
## Captain's intent
Verify native Pi worker recovery for \$phase.

## Firstmate spec
Keep the live guard worker idle.

Delivery contract: mode=no-mistakes
BRIEF
cat > '$TOPIC_HOME/state/'"\$id"'.pi-ext.ts' <<EXT
export default function () {}
EXT
FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 \
FM_HOME='$TOPIC_HOME' FM_ROOT_OVERRIDE='$PROJECT' \
'$PROJECT/bin/fm-spawn.sh' "\$id" '$SCRATCH_PROJECT' pi \
  --mode no-mistakes --yolo off --backend herdr \
  > '$TMP_ROOT/spawn-'"\$phase"'.out' 2> '$TMP_ROOT/spawn-'"\$phase"'.err'
: > "\$marker"
EOF
chmod +x "$SPAWN_SCRIPT"

cat > "$LAUNCH_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export HOME='$LAB_HOME'
export PATH='$FAKEBIN:$ORIGINAL_PATH'
export PI_CODING_AGENT_DIR='$PI_DIR'
export FM_PI_HOME_RECOVERY_CAPTURE='$CAPTURE'
export FM_PI_HOME_RECOVERY_PHASE='$PHASE'
export FM_PI_HOME_RECOVERY_SPAWN='$SPAWN_SCRIPT'
export FM_PI_HOME_RECOVERY_FAKEBIN='$FAKEBIN'
export FM_PI_HOME_RECOVERY_ORIGINAL_PATH='$ORIGINAL_PATH'
exec '$PROJECT/bin/fm' '$TOPIC'
EOF
chmod +x "$LAUNCH_SCRIPT"
printf 'before\n' > "$PHASE"

workspace_of_pane() {
  lab pane get "$1" 2>/dev/null | jq -r '.result.pane.workspace_id // empty'
}

wait_for_capture() {
  local predicate=$1
  for _ in $(seq 1 360); do
    if [ -s "$CAPTURE" ] && jq -s -e "$predicate" "$CAPTURE" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

wait_for_file() {
  local file=$1
  for _ in $(seq 1 360); do
    [ -s "$file" ] && return 0
    sleep 0.25
  done
  return 1
}

OPERATOR_JSON=$(lab workspace create --cwd "$PROJECT" --label operator-shell --no-focus) \
  || fail "could not create the isolated operator workspace"
PRIMARY_WORKSPACE=$(printf '%s' "$OPERATOR_JSON" | jq -er '.result.workspace.workspace_id') \
  || fail "operator workspace creation omitted its id"
PRIMARY_PANE=$(printf '%s' "$OPERATOR_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "operator workspace creation omitted its pane"
UNRELATED_JSON=$(lab workspace create --cwd "$PROJECT" --label unrelated-focused --no-focus) \
  || fail "could not create the unrelated workspace"
UNRELATED_TAB=$(printf '%s' "$UNRELATED_JSON" | jq -er '.result.tab.tab_id') \
  || fail "unrelated workspace creation omitted its tab"
lab tab focus "$UNRELATED_TAB" >/dev/null \
  || fail "could not focus the unrelated workspace"

lab pane run "$PRIMARY_PANE" "$LAUNCH_SCRIPT" >/dev/null \
  || fail "could not begin the real operator path with fm <topic>"
wait_for_capture 'any(.[]; .phase == "spawn-complete" and .reason == "before")' \
  || fail "the initial Firstmate session did not spawn its real Pi worker"
wait_for_file "$TOPIC_HOME/state/live-before.meta" \
  || fail "the initial worker did not publish task metadata"
wait_for_capture 'any(.[]; .phase == "session-start" and .role == "worker-live-before" and .fm_home == "'"$TOPIC_HOME"'" and .fm_task_id == "live-before")' \
  || fail "the initial real Pi worker did not start with its topic home and task identity"
INITIAL_WORKER=$(jq -sr '[.[] | select(.phase == "session-start" and .role == "worker-live-before")][-1]' "$CAPTURE")
INITIAL_WORKER_PID=$(printf '%s' "$INITIAL_WORKER" | jq -er '.pid') \
  || fail "the initial worker capture omitted its process id"
INITIAL_WORKER_SESSION=$(printf '%s' "$INITIAL_WORKER" | jq -er '.session_file') \
  || fail "the initial worker capture omitted its Pi session"
[ -f "$INITIAL_WORKER_SESSION" ] \
  || fail "the initial real Pi worker did not persist its topic-home session"
[ ! -e "$TOPIC_HOME/config/herdr-presentation-spaces" ] \
  || fail "the live guard must prove absent-config behavior, not an opt-out override"
[ ! -e "$TOPIC_HOME/state/live-before.herdr-presentation" ] \
  || fail "a topic worker created a separate presentation workspace"

INITIAL_PRIMARY=$(jq -sr '[.[] | select(.phase == "session-start" and .role == "primary")][0]' "$CAPTURE")
INITIAL_PRIMARY_PID=$(printf '%s' "$INITIAL_PRIMARY" | jq -er '.pid') \
  || fail "the initial primary capture omitted its process id"
INITIAL_PRIMARY_SESSION=$(printf '%s' "$INITIAL_PRIMARY" | jq -er '.session_file') \
  || fail "the initial primary capture omitted its Pi session"
[ -f "$INITIAL_PRIMARY_SESSION" ] \
  || fail "the initial primary Pi session was not persisted under its topic home"
[ "$(printf '%s' "$INITIAL_PRIMARY" | jq -r '.fm_home')" = "$TOPIC_HOME" ] \
  || fail "the initial primary did not use the topic home"
INITIAL_PRIMARY_PANE=$(printf '%s' "$INITIAL_PRIMARY" | jq -er '.herdr_pane') \
  || fail "the initial primary capture omitted its Herdr pane"
[ "$(workspace_of_pane "$INITIAL_PRIMARY_PANE")" = "$PRIMARY_WORKSPACE" ] \
  || fail "fm <topic> did not remain in its initial operator workspace"
BEFORE_PANE=$(sed -n 's/^herdr_pane_id=//p' "$TOPIC_HOME/state/live-before.meta")
[ -n "$BEFORE_PANE" ] || fail "the initial worker metadata omitted its pane"
[ "$(workspace_of_pane "$BEFORE_PANE")" = "$PRIMARY_WORKSPACE" ] \
  || fail "the initial worker was not a tab in the exact primary workspace"
pass "fm <topic> keeps an absent-config worker as a tab in the initial workspace, not the focused workspace"

printf 'after\n' > "$PHASE"
helper stop "$SESSION" >/dev/null \
  || fail "could not stop only the isolated Herdr lab"
helper provision "$SESSION" \
  || fail "could not restart only the isolated Herdr lab"

if ! wait_for_capture "any(.[]; .phase == \"session-start\" and .role == \"primary\" and .pid != $INITIAL_PRIMARY_PID and .fm_home == \"$TOPIC_HOME\")"; then
  printf '%s\n' 'diagnostic: Pi startup capture after native Herdr restart:' >&2
  cat "$CAPTURE" >&2
  printf '%s\n' 'diagnostic: primary pane after native Herdr restart:' >&2
  lab pane read "$INITIAL_PRIMARY_PANE" --source recent --lines 200 >&2 || true
  printf '%s\n' 'diagnostic: worker pane after native Herdr restart:' >&2
  lab pane read "$BEFORE_PANE" --source recent --lines 200 >&2 || true
  fail "native Herdr recovery did not restore the primary with its topic home"
fi
RESTORED_PRIMARY=$(jq -sr --argjson initial "$INITIAL_PRIMARY_PID" \
  '[.[] | select(.phase == "session-start" and .role == "primary" and .pid != $initial)][-1]' "$CAPTURE")
RESTORED_PRIMARY_PANE=$(printf '%s' "$RESTORED_PRIMARY" | jq -er '.herdr_pane') \
  || fail "the restored primary capture omitted its Herdr pane"
[ "$(printf '%s' "$RESTORED_PRIMARY" | jq -r '.session_file')" = "$INITIAL_PRIMARY_SESSION" ] \
  || fail "native recovery selected a different primary Pi session"
[ "$(workspace_of_pane "$RESTORED_PRIMARY_PANE")" = "$PRIMARY_WORKSPACE" ] \
  || fail "native recovery moved the primary away from its initial workspace"

wait_for_capture "any(.[]; .phase == \"session-start\" and .role == \"worker-live-before\" and .pid != $INITIAL_WORKER_PID and .fm_home == \"$TOPIC_HOME\" and .fm_task_id == \"live-before\")" \
  || fail "native Herdr recovery did not restore the pre-restart worker home and task identity"
RESTORED_BEFORE=$(jq -sr --argjson initial "$INITIAL_WORKER_PID" \
  '[.[] | select(.phase == "session-start" and .role == "worker-live-before" and .pid != $initial)][-1]' "$CAPTURE")
RESTORED_BEFORE_PANE=$(printf '%s' "$RESTORED_BEFORE" | jq -er '.herdr_pane') \
  || fail "the restored worker capture omitted its Herdr pane"
[ "$(printf '%s' "$RESTORED_BEFORE" | jq -r '.session_file')" = "$INITIAL_WORKER_SESSION" ] \
  || fail "native recovery selected a different worker Pi session"
[ "$(workspace_of_pane "$RESTORED_BEFORE_PANE")" = "$PRIMARY_WORKSPACE" ] \
  || fail "native recovery moved the existing worker out of the initial primary workspace"

wait_for_capture 'any(.[]; .phase == "spawn-complete" and .reason == "after")' \
  || fail "the restored primary did not spawn a post-recovery worker"
wait_for_file "$TOPIC_HOME/state/live-after.meta" \
  || fail "the post-recovery worker did not publish task metadata"
AFTER_PANE=$(sed -n 's/^herdr_pane_id=//p' "$TOPIC_HOME/state/live-after.meta")
[ -n "$AFTER_PANE" ] || fail "the post-recovery worker metadata omitted its pane"
[ "$(workspace_of_pane "$AFTER_PANE")" = "$PRIMARY_WORKSPACE" ] \
  || fail "the post-recovery worker was not a tab in the initial primary workspace"
wait_for_capture 'any(.[]; .phase == "session-start" and .role == "worker-live-after" and .fm_home == "'"$TOPIC_HOME"'" and .fm_task_id == "live-after")' \
  || fail "the post-recovery Pi worker did not inherit the restored topic home"
[ ! -e "$TOPIC_HOME/state/live-after.herdr-presentation" ] \
  || fail "the post-recovery topic worker created a separate presentation workspace"
pass "native Herdr restart restores primary and worker homes, preserves the initial workspace, and places the next worker there"

jq -s -e --arg session "$SESSION" --arg home "$TOPIC_HOME" '
  [.[] | select(.phase == "session-start" and (.role == "primary" or (.role | startswith("worker-"))))]
  | length >= 4
    and all(.[]; .herdr_session == $session and .fm_home == $home)
' "$CAPTURE" >/dev/null \
  || fail "one or more recovered Pi processes carried a foreign session or home identity"
pass "every observed primary and worker Pi process is bound to the exact named topic session and canonical home"

PI_VERSION=$(pi --version 2>/dev/null | head -1)
if ! cleanup_all; then
  trap - EXIT
  fail "isolated Herdr lab cleanup failed or the default session changed"
fi
trap - EXIT
pass "isolated Herdr recovery lab is removed with the default session unchanged"
printf 'evidence: herdr-client=%s protocol=%s herdr-server=%s protocol=%s pi=%s integration=%s\n' \
  "$HERDR_CLIENT_VERSION" "$HERDR_CLIENT_PROTOCOL" \
  "$HERDR_SERVER_VERSION" "$HERDR_SERVER_PROTOCOL" \
  "$PI_VERSION" "$PI_INTEGRATION_VERSION"
