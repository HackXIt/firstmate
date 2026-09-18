import { lstatSync, realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

// This global entry is the sole Pi native-restart owner; ordinary Firstmate
// extensions consume the restored environment and never run recovery themselves.
const extensionFile = realpathSync(fileURLToPath(import.meta.url));
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const recoveryModule = await import(
  pathToFileURL(resolve(extensionDir, "lib/fm-pi-session-home.ts")).href
);
const restoredHome = recoveryModule.restoreFirstmateHomeFromOwnedPiSession(root);
const recoveredWorkerExtension = restoredHome
  ? process.env.FM_PI_RECOVERED_WORKER_EXTENSION
  : undefined;

function safeRecoveredWorkerExtension(path: string): boolean {
  try {
    const info = lstatSync(path);
    return info.isFile() && info.nlink === 1 && realpathSync(path) === path;
  } catch {
    return false;
  }
}

export default async function (pi: any): Promise<void> {
  if (!recoveredWorkerExtension) return;
  if (!safeRecoveredWorkerExtension(recoveredWorkerExtension)) {
    throw new Error("Firstmate topic-session recovery refused: the worker extension changed before loading");
  }
  const workerModule = await import(pathToFileURL(recoveredWorkerExtension).href);
  if (typeof workerModule.default !== "function") {
    throw new Error("Firstmate topic-session recovery refused: the worker extension has no default factory");
  }
  await workerModule.default(pi);
}
