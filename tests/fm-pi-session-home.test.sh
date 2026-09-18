#!/usr/bin/env bash
# tests/fm-pi-session-home.test.sh - restore topic-home identity from Pi session paths.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-session-home.XXXXXX")
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

PROJECT="$TMP_ROOT/firstmate"
HOME_DIR="$TMP_ROOT/topic-home"
SESSION_DIR="$HOME_DIR/pi-sessions"
SESSION="$SESSION_DIR/session.jsonl"
HERDR_TOPIC_SESSION="firstmate-topic-home-test"
mkdir -p "$PROJECT" "$SESSION_DIR" "$HOME_DIR/config" "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/projects"
printf 'version=2\nhome=%s\nroot=%s\nherdr_session=%s\n' "$HOME_DIR" "$PROJECT" "$HERDR_TOPIC_SESSION" > "$HOME_DIR/.fm-topic-home"
chmod 600 "$HOME_DIR/.fm-topic-home"
chmod 775 "$HOME_DIR" "$HOME_DIR/config" "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/projects" "$SESSION_DIR"
printf '{"type":"session","version":3,"id":"session-id","timestamp":"2026-01-01T00:00:00.000Z","cwd":"%s"}\n' "$PROJECT" > "$SESSION"

FM_PI_SESSION_HOME_MODULE="$ROOT/.pi/extensions/lib/fm-pi-session-home.ts" \
FM_PI_SESSION_HOME_PROJECT="$PROJECT" \
FM_PI_SESSION_HOME_HOME="$HOME_DIR" \
FM_PI_SESSION_HOME_SESSION="$SESSION" \
HERDR_ENV=1 \
HERDR_SESSION="$HERDR_TOPIC_SESSION" \
node --input-type=module <<'JS'
import { pathToFileURL } from "node:url";
import { mkdirSync, renameSync, unlinkSync, symlinkSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

const modulePath = process.env.FM_PI_SESSION_HOME_MODULE;
const project = process.env.FM_PI_SESSION_HOME_PROJECT;
const home = process.env.FM_PI_SESSION_HOME_HOME;
const session = process.env.FM_PI_SESSION_HOME_SESSION;
const {
  restoreFirstmateHomeFromOwnedPiSession,
  restoreFirstmateHomeFromPiSession,
  trustedFirstmatePiProject,
} = await import(pathToFileURL(modulePath).href);

function reset() {
  delete process.env.FM_STATE_OVERRIDE;
  delete process.env.FM_HOME;
  delete process.env.FM_ROOT_OVERRIDE;
  delete process.env.FM_TASK_ID;
  delete process.env.FM_PI_RECOVERED_WORKER_EXTENSION;
  delete process.env.FM_PI_TOPIC_LAUNCH;
  process.env.HERDR_ENV = "1";
  process.env.HERDR_SESSION = "firstmate-topic-home-test";
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function expectRefusal(args, message, herdrSession = "firstmate-topic-home-test") {
  reset();
  process.env.HERDR_SESSION = herdrSession;
  let refused = false;
  try {
    restoreFirstmateHomeFromPiSession(project, args);
  } catch (error) {
    refused = String(error).includes("Firstmate topic-session recovery refused:");
  }
  assert(refused, message);
  assert(process.env.FM_HOME === undefined, `${message}: FM_HOME was mutated`);
  assert(process.env.FM_ROOT_OVERRIDE === undefined, `${message}: FM_ROOT_OVERRIDE was mutated`);
}

reset();
const restored = restoreFirstmateHomeFromPiSession(project, ["--session", session]);
assert(restored === home, `expected ${home}, got ${restored}`);
assert(process.env.FM_HOME === home, "FM_HOME was not restored");
assert(process.env.FM_ROOT_OVERRIDE === project, "FM_ROOT_OVERRIDE was not restored");
console.log("ok - exact Pi session path restores its owning topic home");

expectRefusal(
  ["--session", session],
  "a session from another Herdr topic was trusted",
  "foreign-topic-session",
);
console.log("ok - topic-home recovery refuses a mismatched Herdr session identity");

writeFileSync(resolve(home, ".fm-topic-home"), `version=2\nhome=${home}\nroot=${project}\nherdr_session=firstmate-topic-home-test\nherdr_session=foreign-topic-session\n`);
expectRefusal(["--session", session], "an ambiguous topic binding was trusted");
writeFileSync(resolve(home, ".fm-topic-home"), `version=2\nhome=${home}\nroot=${project}\nherdr_session=firstmate-topic-home-test\n`);
console.log("ok - topic-home recovery refuses duplicate identity fields instead of choosing one");

writeFileSync(resolve(home, ".fm-topic-home"), `version=1\nhome=${home}\nroot=${project}\n`);
expectRefusal(["--session", session], "a legacy topic marker without an exact Herdr session was trusted");
writeFileSync(resolve(home, ".fm-topic-home"), `version=2\nhome=${home}\nroot=${project}\nherdr_session=firstmate-topic-home-test\n`);
console.log("ok - recovery refuses an unbound legacy marker until fm <topic> renews it");

reset();
process.env.FM_HOME = home;
process.env.FM_ROOT_OVERRIDE = project;
assert(restoreFirstmateHomeFromPiSession(project, ["--session", session]) === home, "matching ambient identity was not validated");
console.log("ok - matching ambient Firstmate identity is validated against the resumed Pi session");

reset();
process.env.FM_HOME = "/foreign/home";
let ambientRefused = false;
try {
  restoreFirstmateHomeFromPiSession(project, ["--session", session]);
} catch (error) {
  ambientRefused = String(error).includes("recovery refused");
}
assert(ambientRefused, "a foreign ambient Firstmate home bypassed session validation");
console.log("ok - recovery refuses a foreign ambient home instead of trusting inherited process state");

reset();
process.env.HERDR_ENV = "0";
assert(
  restoreFirstmateHomeFromPiSession(project, ["--session", session]) === undefined,
  "a non-Herdr Pi resume restored a topic home",
);
assert(process.env.FM_HOME === undefined, "a non-Herdr Pi resume set FM_HOME");
console.log("ok - manual Pi resumes outside Herdr remain unchanged");

expectRefusal(
  ["--session", session, "--session", session],
  "multiple session selectors were not refused",
);
console.log("ok - multiple Pi session selectors are refused as ambiguous");

expectRefusal(
  [`--session=${session}`],
  "Pi's unsupported equals-form session flag was not refused",
);
console.log("ok - unsupported equals-form session selectors are refused");

const linkedSession = resolve(dirname(session), "linked.jsonl");
symlinkSync(session, linkedSession);
expectRefusal(["--session", linkedSession], "a symlinked session was trusted");
console.log("ok - symlinked session files cannot redirect topic-home recovery");

const foreignDirectory = resolve(home, "other-sessions");
mkdirSync(foreignDirectory, { recursive: true });
const foreignLocation = resolve(foreignDirectory, "session.jsonl");
writeFileSync(foreignLocation, `{"type":"session","version":3,"id":"foreign-location","timestamp":"2026-01-01T00:00:00.000Z","cwd":${JSON.stringify(project)}}\n`);
expectRefusal(["--session", foreignLocation], "a session outside pi-sessions was trusted");
console.log("ok - only a direct pi-sessions child can identify a topic home");

const otherHome = resolve(dirname(home), "other-home");
const mismatchedDirectory = resolve(otherHome, "pi-sessions");
mkdirSync(mismatchedDirectory, { recursive: true });
for (const child of ["config", "data", "state", "projects"]) mkdirSync(resolve(otherHome, child));
writeFileSync(resolve(otherHome, ".fm-topic-home"), `version=2\nhome=${otherHome}\nroot=${project}\nherdr_session=firstmate-topic-home-test\n`, { mode: 0o600 });
const mismatched = resolve(mismatchedDirectory, "session.jsonl");
writeFileSync(mismatched, '{"type":"session","version":3,"id":"wrong-cwd","timestamp":"2026-01-01T00:00:00.000Z","cwd":"/foreign/project"}\n');
expectRefusal(["--session", mismatched], "a session for another project was trusted");
console.log("ok - session header must bind the shared Firstmate checkout or one exact recorded worker");

const worker = resolve(dirname(home), "worker-copy");
mkdirSync(worker, { recursive: true });
writeFileSync(resolve(home, "state", "worker-a.meta"), [
  "endpoint_task_id=worker-a",
  "backend=herdr",
  "harness=pi",
  "kind=ship",
  `worktree=${worker}`,
  "herdr_session=firstmate-topic-home-test",
  "",
].join("\n"));
writeFileSync(resolve(home, "state", "worker-a.pi-ext.ts"), "export default function () {}\n");
const workerSession = resolve(dirname(session), "worker-session.jsonl");
writeFileSync(workerSession, `{"type":"session","version":3,"id":"worker-session","timestamp":"2026-01-01T00:00:00.000Z","cwd":${JSON.stringify(worker)}}\n`);
reset();
assert(restoreFirstmateHomeFromPiSession(project, ["--session", workerSession]) === home, "worker session did not restore its topic home");
assert(process.env.FM_TASK_ID === "worker-a", "worker session did not restore its exact task identity");
assert(process.env.FM_PI_RECOVERED_WORKER_EXTENSION === resolve(home, "state", "worker-a.pi-ext.ts"), "worker session did not bind its generated extension");
console.log("ok - exact worker metadata binds a resumed worker session to its topic home and task extension");

const externalState = resolve(dirname(home), "external-state");
renameSync(resolve(home, "state"), externalState);
mkdirSync(resolve(home, "state"));
const stateBinding = resolve(home, ".fm-pi-state");
writeFileSync(stateBinding, `home=${home}\nroot=${project}\nherdr_session=firstmate-topic-home-test\nstate=${externalState}\n`);
reset();
assert(restoreFirstmateHomeFromPiSession(project, ["--session", workerSession]) === home, "external-state worker recovery failed");
assert(process.env.FM_STATE_OVERRIDE === externalState, "effective state directory was not restored");
assert(process.env.FM_PI_RECOVERED_WORKER_EXTENSION === resolve(externalState, "worker-a.pi-ext.ts"), "worker extension was not recovered from external state");
writeFileSync(stateBinding, `home=${home}\nroot=${project}\nherdr_session=foreign-topic\nstate=${externalState}\n`);
expectRefusal(["--session", workerSession], "foreign state binding was trusted");
unlinkSync(stateBinding);
renameSync(externalState, resolve(home, "state"));
console.log("ok - external worker state is restored only from a matching persisted binding");

reset();
process.env.FM_TASK_ID = "foreign-worker";
let workerIdentityRefused = false;
try {
  restoreFirstmateHomeFromPiSession(project, ["--session", workerSession]);
} catch (error) {
  workerIdentityRefused = String(error).includes("recovery refused");
}
assert(workerIdentityRefused, "a foreign ambient worker identity bypassed session validation");
console.log("ok - worker recovery refuses a foreign ambient task identity");

writeFileSync(resolve(home, "state", "worker-a.meta"), [
  "endpoint_task_id=foreign-task",
  "backend=herdr",
  "harness=pi",
  "kind=ship",
  `worktree=${worker}`,
  "herdr_session=firstmate-topic-home-test",
  "",
].join("\n"));
expectRefusal(["--session", workerSession], "mismatched task metadata was trusted");
writeFileSync(resolve(home, "state", "worker-a.meta"), [
  "endpoint_task_id=worker-a",
  "backend=herdr",
  "harness=pi",
  "kind=ship",
  `worktree=${worker}`,
  "herdr_session=firstmate-topic-home-test",
  "",
].join("\n"));
console.log("ok - worker recovery refuses a mismatched canonical task identity");

writeFileSync(resolve(home, "state", "worker-b.meta"), [
  "endpoint_task_id=worker-b",
  "backend=herdr",
  "harness=pi-signed",
  "kind=scout",
  `worktree=${worker}`,
  "herdr_session=firstmate-topic-home-test",
  "",
].join("\n"));
writeFileSync(resolve(home, "state", "worker-b.pi-ext.ts"), "export default function () {}\n");
expectRefusal(["--session", workerSession], "duplicate worker metadata was guessed through");
console.log("ok - ambiguous worker ownership refuses instead of guessing");

reset();
const unrelatedHome = resolve(dirname(home), "unrelated");
const unrelatedSessions = resolve(unrelatedHome, "pi-sessions");
mkdirSync(unrelatedSessions, { recursive: true });
const unrelated = resolve(unrelatedSessions, "session.jsonl");
writeFileSync(unrelated, `{"type":"session","version":3,"id":"unrelated","timestamp":"2026-01-01T00:00:00.000Z","cwd":${JSON.stringify(worker)}}\n`);
assert(restoreFirstmateHomeFromOwnedPiSession(project, ["--session", unrelated]) === undefined, "the global recovery entry point claimed an unrelated Pi session");
assert(restoreFirstmateHomeFromOwnedPiSession(project, ["--session", unrelated, "--session", unrelated]) === undefined, "the global recovery entry point rejected an ambiguous unrelated Pi session");
assert(restoreFirstmateHomeFromOwnedPiSession(project, [`--session=${unrelated}`]) === undefined, "the global recovery entry point rejected an unsupported unrelated Pi selector");
console.log("ok - global recovery ignores Pi sessions with no Firstmate topic-home binding");

reset();
let malformedOwnedRefused = false;
try {
  restoreFirstmateHomeFromOwnedPiSession(project, ["--session", "--session", session]);
} catch (error) {
  malformedOwnedRefused = String(error).includes("recovery refused");
}
assert(malformedOwnedRefused, "a malformed selector before an owned topic session bypassed recovery refusal");
console.log("ok - global recovery refuses a malformed invocation that also claims a topic session");

expectRefusal(["--session", "session.jsonl"], "a relative session path was trusted");
console.log("ok - relative or unresolved session references are refused");

reset();
process.env.FM_PI_TOPIC_LAUNCH = "1";
process.env.FM_HOME = home;
process.env.FM_ROOT_OVERRIDE = project;
process.chdir(project);
assert(trustedFirstmatePiProject(project) === project, "the launcher's validated primary project was not trusted");
console.log("ok - an attested initial fm <topic> launch trusts only its validated primary project");
JS
node_status=$?
if [ "$node_status" -ne 0 ]; then
  exit "$node_status"
fi

command -v pi >/dev/null 2>&1 || { echo "skip: pi not found for executable restore regression"; exit 0; }

PRIMARY_PI_DIR="$TMP_ROOT/primary-pi-agent"
PRIMARY_TRUST_MARKER="$TMP_ROOT/primary-project-trusted"
mkdir -p "$PROJECT/.pi/extensions/lib" "$PROJECT/bin" "$PRIMARY_PI_DIR/extensions"
cp "$ROOT/.pi/extensions/fm-topic-home-recovery.ts" "$PROJECT/.pi/extensions/fm-topic-home-recovery.ts"
cp "$ROOT/.pi/extensions/fm-calm.ts" "$PROJECT/.pi/extensions/fm-calm.ts"
cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$PROJECT/.pi/extensions/fm-primary-pi-watch.ts"
cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$PROJECT/.pi/extensions/fm-primary-turnend-guard.ts"
cp "$ROOT/.pi/extensions/lib/"*.ts "$PROJECT/.pi/extensions/lib/"
ln -s "$PROJECT/.pi/extensions/fm-topic-home-recovery.ts" \
  "$PRIMARY_PI_DIR/extensions/fm-topic-home-recovery.ts"
cat > "$PROJECT/.pi/extensions/fm-trust-proof.ts" <<'TS'
import { writeFileSync } from "node:fs";
writeFileSync(process.env.FM_PI_TRUST_PROOF!, "trusted\n");
export default function () {}
TS
for script in fm-sessionstart-run.sh fm-turnend-guard.sh fm-arm-pretool-check.sh fm-cd-pretool-check.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$PROJECT/bin/$script"
  chmod +x "$PROJECT/bin/$script"
done
rm -f "$HOME_DIR/state/.pi-turnend-extension-loaded" "$HOME_DIR/state/.pi-watch-extension-loaded"

(
  cd "$PROJECT" || exit 1
  env -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_TASK_ID -u FM_STATE_OVERRIDE \
    HOME="$TMP_ROOT/user-home" PI_CODING_AGENT_DIR="$PRIMARY_PI_DIR" \
    FM_PI_TRUST_PROOF="$PRIMARY_TRUST_MARKER" \
    HERDR_ENV=1 HERDR_SESSION="$HERDR_TOPIC_SESSION" PI_OFFLINE=1 \
    pi --mode rpc --no-context-files --no-skills --no-prompt-templates --no-themes \
      --session "$SESSION" </dev/null > "$TMP_ROOT/pi-rpc.out" 2> "$TMP_ROOT/pi-rpc.err"
)
status=$?
if [ "$status" -ne 0 ]; then
  printf 'not ok - Pi executable restore failed (%s)\n--- stdout ---\n' "$status" >&2
  cat "$TMP_ROOT/pi-rpc.out" >&2
  printf '%s\n' '--- stderr ---' >&2
  cat "$TMP_ROOT/pi-rpc.err" >&2
  exit 1
fi
[ -f "$HOME_DIR/state/.pi-turnend-extension-loaded" ] \
  || { echo "not ok - Pi guard extension did not bind the recovered topic home" >&2; exit 1; }
[ -f "$HOME_DIR/state/.pi-watch-extension-loaded" ] \
  || { echo "not ok - Pi watcher extension did not bind the recovered topic home" >&2; exit 1; }
[ ! -e "$PROJECT/state/.pi-turnend-extension-loaded" ] \
  || { echo "not ok - Pi guard extension touched shared-root state" >&2; exit 1; }
[ ! -e "$PROJECT/state/.pi-watch-extension-loaded" ] \
  || { echo "not ok - Pi watcher extension touched shared-root state" >&2; exit 1; }
[ -f "$PRIMARY_TRUST_MARKER" ] \
  || { echo "not ok - recovered primary stopped before trusting its validated Firstmate project" >&2; exit 1; }
printf 'ok - pi --session trusts and loads Firstmate extensions against the recovered topic home\n'

for rejection in legacy mismatched-session foreign-home; do
  rm -f "$HOME_DIR/state/.pi-turnend-extension-loaded" "$HOME_DIR/state/.pi-watch-extension-loaded"
  mkdir -p "$PROJECT/state" "$TMP_ROOT/foreign-home/state"
  if [ "$rejection" = legacy ]; then
    printf 'version=1\nhome=%s\nroot=%s\n' "$HOME_DIR" "$PROJECT" > "$HOME_DIR/.fm-topic-home"
  else
    printf 'version=2\nhome=%s\nroot=%s\nherdr_session=%s\n' "$HOME_DIR" "$PROJECT" "$HERDR_TOPIC_SESSION" > "$HOME_DIR/.fm-topic-home"
  fi
  (
    cd "$PROJECT" || exit 1
    unset FM_HOME FM_ROOT_OVERRIDE FM_TASK_ID FM_STATE_OVERRIDE
    export HOME="$TMP_ROOT/user-home" HERDR_ENV=1 HERDR_SESSION="$HERDR_TOPIC_SESSION" PI_OFFLINE=1
    [ "$rejection" != mismatched-session ] || export HERDR_SESSION=foreign-topic
    [ "$rejection" != foreign-home ] || export FM_HOME="$TMP_ROOT/foreign-home"
    pi --mode rpc --approve --no-context-files --no-skills --no-prompt-templates --no-themes --no-extensions \
      -e .pi/extensions/fm-topic-home-recovery.ts \
      -e .pi/extensions/fm-calm.ts \
      -e .pi/extensions/fm-primary-turnend-guard.ts \
      -e .pi/extensions/fm-primary-pi-watch.ts \
      --session "$SESSION" </dev/null > "$TMP_ROOT/pi-rejected.out" 2> "$TMP_ROOT/pi-rejected.err"
  )
  for rejected_home in "$HOME_DIR" "$PROJECT" "$TMP_ROOT/foreign-home"; do
    for marker in .pi-turnend-extension-loaded .pi-watch-extension-loaded; do
      [ ! -e "$rejected_home/state/$marker" ] \
        || { echo "not ok - rejected $rejection recovery initialized $rejected_home/$marker" >&2; exit 1; }
    done
  done
  printf 'ok - rejected %s recovery prevents consumer initialization\n' "$rejection"
done

WORKER_HOME="$TMP_ROOT/executable-worker-home"
WORKER_COPY="$TMP_ROOT/executable-worker-copy"
WORKER_SESSION="$WORKER_HOME/pi-sessions/session.jsonl"
WORKER_EXTENSION_MARKER="$TMP_ROOT/recovered-worker-extension.loaded"
WORKER_STATE="$TMP_ROOT/executable-worker-state"
mkdir -p "$WORKER_STATE"
GLOBAL_PI_DIR="$TMP_ROOT/pi-agent"
WORKER_TRUST_MARKER="$TMP_ROOT/worker-project-trusted"
mkdir -p "$WORKER_COPY/.pi/extensions" "$WORKER_HOME/config" "$WORKER_HOME/data" "$WORKER_HOME/state" \
  "$WORKER_HOME/projects" "$WORKER_HOME/pi-sessions" "$GLOBAL_PI_DIR/extensions"
ln -s "$ROOT/.pi/extensions/fm-topic-home-recovery.ts" \
  "$GLOBAL_PI_DIR/extensions/fm-topic-home-recovery.ts"
printf 'version=2\nhome=%s\nroot=%s\nherdr_session=%s\n' \
  "$WORKER_HOME" "$ROOT" "$HERDR_TOPIC_SESSION" > "$WORKER_HOME/.fm-topic-home"
printf 'home=%s\nroot=%s\nherdr_session=%s\nstate=%s\n' \
  "$WORKER_HOME" "$ROOT" "$HERDR_TOPIC_SESSION" "$WORKER_STATE" > "$WORKER_HOME/.fm-pi-state"
printf 'endpoint_task_id=worker-live\nbackend=herdr\nharness=pi\nkind=ship\nworktree=%s\nherdr_session=%s\n' \
  "$WORKER_COPY" "$HERDR_TOPIC_SESSION" > "$WORKER_STATE/worker-live.meta"
cat > "$WORKER_STATE/worker-live.pi-ext.ts" <<EOF
import { writeFileSync } from "node:fs";
if (process.env.FM_STATE_OVERRIDE !== ${WORKER_STATE@Q}) throw new Error("state override was not restored");
writeFileSync(${WORKER_EXTENSION_MARKER@Q}, "loaded\\n");
export default function () {}
EOF
cat > "$WORKER_COPY/.pi/extensions/fm-trust-proof.ts" <<EOF
import { writeFileSync } from "node:fs";
writeFileSync(${WORKER_TRUST_MARKER@Q}, "trusted\\n");
export default function () {}
EOF
printf '{"type":"session","version":3,"id":"worker-live","timestamp":"2026-01-01T00:00:00.000Z","cwd":"%s"}\n' \
  "$WORKER_COPY" > "$WORKER_SESSION"
(
  cd "$WORKER_COPY" || exit 1
  env -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_TASK_ID -u FM_STATE_OVERRIDE \
    HOME="$TMP_ROOT/user-home" PI_CODING_AGENT_DIR="$GLOBAL_PI_DIR" \
    HERDR_ENV=1 HERDR_SESSION="$HERDR_TOPIC_SESSION" PI_OFFLINE=1 \
    pi --mode rpc --no-context-files --no-skills --no-prompt-templates --no-themes \
      --session "$WORKER_SESSION" </dev/null > "$TMP_ROOT/pi-worker-rpc.out" 2> "$TMP_ROOT/pi-worker-rpc.err"
)
status=$?
if [ "$status" -ne 0 ]; then
  printf 'not ok - Pi executable worker recovery failed (%s)\n--- stdout ---\n' "$status" >&2
  cat "$TMP_ROOT/pi-worker-rpc.out" >&2
  printf '%s\n' '--- stderr ---' >&2
  cat "$TMP_ROOT/pi-worker-rpc.err" >&2
  exit 1
fi
[ -f "$WORKER_EXTENSION_MARKER" ] \
  || { echo "not ok - global topic recovery did not reload the worker's generated extension" >&2; exit 1; }
[ -f "$WORKER_TRUST_MARKER" ] \
  || { echo "not ok - recovered worker stopped before trusting its validated project" >&2; exit 1; }
printf 'ok - global Pi recovery trusts a worker project and reloads its generated extension before session_start\n'

printf 'endpoint_task_id=worker-other\nbackend=herdr\nharness=pi\nkind=ship\nworktree=%s\nherdr_session=%s\n' \
  "$WORKER_COPY" "$HERDR_TOPIC_SESSION" > "$WORKER_STATE/worker-other.meta"
printf 'export default function () {}\n' > "$WORKER_STATE/worker-other.pi-ext.ts"
rm -f "$WORKER_TRUST_MARKER"
(
  cd "$WORKER_COPY" || exit 1
  env FM_PI_TOPIC_LAUNCH=1 FM_HOME="$WORKER_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TASK_ID=worker-live HOME="$TMP_ROOT/user-home" PI_CODING_AGENT_DIR="$GLOBAL_PI_DIR" \
    HERDR_ENV=1 HERDR_SESSION="$HERDR_TOPIC_SESSION" PI_OFFLINE=1 \
    pi --mode rpc --no-context-files --no-skills --no-prompt-templates --no-themes \
      --session-dir "$WORKER_HOME/pi-sessions" 'provider-free initial worker fixture' </dev/null \
      > "$TMP_ROOT/pi-initial-worker-rpc.out" 2> "$TMP_ROOT/pi-initial-worker-rpc.err"
)
status=$?
if [ "$status" -ne 0 ]; then
  printf 'not ok - Pi executable initial worker launch failed (%s)\n--- stdout ---\n' "$status" >&2
  cat "$TMP_ROOT/pi-initial-worker-rpc.out" >&2
  printf '%s\n' '--- stderr ---' >&2
  cat "$TMP_ROOT/pi-initial-worker-rpc.err" >&2
  exit 1
fi
[ -f "$WORKER_TRUST_MARKER" ] \
  || { echo "not ok - validated initial worker stopped before trusting its exact worktree" >&2; exit 1; }
printf 'ok - a validated initial Pi worker trusts only its exact task worktree before loading project resources\n'

rm -f "$WORKER_TRUST_MARKER"
(
  cd "$WORKER_COPY" || exit 1
  env FM_PI_TOPIC_LAUNCH=1 FM_HOME="$WORKER_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TASK_ID=worker-missing HOME="$TMP_ROOT/user-home" PI_CODING_AGENT_DIR="$GLOBAL_PI_DIR" \
    HERDR_ENV=1 HERDR_SESSION="$HERDR_TOPIC_SESSION" PI_OFFLINE=1 \
    pi --mode rpc --no-context-files --no-skills --no-prompt-templates --no-themes \
      --session-dir "$WORKER_HOME/pi-sessions" 'mismatched initial worker fixture' </dev/null \
      > "$TMP_ROOT/pi-mismatched-worker-rpc.out" 2> "$TMP_ROOT/pi-mismatched-worker-rpc.err"
)
status=$?
[ "$status" -ne 0 ] \
  || { echo "not ok - a mismatched initial worker task identity was accepted" >&2; exit 1; }
[ ! -e "$WORKER_TRUST_MARKER" ] \
  || { echo "not ok - a mismatched initial worker loaded project resources" >&2; exit 1; }
grep -F 'does not identify one exact task record for this worktree and Herdr topic' \
  "$TMP_ROOT/pi-mismatched-worker-rpc.err" >/dev/null \
  || { echo "not ok - mismatched initial worker refusal omitted its identity diagnostic" >&2; exit 1; }
printf 'ok - initial Pi worker trust refuses a task identity without one exact matching record\n'
