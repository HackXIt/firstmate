import { existsSync, readFileSync, realpathSync } from "node:fs";
import { basename, dirname, isAbsolute, resolve } from "node:path";

type SessionHeader = {
  type?: unknown;
  cwd?: unknown;
};

function exactSessionArgument(args: string[]): string | undefined {
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--session") return args[index + 1];
    if (arg.startsWith("--session=")) return arg.slice("--session=".length);
  }
  return undefined;
}

function sameRealPath(left: string, right: string): boolean {
  try {
    return realpathSync(left) === realpathSync(right);
  } catch {
    return false;
  }
}

function sessionHeader(path: string): SessionHeader | undefined {
  try {
    const firstLine = readFileSync(path, "utf8").split(/\r?\n/, 1)[0];
    const parsed = JSON.parse(firstLine) as SessionHeader;
    return parsed && typeof parsed === "object" ? parsed : undefined;
  } catch {
    return undefined;
  }
}

export function restoreFirstmateHomeFromPiSession(
  firstmateRoot: string,
  args: string[] = process.argv.slice(2),
): string | undefined {
  if (process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE) return undefined;

  const requestedSession = exactSessionArgument(args);
  if (!requestedSession || !isAbsolute(requestedSession) || !existsSync(requestedSession)) {
    return undefined;
  }

  let sessionPath: string;
  let root: string;
  try {
    sessionPath = realpathSync(requestedSession);
    root = realpathSync(firstmateRoot);
  } catch {
    return undefined;
  }

  const sessionDirectory = dirname(sessionPath);
  if (basename(sessionDirectory) !== "pi-sessions") return undefined;

  const home = dirname(sessionDirectory);
  for (const child of ["config", "data", "state", "projects"]) {
    if (!existsSync(resolve(home, child))) return undefined;
  }

  const header = sessionHeader(sessionPath);
  if (header?.type !== "session" || typeof header.cwd !== "string") return undefined;
  if (!sameRealPath(header.cwd, root)) return undefined;

  process.env.FM_HOME = home;
  process.env.FM_ROOT_OVERRIDE = root;
  return home;
}
