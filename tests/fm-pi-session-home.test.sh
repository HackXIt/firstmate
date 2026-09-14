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
mkdir -p "$PROJECT" "$SESSION_DIR" "$HOME_DIR/config" "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/projects"
printf 'version=1\nhome=%s\nroot=%s\n' "$HOME_DIR" "$PROJECT" > "$HOME_DIR/.fm-topic-home"
chmod 600 "$HOME_DIR/.fm-topic-home"
chmod 775 "$HOME_DIR" "$HOME_DIR/config" "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/projects" "$SESSION_DIR"
printf '{"type":"session","version":3,"id":"session-id","timestamp":"2026-01-01T00:00:00.000Z","cwd":"%s"}\n' "$PROJECT" > "$SESSION"

FM_PI_SESSION_HOME_MODULE="$ROOT/.pi/extensions/lib/fm-pi-session-home.ts" \
FM_PI_SESSION_HOME_PROJECT="$PROJECT" \
FM_PI_SESSION_HOME_HOME="$HOME_DIR" \
FM_PI_SESSION_HOME_SESSION="$SESSION" \
HERDR_ENV=1 \
node --input-type=module <<'JS'
import { pathToFileURL } from "node:url";
import { mkdirSync, symlinkSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

const modulePath = process.env.FM_PI_SESSION_HOME_MODULE;
const project = process.env.FM_PI_SESSION_HOME_PROJECT;
const home = process.env.FM_PI_SESSION_HOME_HOME;
const session = process.env.FM_PI_SESSION_HOME_SESSION;
const { restoreFirstmateHomeFromPiSession } = await import(pathToFileURL(modulePath).href);

function reset() {
  delete process.env.FM_HOME;
  delete process.env.FM_ROOT_OVERRIDE;
  process.env.HERDR_ENV = "1";
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function expectRefusal(args, message) {
  reset();
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

reset();
process.env.FM_HOME = "/explicit/home";
const explicit = restoreFirstmateHomeFromPiSession(project, ["--session", session]);
assert(explicit === undefined, "explicit FM_HOME should suppress recovery");
assert(process.env.FM_HOME === "/explicit/home", "explicit FM_HOME was overwritten");
assert(process.env.FM_ROOT_OVERRIDE === undefined, "recovery partially mutated an explicit environment");
console.log("ok - explicit Firstmate environment remains authoritative");

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
writeFileSync(resolve(otherHome, ".fm-topic-home"), `version=1\nhome=${otherHome}\nroot=${project}\n`, { mode: 0o600 });
const mismatched = resolve(mismatchedDirectory, "session.jsonl");
writeFileSync(mismatched, '{"type":"session","version":3,"id":"wrong-cwd","timestamp":"2026-01-01T00:00:00.000Z","cwd":"/foreign/project"}\n');
expectRefusal(["--session", mismatched], "a session for another project was trusted");
console.log("ok - session header must bind the shared Firstmate checkout");

expectRefusal(["--session", "session.jsonl"], "a relative session path was trusted");
console.log("ok - relative or unresolved session references are refused");
JS
node_status=$?
if [ "$node_status" -ne 0 ]; then
  exit "$node_status"
fi

command -v pi >/dev/null 2>&1 || { echo "skip: pi not found for executable restore regression"; exit 0; }

mkdir -p "$PROJECT/.pi/extensions/lib" "$PROJECT/bin"
cp "$ROOT/.pi/extensions/fm-calm.ts" "$PROJECT/.pi/extensions/fm-calm.ts"
cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$PROJECT/.pi/extensions/fm-primary-pi-watch.ts"
cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$PROJECT/.pi/extensions/fm-primary-turnend-guard.ts"
cp "$ROOT/.pi/extensions/lib/"*.ts "$PROJECT/.pi/extensions/lib/"
for script in fm-sessionstart-run.sh fm-turnend-guard.sh fm-arm-pretool-check.sh fm-cd-pretool-check.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$PROJECT/bin/$script"
  chmod +x "$PROJECT/bin/$script"
done
rm -f "$HOME_DIR/state/.pi-turnend-extension-loaded" "$HOME_DIR/state/.pi-watch-extension-loaded"

(
  cd "$PROJECT" || exit 1
  env -u FM_HOME -u FM_ROOT_OVERRIDE \
    HOME="$TMP_ROOT/user-home" HERDR_ENV=1 PI_OFFLINE=1 \
    pi --mode rpc --approve --no-context-files --no-skills --no-prompt-templates --no-themes --no-extensions \
      -e .pi/extensions/fm-calm.ts \
      -e .pi/extensions/fm-primary-turnend-guard.ts \
      -e .pi/extensions/fm-primary-pi-watch.ts \
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
printf 'ok - pi --session loads Firstmate extensions against the recovered topic home\n'
