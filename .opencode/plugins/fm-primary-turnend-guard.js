import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { encodeFirstmateOperationalInput, queueFirstmateOperationalInput } from "./lib/fm-operational-input.js";

const COORDINATOR_KEY = "__firstmateOpenCodeWatchArm";

let skipNextIdle = false;

function runProcess(command, args, input = "") {
  return new Promise((resolve) => {
    const child = spawn(command, args, {
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolve({ code: 0, stdout: "", stderr: "" }));
    child.on("close", (code) => resolve({ code: code ?? 0, stdout, stderr }));
    child.stdin.end(input);
  });
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  return resolvePath(anchor);
}

function resolvePath(anchor) {
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

function runGuard(root) {
  if (!root) return Promise.resolve({ code: 0, stderr: "" });
  return runProcess(`${root}/bin/fm-turnend-guard.sh`, [], '{"stop_hook_active":false}');
}

async function letWatchArmRun(sessionID, client) {
  const coordinator = globalThis[COORDINATOR_KEY];
  if (!coordinator?.ensureArmed) return false;
  const status = await coordinator.ensureArmed(sessionID, client);
  return status === "armed" || status === "wake" || status === "failed";
}

export default {
  id: "fm.primary.turnend-guard",
  async setup(ctx) {
    const root = await resolveRoot(ctx.location.directory);
    const controller = new AbortController();
    void (async () => {
      for await (const event of ctx.event.subscribe({
        types: ["session.execution.succeeded", "session.execution.failed", "session.execution.interrupted"],
        signal: controller.signal,
      })) {
        if (skipNextIdle) {
          skipNextIdle = false;
          continue;
        }
        const sessionID = event.data?.sessionID;
        if (!sessionID) continue;
        if (await letWatchArmRun(sessionID, ctx)) continue;

        const result = await runGuard(root);
        if (result.code !== 2) continue;

        try {
          const text = await encodeFirstmateOperationalInput(
            root,
            "turn-end-guard",
            "TURN WOULD END BLIND - supervision is off. " +
              "The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n" +
              result.stderr,
          );
          await queueFirstmateOperationalInput(ctx, sessionID, text);
          skipNextIdle = true;
        } catch {
          skipNextIdle = false;
        }
      }
    })().catch(() => {});
    return () => controller.abort();
  },
};
