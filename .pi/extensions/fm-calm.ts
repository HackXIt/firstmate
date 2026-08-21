// Firstmate's home-persistent Pi transcript presentation toggle.
//
// Verified against Pi 0.81.1 and 0.82.0, which expose session_start replacement
// reasons, agent_start and agent_settled, ExtensionUIContext.setToolsExpanded(),
// setWorkingVisible(), setWidget() with a disposable component factory, and
// setHiddenThinkingLabel().
// ./lib/fm-calm-working-ship.ts owns the animated working presentation this file
// installs. The focused tests pin those assumptions but never reject a newer Pi solely
// for its version. The collapsed-thinking, operational-user, and tool-execution
// presentation adapters probe the exact API they patch and degrade independently with a
// diagnostic (see installCalmPresentationAdapter below) if a future Pi removes it.
// docs/configuration.md owns the home-local Calm preference contract.
import { randomUUID } from "node:crypto";
import {
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type {
  ExtensionAPI,
  ExtensionUIContext,
} from "@earendil-works/pi-coding-agent";
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import { getKeybindings, type Component } from "@earendil-works/pi-tui";
import { installCalmAssistantLayout } from "./lib/fm-calm-assistant-layout.ts";
import { installCalmOperationalUserLayout } from "./lib/fm-calm-operational-user-layout.ts";
import {
  CALM_WORKING_SHIP_WIDGET_KEY,
  createCalmWorkingShipAnimation,
  createCalmWorkingShipWidget,
} from "./lib/fm-calm-working-ship.ts";
import {
  calmPresentationHides,
  calmPresentationIsActive,
  FIRSTMATE_CALM_PRESENTATION_EVENT,
  registerFirstmateSyntheticPresentation,
  setCalmPresentation,
  setCalmStockExportRendering,
} from "./lib/fm-calm-visibility.ts";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");

// Each presentation adapter probes the exact Pi API it patches. If a future Pi removes
// that API, only the affected adapter degrades; the rest of Calm keeps working.
function installCalmPresentationAdapter(name: string, install: () => void): void {
  try {
    install();
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    console.error(`Firstmate Calm: ${name} presentation adapter unavailable, skipping. ${reason}`);
  }
}

const CALM_TOOL_EXECUTION_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-tool-execution-layout:pi-0.84.2",
);
const CALM_CONTROLLED_TOOL_NAMES = new Set([
  "bash",
  "edit",
  "find",
  "grep",
  "ls",
  "read",
  "write",
]);

type ToolExecutionPresentationState = {
  toolName?: string;
  imageComponents?: Component[];
  imageSpacers?: Component[];
};

type CalmToolExecutionLayoutPatch = {
  hidesToolRows: () => boolean;
};

function renderImageBoundaryOnly(
  state: ToolExecutionPresentationState,
  width: number,
): string[] {
  const images = Array.isArray(state.imageComponents) ? state.imageComponents : [];
  if (images.length === 0) return [];

  const spacers = Array.isArray(state.imageSpacers) ? state.imageSpacers : [];
  const lines: string[] = [];
  for (let index = 0; index < images.length; index += 1) {
    const spacer = spacers[index];
    if (spacer) lines.push(...spacer.render(width));
    lines.push(...images[index].render(width));
  }
  return lines;
}

function installCalmToolExecutionLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmToolExecutionLayoutPatch | undefined;
  };
  const hidesToolRows = (): boolean =>
    calmPresentationHides("assistant-tool-call") || calmPresentationHides("tool-result");
  const installed = registry[CALM_TOOL_EXECUTION_LAYOUT_PATCH];
  if (installed) {
    installed.hidesToolRows = hidesToolRows;
    return;
  }

  const toolExecutionComponent = (PiCodingAgent as {
    ToolExecutionComponent?: { prototype?: { render?: unknown } };
  }).ToolExecutionComponent;
  const toolExecutionPrototype = toolExecutionComponent?.prototype;
  const originalRender = toolExecutionPrototype?.render;
  if (typeof originalRender !== "function") {
    throw new Error("Firstmate Calm requires Pi ToolExecutionComponent.render");
  }

  const patch: CalmToolExecutionLayoutPatch = { hidesToolRows };
  toolExecutionPrototype.render = function (width: number): string[] {
    const state = this as unknown as ToolExecutionPresentationState;
    if (
      patch.hidesToolRows() &&
      typeof state.toolName === "string" &&
      CALM_CONTROLLED_TOOL_NAMES.has(state.toolName)
    ) {
      return renderImageBoundaryOnly(state, width);
    }
    return originalRender.call(this, width);
  };

  registry[CALM_TOOL_EXECUTION_LAYOUT_PATCH] = patch;
}

export default function (pi: ExtensionAPI) {
  installCalmPresentationAdapter("collapsed-thinking", installCalmAssistantLayout);
  installCalmPresentationAdapter("operational-user-row", installCalmOperationalUserLayout);
  installCalmPresentationAdapter("tool-execution-row", installCalmToolExecutionLayout);

  let exportRendering = false;
  let removeTerminalInputHandler: (() => void) | undefined;
  // One logical agent run, tracked from agent_start through agent_settled rather than
  // from turns or tool calls, so the boat never flickers between tool calls, automatic
  // continuations, retries, or compaction that stay inside the same run.
  let agentRunActive = false;
  let workingShipShown = false;
  // One animation instance per extension lifetime. Hiding the working widget freezes
  // this state; the next working period resumes it. session_start resets it so a fresh
  // Pi session starts at the normal initial position. Never module-global.
  const workingShipAnimation = createCalmWorkingShipAnimation();

  // Single owner of Calm's working-row presentation choice. The widget is only created
  // or removed on a real transition, so repeated starts cannot duplicate its timer.
  const applyWorkingPresentation = (
    ui: ExtensionUIContext,
    forceStockVisibility = false,
  ): void => {
    const showShip = agentRunActive && calmPresentationIsActive();
    if (showShip !== workingShipShown) {
      workingShipShown = showShip;
      ui.setWidget(
        CALM_WORKING_SHIP_WIDGET_KEY,
        showShip
          ? (tui) => createCalmWorkingShipWidget(tui, workingShipAnimation)
          : undefined,
      );
      ui.setWorkingVisible(!showShip);
    } else if (forceStockVisibility && !showShip) {
      ui.setWorkingVisible(true);
    }
  };

  const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
  const configDirectory = process.env.FM_CONFIG_OVERRIDE || resolve(fmHome, "config");
  const calmPreferencePath = resolve(configDirectory, "calm");
  // "max" is the legacy value written by the removed third presentation level, whose
  // behavior is now ordinary Calm; a home upgraded from it restores as on rather than
  // dropping to off. docs/configuration.md owns the persisted value schema.
  const loadCalmPreference = (): boolean => {
    let stored: string;
    try {
      stored = readFileSync(calmPreferencePath, "utf8").trim();
    } catch {
      return false;
    }
    return stored === "on" || stored === "max";
  };
  const persistCalmPreference = (active: boolean): void => {
    mkdirSync(dirname(calmPreferencePath), { recursive: true });
    const temporaryPath = `${calmPreferencePath}.${process.pid}.${randomUUID()}.tmp`;
    try {
      writeFileSync(temporaryPath, active ? "on\n" : "off\n", {
        encoding: "utf8",
        flag: "wx",
        mode: 0o600,
      });
      renameSync(temporaryPath, calmPreferencePath);
    } finally {
      rmSync(temporaryPath, { force: true });
    }
  };

  const publishPresentationState = (): void => {
    pi.events.emit(FIRSTMATE_CALM_PRESENTATION_EVENT, {
      active: calmPresentationIsActive(),
      stockExportRendering: exportRendering,
    });
  };

  registerFirstmateSyntheticPresentation(pi);

  // Calm no longer registers same-name built-in tool overrides. The tool-execution
  // presentation adapter above hides the controlled rows without taking ownership from
  // renderer or behavior extensions such as pi-tool-display.
  pi.on("session_start", (_event, ctx) => {
    exportRendering = false;
    setCalmPresentation(loadCalmPreference());
    setCalmStockExportRendering(false);
    publishPresentationState();
    agentRunActive = false;
    workingShipShown = false;
    // A genuine new session lifetime starts the boat at the normal initial position.
    workingShipAnimation.reset();
    applyWorkingPresentation(ctx.ui, true);
    ctx.ui.setHiddenThinkingLabel(calmPresentationIsActive() ? "" : undefined);
    ctx.ui.setStatus("firstmate-calm", undefined);
    removeTerminalInputHandler?.();
    removeTerminalInputHandler = ctx.ui.onTerminalInput((data) => {
      if (!getKeybindings().matches(data, "tui.input.submit")) return;

      const input = ctx.ui.getEditorText().trim();
      if (
        input !== "/share" &&
        input !== "/export" &&
        !input.startsWith("/export ")
      ) {
        return;
      }

      exportRendering = true;
      setCalmStockExportRendering(true);
      publishPresentationState();
      setTimeout(() => {
        exportRendering = false;
        setCalmStockExportRendering(false);
        publishPresentationState();
        // Ask Pi to repaint rows that consult Calm live in render() without appending
        // a transcript status line. Avoid setToolsExpanded() here: since Pi 0.83.0 it
        // emits its own status and can overwrite the export confirmation.
        ctx.ui.setStatus("firstmate-calm", undefined);
      }, 0);
    });
  });

  pi.on("agent_start", (_event, ctx) => {
    agentRunActive = true;
    applyWorkingPresentation(ctx.ui);
  });

  // agent_settled is emitted from a finally block, so it also covers abort and failure.
  pi.on("agent_settled", (_event, ctx) => {
    agentRunActive = false;
    applyWorkingPresentation(ctx.ui);
  });

  pi.on("session_shutdown", (_event, ctx) => {
    agentRunActive = false;
    applyWorkingPresentation(ctx.ui);
  });

  pi.registerCommand("calm", {
    description: "Toggle Firstmate's supported conversation-only transcript presentation.",
    handler: async (_args, ctx) => {
      const active = !calmPresentationIsActive();
      persistCalmPreference(active);
      setCalmPresentation(active);
      publishPresentationState();
      applyWorkingPresentation(ctx.ui, true);
      // Pi re-runs every assistant row's layout from this call even when the label is
      // unchanged, which is what makes a toggle apply to rows already on screen.
      ctx.ui.setHiddenThinkingLabel(active ? "" : undefined);
      ctx.ui.setStatus("firstmate-calm", undefined);

      const expanded = ctx.ui.getToolsExpanded();
      ctx.ui.setToolsExpanded(!expanded);
      ctx.ui.setToolsExpanded(expanded);
    },
  });
}
