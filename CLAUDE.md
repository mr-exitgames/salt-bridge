# Salt Bridge — Claude Code context

This is the Salt Bridge MCP server for Qubes OS. It runs in a dedicated, privileged AppVM and provides cross-VM management tools to Claude Code via qrexec.

## Architecture

- `server.py` is the MCP server. It calls `qrexec-client-vm dom0 saltbridge.<Service>` for each tool invocation.
- dom0 qrexec services live in `dom0-setup/qubes-rpc/`. They are shell scripts that wrap `qvm-run`, `qvm-firewall`, etc.
- dom0 policy in `dom0-setup/policy.d/30-salt-bridge.policy` controls which VM(s) can call the services.
- The dom0 installer (`dom0-install.sh`) must be run in two steps due to stdin conflicts when piping through `qvm-run`.

## Key constraints

- `exec_in_vm`, `exec_in_vm_root`, `read_file_in_vm`, `write_file_in_vm` all block `dom0` / `@adminvm` as a target (enforced in dom0 service scripts). Do not remove this guard.
- The same tools also block `salt-bridge` itself as a target (enforced in `server.py` via `_reject_self`). When operating on salt-bridge, use local tools (Read, Write, Bash, Grep, Glob) directly — no qrexec needed.
- VM names are validated with `^[a-zA-Z][a-zA-Z0-9_-]*$` in every dom0 service script.
- The MCP server depends on `mcp[cli]>=1.0.0` (Python).
- Qubes minimal template VMs lack `sudo` — use `exec_in_vm_root` (which calls `qvm-run -u root`) for those.

## Development

- The git remote is `git@git:repos/salt-bridge.git` via SSH over `qubes.ConnectTCP` qrexec.
- When adding a new tool: add the qrexec service script in `dom0-setup/qubes-rpc/`, the `@mcp.tool()` function in `server.py`, the policy line in `dom0-setup/policy.d/`, and the service name to the `for svc in ...` loop in `dom0-install.sh`.
- After changing `server.py`, restart Claude Code for the MCP server to reload.
- After changing dom0 scripts or policy, re-run the two-step dom0 installer.
