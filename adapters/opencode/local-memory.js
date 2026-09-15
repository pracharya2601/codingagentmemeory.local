// OpenCode plugin adapter for local-memory.
// Install: copy to <project>/.opencode/plugins/local-memory.js  or  ~/.config/opencode/plugins/local-memory.js
// and set LOCAL_MEMORY_DIR to the cloned repo (or edit REPO below).
//
// Uses OpenCode's plugin hooks:
//   tool.execute.before  -> log edits / writes / state-changing shell commands
//   chat.message         -> log the prompt and append retrieved memory as an extra text part
//   event (session.idle) -> if a checkpoint is due, send the checkpoint request as a follow-up prompt
//
// Status: written against the OpenCode plugin API reference; not yet verified end to end.

import { spawnSync } from "node:child_process"
import { existsSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

const REPO = process.env.LOCAL_MEMORY_DIR || join(homedir(), "claude-local-memory")
const CORE = join(REPO, "scripts", "memlog.sh")

function core(args, cwd) {
  if (!existsSync(CORE)) return ""
  const r = spawnSync("bash", [CORE, ...args], { cwd, encoding: "utf8", timeout: 60000 })
  return (r.stdout || "").trim()
}

export const LocalMemory = async ({ directory, client }) => {
  const cwd = directory || process.cwd()
  let idleGuard = 0

  return {
    "tool.execute.before": async (input, output) => {
      const tool = (input.tool || "").toLowerCase()
      const args = output.args || {}
      if (tool === "edit" || tool === "write" || tool === "multiedit" || tool === "patch") {
        const f = args.filePath || args.path || args.file_path
        if (f) core(["edit", cwd, f, input.tool], cwd)
      } else if (tool === "bash" || tool === "shell") {
        if (args.command) core(["cmd", cwd, args.command], cwd)
      }
    },

    "chat.message": async (input, output) => {
      const parts = output.parts || []
      const text = parts.filter(p => p.type === "text").map(p => p.text).join(" ").trim()
      if (!text) return
      core(["note", cwd, text], cwd)
      const hits = core(["retrieve", cwd, text], cwd)
      if (hits) {
        parts.push({
          type: "text",
          text: "Relevant past memory for this project (from the local index; verify against the repo before relying on it):\n" + hits,
        })
        output.parts = parts
      }
    },

    event: async ({ event }) => {
      if (event.type !== "session.idle") return
      const now = Date.now()
      if (now - idleGuard < 5000) return // one check per idle burst
      idleGuard = now
      const due = core(["due", cwd], cwd)
      if (!due) return
      const sessionID = event.properties?.sessionID
      if (!sessionID || !client?.session?.prompt) return
      try {
        await client.session.prompt({ path: { id: sessionID }, body: { parts: [{ type: "text", text: due }] } })
      } catch (e) {
        // If follow-up prompting is unavailable, the checkpoint stays armed and the MCP route can pick it up.
      }
    },
  }
}

export default LocalMemory
