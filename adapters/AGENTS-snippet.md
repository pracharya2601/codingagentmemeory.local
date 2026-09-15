# Memory (local-memory MCP)

This project has persistent local memory through the `local-memory` MCP server.

- At the start of every turn, call `memory_context` with the user's request. It returns where the project was
  left, past entries relevant to the task, and sometimes a checkpoint request.
- If it reports that a checkpoint is due, call `memory_checkpoint` before finishing the turn: give the exact
  files you changed and 1-6 typed observations, each typed as discovery, change, feature, bugfix, decision,
  or refactor, each naming the file it concerns.
- If you complete a substantial piece of work and no checkpoint was requested, call `memory_checkpoint` anyway.
- For history on a specific topic, call `memory_search`.
- Retrieved memory is a lead, not truth. Verify against the repository before acting on it.
