import {
  closeSync,
  existsSync,
  fstatSync,
  lstatSync,
  openSync,
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

function markerTrustsHome(home: string, root: string): boolean {
  const marker = resolve(home, topicHomeMarker);
  if (!safeRegularFile(marker)) return false;
  let values: Record<string, string>;
  try {
    values = Object.fromEntries(
      readFileBounded(marker, 4096)
        .trim()
        .split(/\r?\n/)
        .map((line) => {
          const separator = line.indexOf("=");
          return separator > 0 ? [line.slice(0, separator), line.slice(separator + 1)] : ["", ""];
        }),
    );
  } catch {
    return false;
  }
  return values.version === "1" && values.home === home && values.root === root;
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
  const defaultBase = process.env.HOME ? resolve(process.env.HOME, ".local/share/firstmate") : "";
  if (isAbsolute(defaultBase) && safeDirectory(defaultBase) && dirname(home) === realpathSync(defaultBase)) {
    return true;
  }
  return markerTrustsHome(home, root);
}

export function restoreFirstmateHomeFromPiSession(
  firstmateRoot: string,
  args: string[] = process.argv.slice(2),
): string | undefined {
  if (process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE) return undefined;
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
    fail("the session directory is not bound to an owner-controlled Firstmate topic home");
  }
  for (const child of ["config", "data", "state", "projects", "pi-sessions"]) {
    if (!safeDirectory(resolve(home, child))) fail(`the topic home has an unsafe or missing ${child} directory`);
  }

  const header = sessionHeader(sessionPath);
  if (header?.type !== "session" || typeof header.cwd !== "string") {
    fail("the Pi session header is missing or invalid");
  }
  if (!sameRealPath(header.cwd, root)) {
    fail("the Pi session header belongs to another working directory");
  }

  process.env.FM_HOME = home;
  process.env.FM_ROOT_OVERRIDE = root;
  return home;
}
