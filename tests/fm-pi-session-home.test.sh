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
printf '{"type":"session","version":3,"id":"session-id","timestamp":"2026-01-01T00:00:00.000Z","cwd":"%s"}\n' "$PROJECT" > "$SESSION"

FM_PI_SESSION_HOME_MODULE="$ROOT/.pi/extensions/lib/fm-pi-session-home.ts" \
FM_PI_SESSION_HOME_PROJECT="$PROJECT" \
FM_PI_SESSION_HOME_HOME="$HOME_DIR" \
FM_PI_SESSION_HOME_SESSION="$SESSION" \
node --input-type=module <<'JS'
import { pathToFileURL } from "node:url";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

const modulePath = process.env.FM_PI_SESSION_HOME_MODULE;
const project = process.env.FM_PI_SESSION_HOME_PROJECT;
const home = process.env.FM_PI_SESSION_HOME_HOME;
const session = process.env.FM_PI_SESSION_HOME_SESSION;
const { restoreFirstmateHomeFromPiSession } = await import(pathToFileURL(modulePath).href);

function reset() {
  delete process.env.FM_HOME;
  delete process.env.FM_ROOT_OVERRIDE;
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

reset();
const restored = restoreFirstmateHomeFromPiSession(project, ["--session", session]);
assert(restored === home, `expected ${home}, got ${restored}`);
assert(process.env.FM_HOME === home, "FM_HOME was not restored");
assert(process.env.FM_ROOT_OVERRIDE === project, "FM_ROOT_OVERRIDE was not restored");
console.log("ok - exact Pi session path restores its owning topic home");

reset();
const equalsRestored = restoreFirstmateHomeFromPiSession(project, [`--session=${session}`]);
assert(equalsRestored === home, "--session=<path> did not restore the topic home");
console.log("ok - equals-form Pi session path restores its owning topic home");

reset();
process.env.FM_HOME = "/explicit/home";
const explicit = restoreFirstmateHomeFromPiSession(project, ["--session", session]);
assert(explicit === undefined, "explicit FM_HOME should suppress recovery");
assert(process.env.FM_HOME === "/explicit/home", "explicit FM_HOME was overwritten");
assert(process.env.FM_ROOT_OVERRIDE === undefined, "recovery partially mutated an explicit environment");
console.log("ok - explicit Firstmate environment remains authoritative");

reset();
const foreignDirectory = resolve(home, "other-sessions");
mkdirSync(foreignDirectory, { recursive: true });
const foreignLocation = resolve(foreignDirectory, "session.jsonl");
writeFileSync(foreignLocation, `{"type":"session","version":3,"id":"foreign-location","timestamp":"2026-01-01T00:00:00.000Z","cwd":${JSON.stringify(project)}}\n`);
assert(
  restoreFirstmateHomeFromPiSession(project, ["--session", foreignLocation]) === undefined,
  "a session outside pi-sessions was trusted",
);
assert(process.env.FM_HOME === undefined, "an unowned session path set FM_HOME");
console.log("ok - only a direct pi-sessions child can identify a topic home");

reset();
const otherHome = resolve(dirname(home), "other-home");
const mismatchedDirectory = resolve(otherHome, "pi-sessions");
mkdirSync(mismatchedDirectory, { recursive: true });
for (const child of ["config", "data", "state", "projects"]) mkdirSync(resolve(otherHome, child));
const mismatched = resolve(mismatchedDirectory, "session.jsonl");
writeFileSync(mismatched, '{"type":"session","version":3,"id":"wrong-cwd","timestamp":"2026-01-01T00:00:00.000Z","cwd":"/foreign/project"}\n');
assert(
  restoreFirstmateHomeFromPiSession(project, ["--session", mismatched]) === undefined,
  "a session for another project was trusted",
);
assert(process.env.FM_HOME === undefined, "a mismatched session header set FM_HOME");
console.log("ok - session header must bind the shared Firstmate checkout");

reset();
assert(
  restoreFirstmateHomeFromPiSession(project, ["--session", "session.jsonl"]) === undefined,
  "a relative session path was trusted",
);
assert(process.env.FM_HOME === undefined, "a relative session path set FM_HOME");
console.log("ok - relative or unresolved session references do not infer a home");
JS
