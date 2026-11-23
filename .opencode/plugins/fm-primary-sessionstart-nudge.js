import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { queueFirstmateOperationalInput } from "./lib/fm-operational-input.js";

const handledSessions = new Set();

function runProcess(command, args) {
  return new Promise((resolveResult) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "ignore"] });
    let stdout = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.on("error", () => resolveResult({ code: 0, stdout: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stdout }));
  });
}

function resolvePath(anchor) {
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  return resolvePath(anchor);
}

export default {
  id: "fm.primary.sessionstart-nudge",
  async setup(ctx) {
    const root = await resolveRoot(ctx.location.directory);
    const controller = new AbortController();
    void (async () => {
      for await (const event of ctx.event.subscribe({
        types: ["session.created", "session.inbox.enqueued"],
        signal: controller.signal,
      })) {
        const sessionID = event.data?.info?.id ?? event.data?.sessionID;
        if (!sessionID || handledSessions.has(sessionID) || !root) continue;
        handledSessions.add(sessionID);

        const result = await runProcess(`${root}/bin/fm-sessionstart-nudge.sh`, []);
        const nudge = result.code === 0 ? result.stdout.trim() : "";
        if (!nudge) continue;
        try {
          await queueFirstmateOperationalInput(ctx, sessionID, nudge);
        } catch {
          // The session may have closed before delivery.
        }
      }
    })().catch(() => {});
    return () => controller.abort();
  },
};
