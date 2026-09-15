# Adapters

One core, many agents. Each adapter translates a tool's events into the six core calls
(`note`, `edit`, `cmd`, `retrieve`, `last`, `due`). Where a tool cannot inject context or hold the agent,
the MCP server fills the gap.

## Support matrix

| Capability | Claude Code | Cursor | Codex CLI | Gemini CLI | OpenCode | Pi |
|---|---|---|---|---|---|---|
| Prompt logging | hook | hook | `notify` | hook | plugin | extension |
| Edit logging | hook, per tool call | hook, per edit | git status at turn end | hook, per tool call | plugin, per tool call | extension, per tool call |
| Command logging | hook | hook | not available | hook | plugin | extension |
| Retrieval into the prompt | hook | MCP + rule | MCP + AGENTS.md | hook | plugin | extension |
| Last checkpoint at session start | hook | MCP | MCP | hook | via retrieval | extension |
| Checkpoint delivery | Stop hook holds the agent | `followup_message` | MCP `memory_context` | AfterAgent holds the agent | follow-up prompt | `sendUserMessage` |
| Viewer | `/memory-ui` | CLI | CLI | CLI | CLI | CLI |
| **Verification status** | **verified: marketplace install, hooks firing in a real session, checkpoints in daily use** | untested | untested | untested | untested | untested |

"Untested" means: written against that tool's published extension reference, translator exercised with
synthetic payloads in this repo's test script, JavaScript and TypeScript syntax-checked, but not yet run
inside the tool itself. If you run one, please report what happened, including the tool version, so the
status can be updated.

## Adding an adapter

An adapter needs to answer four questions about the tool:

1. **Where does it tell me the prompt?** Call `memlog.sh note <cwd> <text>`. If it also lets you add context
   to the prompt, call `retrieve` and hand the text back in whatever shape the tool accepts.
2. **Where does it tell me a file changed or a command ran?** Call `edit` / `cmd`. If it doesn't, use git at
   turn end like the Codex adapter.
3. **Where does the turn end, and can I give the agent one more instruction?** Call `due`; if it prints, deliver
   the text. If the tool cannot deliver it, rely on MCP: `memory_context` will report it.
4. **Does it speak MCP?** If yes, register `scripts/mcp_server.py` and add `adapters/AGENTS-snippet.md` to the
   agent's instructions file. That alone gives retrieval and checkpoints with no hooks.

Keep adapters thin. All logic belongs in `scripts/memlog.sh` and `scripts/memindex.py` so every tool gets
the same behaviour and fixes land once.

## Sharing memory between tools

All adapters write to the same folders and the same index, keyed by project path. Use Claude Code in the
morning and Cursor in the afternoon on the same repo and both see the same checkpoints and observations.
