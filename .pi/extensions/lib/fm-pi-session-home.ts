import {
  closeSync,
  existsSync,
  fstatSync,
  lstatSync,
  openSync,
  readdirSync,
  readSync,
  realpathSync,
  statSync,
} from "node:fs";
import { basename, dirname, isAbsolute, resolve } from "node:path";

type SessionHeader = {
  type?: unknown;
  cwd?: unknown;
};

const maximumHeaderBytes = 64 * 1024;
const topicHomeMarker = ".fm-topic-home";

function fail(message: string): never {
  throw new Error(`Firstmate topic-session recovery refused: ${message}`);
}

function exactSessionArgument(args: string[]): string | undefined {
  const selectors: string[] = [];
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--") break;
    if (arg.startsWith("--session=")) {
      fail("Pi does not support --session=<path>; use one --session <absolute-path> selector");
    }
    if (arg !== "--session") continue;
    const value = args[index + 1];
    if (!value || value.startsWith("-")) fail("--session is missing its path");
    selectors.push(value);
    index += 1;
  }
  if (selectors.length > 1) fail("multiple --session selectors are ambiguous");
  return selectors[0];
}

function sameRealPath(left: string, right: string): boolean {
  try {
    return realpathSync(left) === realpathSync(right);
  } catch {
    return false;
  }
}

function ownedByCurrentUser(path: string): boolean {
  if (typeof process.getuid !== "function") return true;
  return statSync(path).uid === process.getuid();
}

function safeDirectory(path: string): boolean {
  try {
    const info = lstatSync(path);
    return info.isDirectory() && ownedByCurrentUser(path) && realpathSync(path) === path;
  } catch {
    return false;
  }
}

function safeRegularFile(path: string): boolean {
  try {
    const info = lstatSync(path);
    return info.isFile() && info.nlink === 1 && ownedByCurrentUser(path)
      && realpathSync(path) === path;
  } catch {
    return false;
  }
}

function sessionHeader(path: string): SessionHeader | undefined {
  let descriptor: number | undefined;
  try {
    descriptor = openSync(path, "r");
    const size = Math.min(fstatSync(descriptor).size, maximumHeaderBytes);
    if (size < 1) return undefined;
    const buffer = Buffer.alloc(size);
    const bytes = readSync(descriptor, buffer, 0, size, 0);
    const newline = buffer.subarray(0, bytes).indexOf(0x0a);
    if (newline < 0) return undefined;
    const parsed = JSON.parse(buffer.subarray(0, newline).toString("utf8")) as SessionHeader;
    return parsed && typeof parsed === "object" ? parsed : undefined;
  } catch {
    return undefined;
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
  }
}

function pathEntryExists(path: string): boolean {
  try {
    lstatSync(path);
    return true;
  } catch {
    return false;
  }
}

function topicHomeBinding(home: string, root: string): boolean {
  const marker = resolve(home, topicHomeMarker);
  if (!safeRegularFile(marker)) return false;
  let contents: string;
  try {
    contents = readFileBounded(marker, 4096);
  } catch {
    return false;
  }
  const lines = contents.trim().split(/\r?\n/);
  const version = exactRecordValue(contents, "version");
  const boundHome = exactRecordValue(contents, "home");
  const boundRoot = exactRecordValue(contents, "root");
  const herdrSession = exactRecordValue(contents, "herdr_session");
  return version === "2" && lines.length === 4 && boundHome === home && boundRoot === root
    && herdrSession === process.env.HERDR_SESSION;
}

function readFileBounded(path: string, maximumBytes: number): string {
  let descriptor: number | undefined;
  try {
    descriptor = openSync(path, "r");
    const size = fstatSync(descriptor).size;
    if (size < 1 || size > maximumBytes) throw new Error("file size is outside the accepted bound");
    const buffer = Buffer.alloc(size);
    const bytes = readSync(descriptor, buffer, 0, size, 0);
    if (bytes !== size) throw new Error("short read");
    return buffer.toString("utf8");
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
  }
}

function knownTopicHome(home: string, root: string): boolean {
  const marker = resolve(home, topicHomeMarker);
  return pathEntryExists(marker) && topicHomeBinding(home, root);
}

function argumentsClaimTopicHome(args: string[]): boolean {
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--") break;
    let value: string | undefined;
    if (arg.startsWith("--session=")) {
      value = arg.slice("--session=".length);
    } else if (arg === "--session") {
      value = args[index + 1];
    }
    if (!value || value.startsWith("-")) continue;
    const candidate = isAbsolute(value) ? value : resolve(value);
    const sessionDirectory = dirname(candidate);
    if (basename(sessionDirectory) !== "pi-sessions") continue;
    if (pathEntryExists(resolve(dirname(sessionDirectory), topicHomeMarker))) return true;
  }
  return false;
}

function exactRecordValue(contents: string, key: string): string | undefined {
  const prefix = `${key}=`;
  const matches = contents.split(/\r?\n/).filter((line) => line.startsWith(prefix));
  return matches.length === 1 ? matches[0].slice(prefix.length) : undefined;
}

function workerTaskForSession(home: string, cwd: string): void {
  const state = resolve(home, "state");
  if (!safeDirectory(cwd) || !safeDirectory(state)) {
    fail("the worker session header or topic state directory is unsafe");
  }
  const matches: string[] = [];
  for (const name of readdirSync(state)) {
    if (!name.endsWith(".meta")) continue;
    const metadata = resolve(state, name);
    if (!safeRegularFile(metadata)) fail("worker metadata must be canonical and owner-controlled");
    let contents: string;
    try {
      contents = readFileBounded(metadata, maximumHeaderBytes);
    } catch {
      fail("worker metadata is unreadable or outside the accepted size bound");
    }
    const taskId = name.slice(0, -".meta".length);
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(taskId)) fail("worker metadata has an unsafe task id");
    const endpointTaskId = exactRecordValue(contents, "endpoint_task_id");
    const backend = exactRecordValue(contents, "backend");
    const harness = exactRecordValue(contents, "harness");
    const kind = exactRecordValue(contents, "kind");
    const worktree = exactRecordValue(contents, "worktree");
    const herdrSession = exactRecordValue(contents, "herdr_session");
    if (endpointTaskId !== taskId || backend !== "herdr"
      || (harness !== "pi" && harness !== "pi-signed")
      || (kind !== "ship" && kind !== "scout")) {
      continue;
    }
    if (!worktree || !isAbsolute(worktree) || !sameRealPath(worktree, cwd)) continue;
    if (!herdrSession || herdrSession !== process.env.HERDR_SESSION) continue;
    matches.push(taskId);
  }
  if (matches.length !== 1) {
    fail("the Pi session header does not identify exactly one worker in this Herdr topic");
  }
  const taskId = matches[0];
  if (process.env.FM_TASK_ID && process.env.FM_TASK_ID !== taskId) {
    fail("the ambient worker identity does not match the recovered Pi session");
  }
  const extension = resolve(state, `${taskId}.pi-ext.ts`);
  if (!safeRegularFile(extension)) fail("the recovered worker extension is missing or unsafe");
  process.env.FM_TASK_ID = taskId;
  process.env.FM_PI_RECOVERED_WORKER_EXTENSION = extension;
}

export function restoreFirstmateHomeFromPiSession(
  firstmateRoot: string,
  args: string[] = process.argv.slice(2),
): string | undefined {
  if (process.env.HERDR_ENV !== "1") return undefined;

  const requestedSession = exactSessionArgument(args);
  if (!requestedSession) return undefined;
  if (!isAbsolute(requestedSession) || !existsSync(requestedSession)) {
    fail("Herdr supplied a missing or non-absolute Pi session path");
  }

  let root: string;
  try {
    root = realpathSync(firstmateRoot);
  } catch {
    fail("the shared Firstmate checkout cannot be resolved");
  }

  if (!safeRegularFile(requestedSession)) {
    fail("the Pi session must be a canonical, single-linked, owner-controlled regular file");
  }
  const sessionPath = realpathSync(requestedSession);
  const sessionDirectory = dirname(sessionPath);
  if (basename(sessionDirectory) !== "pi-sessions") {
    fail("the Pi session is not a direct child of a pi-sessions directory");
  }

  const home = dirname(sessionDirectory);
  if (!safeDirectory(home) || !knownTopicHome(home, root)) {
    fail("the session directory is not bound to this Firstmate checkout and Herdr topic");
  }
  for (const child of ["config", "data", "state", "projects", "pi-sessions"]) {
    if (!safeDirectory(resolve(home, child))) fail(`the topic home has an unsafe or missing ${child} directory`);
  }

  const header = sessionHeader(sessionPath);
  if (header?.type !== "session" || typeof header.cwd !== "string") {
    fail("the Pi session header is missing or invalid");
  }
  if (!sameRealPath(header.cwd, root)) {
    workerTaskForSession(home, header.cwd);
  } else if (process.env.FM_TASK_ID) {
    fail("a primary Pi session carries a foreign ambient worker identity");
  }

  if (process.env.FM_HOME && process.env.FM_HOME !== home) {
    fail("the ambient Firstmate home does not match the recovered Pi session");
  }
  if (process.env.FM_ROOT_OVERRIDE && process.env.FM_ROOT_OVERRIDE !== root) {
    fail("the ambient Firstmate checkout does not match the recovered Pi session");
  }
  process.env.FM_HOME = home;
  process.env.FM_ROOT_OVERRIDE = root;
  return home;
}

// The global Pi extension ignores sessions that do not even claim a Firstmate
// topic home. Once a marker is present, the strict recovery path owns every
// safety and mismatch refusal.
export function restoreFirstmateHomeFromOwnedPiSession(
  firstmateRoot: string,
  args: string[] = process.argv.slice(2),
): string | undefined {
  if (process.env.HERDR_ENV !== "1") return undefined;

  if (!argumentsClaimTopicHome(args)) return undefined;
  return restoreFirstmateHomeFromPiSession(firstmateRoot, args);
}
