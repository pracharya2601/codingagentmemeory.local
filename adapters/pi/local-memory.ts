// Pi coding agent extension for local-memory.
// Install: copy to ~/.pi/agent/extensions/local-memory.ts (all projects) or <project>/.pi/extensions/local-memory.ts
// and set LOCAL_MEMORY_DIR to the cloned repo (or edit REPO below).
//
// Uses Pi's extension events:
//   session_start       -> nothing to inject yet; records the project path
//   before_agent_start  -> log the prompt, inject retrieved memory + the last checkpoint as a hidden message
//   tool_call           -> log edits / writes / state-changing shell commands
//   agent_end           -> if a checkpoint is due, send the checkpoint request as the next user message
//
// Status: written against the Pi extension API reference; not yet verified end to end.

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent"
import { existsSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

const REPO = process.env.LOCAL_MEMORY_DIR || join(homedir(), "claude-local-memory")
const CORE = join(REPO, "scripts", "memlog.sh")

export default function (pi: ExtensionAPI) {
  let started = false

  async function core(args: string[], cwd: string): Promise<string> {
    if (!existsSync(CORE)) return ""
    try {
      const r = await pi.exec("bash", [CORE, ...args], { cwd, timeout: 60000 })
      return (r.stdout || "").trim()
    } catch {
      return ""
    }
  }

  pi.on("session_start", async (_event, ctx) => {
    started = true
    await core(["last", ctx.cwd], ctx.cwd) // records slug -> path; output used on before_agent_start
  })

  pi.on("before_agent_start", async (event, ctx) => {
    const prompt = typeof event.prompt === "string" ? event.prompt : ""
    if (!prompt) return
    await core(["note", ctx.cwd, prompt], ctx.cwd)
    const parts: string[] = []
    if (started) {
      const last = await core(["last", ctx.cwd], ctx.cwd)
      if (last) parts.push("Where this project was left (latest checkpoint from local memory):\n" + last)
      started = false
    }
    const hits = await core(["retrieve", ctx.cwd, prompt], ctx.cwd)
    if (hits) parts.push("Relevant past memory for this project (verify against the repo before relying on it):\n" + hits)
    if (!parts.length) return
    return { message: { customType: "local-memory", content: parts.join("\n\n"), display: false } }
  })

  pi.on("tool_call", async (event, ctx) => {
    const name = (event.toolName || "").toLowerCase()
    const input: any = event.input || {}
    if (name === "write" || name === "edit") {
      const f = input.path || input.filePath || input.file_path
      if (f) await core(["edit", ctx.cwd, f, event.toolName], ctx.cwd)
    } else if (name === "bash") {
      if (input.command) await core(["cmd", ctx.cwd, input.command], ctx.cwd)
    }
  })

  pi.on("agent_end", async (_event, ctx) => {
    const due = await core(["due", ctx.cwd], ctx.cwd)
    if (due) pi.sendUserMessage(due)
  })
}
