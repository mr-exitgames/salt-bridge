# Salt Bridge

**An MCP server that gives an agent full cross-VM management of a [Qubes OS](https://www.qubes-os.org/) system — command execution, file I/O, firewall rules, and network policy — all through dom0 qrexec, bounded by an explicit dom0-enforced VM allowlist.**

> [!CAUTION]
> ## This tool fundamentally breaks the Qubes OS security model.
>
> Qubes OS achieves security through **isolation** — each VM is a compartment, and no single VM can reach into another. Salt Bridge **deliberately narrows that boundary** by granting one VM the ability to execute commands, read/write files, and modify firewall rules across an admin-configured set of other VMs on the system.
>
> **What this means in practice:**
> - A compromise of the salt-bridge AppVM = full compromise of every VM in its allowlist
> - Any MCP client bug, prompt injection, or supply-chain attack in that VM has dom0-equivalent reach over the allowlisted VMs
> - The dom0 allowlist bounds the blast radius, but the agent can still do anything within it — there are no per-command prompts
>
> **Salt Bridge is a development and administration tool.** It is designed for:
> - Qubes development machines where you are building/testing Qubes itself
> - Lab and experimentation environments
> - Machines where convenience outweighs compartmentalization
>
> **Do NOT install Salt Bridge on a Qubes system that holds sensitive data** — personal credentials, private keys, confidential documents, cryptocurrency wallets, or anything you rely on Qubes isolation to protect. If you need AI-assisted cross-VM tooling *with* isolation guarantees, see [Calcium Channel](https://github.com/mr-exitgames/calcium-channel) — a least-privilege MCP-over-qrexec mesh that routes MCP connections between isolated VMs with per-server ACLs, strengthening Qubes isolation rather than bypassing it.

## How It Works

Salt Bridge is an [MCP](https://modelcontextprotocol.io/) server that runs inside a dedicated Qubes VM. Any MCP-speaking agent (for example, [Claude Code](https://docs.anthropic.com/en/docs/claude-code)) connects to it like any other MCP server, and each tool call crosses the Qubes security boundary via qrexec — the same mechanism Qubes itself uses for inter-VM communication.

```
                         qrexec boundary
                              │
  ┌──────────────────┐        │        ┌──────────┐       ┌──────────────┐
  │  salt-bridge VM  │        │        │   dom0   │       │ allowlisted  │
  │                  │        │        │          │       │ target VMs   │
  │  Agent           │        │        │ policy:  │       │  ┌────────┐  │
  │    │             │        │        │  +work   │       │  │ work   │  │
  │    ▼             │        │        │  +dev    │       │  └────────┘  │
  │  MCP Server ─────── saltbridge.<Svc>+<vm> ──▶ Service │  ┌────────┐  │
  │  (server.py)     │        │        │ Scripts  │       │  │ dev    │  │
  │    ▲             │        │        │          │       │  └────────┘  │
  │    │             │        │        │ qvm-run  │       │              │
  │  Tool Result ◄───────────────────── qvm-fw    │◄──────│  (others     │
  │                  │        │        │ qvm-ls   │       │   blocked)   │
  └──────────────────┘        │        └──────────┘       └──────────────┘
                              │
```

**The flow:**

1. The agent invokes an MCP tool (e.g. `exec_in_vm`)
2. `server.py` calls `qrexec-client-vm dom0 saltbridge.<Service>+<target-vm>` — the target VM travels in the qrexec argument, not in the payload
3. Dom0 qrexec policy checks (a) that the calling VM is the authorised agent VM and (b) that the target VM is in the generated per-target allow list
4. The dom0 service script re-checks the target against `/etc/qubes/salt-bridge-allowed-vms` and runs the appropriate `qvm-*` command
5. Output streams back through qrexec to the MCP response

## MCP Tools

| Tool | Description |
|------|-------------|
| `list_vms` | List all VMs with state, type, netvm, IP, and label |
| `start_vm` | Start a VM |
| `shutdown_vm` | Gracefully shut down a VM |
| `vm_network_info` | IPs, routes, DNS, iptables, WireGuard status |
| `exec_in_vm` | Run a shell command as the default user |
| `exec_in_vm_root` | Run a shell command as root |
| `read_file_in_vm` | Read a file from any VM |
| `write_file_in_vm` | Write a file to any VM (creates parent dirs) |
| `firewall_list` | List qvm-firewall rules for a VM |
| `firewall_add` | Add a firewall rule (accept/drop) |
| `firewall_remove` | Remove a firewall rule by number |
| `connect_tcp_policy` | Manage `qubes.ConnectTCP` qrexec policy in dom0 |

## Security Model

```
  ┌─────────────────────────────────────────────────────┐
  │                    SECURITY LAYERS                  │
  ├─────────────────────────────────────────────────────┤
  │                                                     │
  │  1. Qrexec Source Policy (dom0)                     │
  │     Only the named agent VM can call saltbridge.*   │
  │                                                     │
  │  2. Qrexec Per-Target Policy (dom0)                 │
  │     saltbridge.<Svc>+<vm> is allowed only for VMs   │
  │     enumerated by the installer; all others denied  │
  │     before any script runs                          │
  │                                                     │
  │  3. Dom0 Allowlist File (installer-enforced)        │
  │     /etc/qubes/salt-bridge-allowed-vms is the       │
  │     authoritative set; service scripts fail closed  │
  │     if a target isn't in it                         │
  │                                                     │
  │  4. Target Blocking (dom0 + server.py)              │
  │     dom0 and the salt-bridge VM itself are always   │
  │     rejected for exec/read/write                    │
  │                                                     │
  │  5. Input Validation (dom0 service scripts)         │
  │     VM names: ^[a-zA-Z][a-zA-Z0-9_-]*$              │
  │     Firewall args: ^[a-zA-Z0-9=\.:/\ -]+$           │
  │     Ports: integer 1–65535                          │
  │                                                     │
  │  6. Resource Limits (server.py)                     │
  │     Output capped at 2 MB (prevents OOM)            │
  │     30-second timeout per command                   │
  │                                                     │
  └─────────────────────────────────────────────────────┘
```

- **The dom0 allowlist is authoritative.** The installer turns `<target-vm>` arguments into per-target qrexec `allow` lines *and* writes `/etc/qubes/salt-bridge-allowed-vms`. Calls to any non-allowlisted VM are rejected by dom0 — first by the qrexec policy engine (before the script runs), then by a fail-closed check inside the script.
- **dom0 is never a valid target** for `exec_in_vm`, `exec_in_vm_root`, `read_file_in_vm`, or `write_file_in_vm` — enforced in both the dom0 service scripts and `server.py`.
- **Only the authorised agent VM** can invoke any Salt Bridge service. All other source VMs are denied by default.
- VM names are regex-validated in every dom0 service script to prevent injection.

## Installation

### Prerequisites

- Qubes OS 4.x
- A dedicated AppVM for Salt Bridge (strongly recommended — isolate the privilege)
- Python 3.10+ in the Salt Bridge VM
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed in the Salt Bridge VM

### Step 1: Set up the Salt Bridge VM

Clone this repo and install dependencies:

```bash
git clone https://github.com/mr-exitgames/salt-bridge.git ~/salt-bridge
cd ~/salt-bridge
pip install -r requirements.txt
```

Add to `~/.mcp.json` (or your Claude Code MCP config):

```json
{
  "mcpServers": {
    "salt-bridge": {
      "command": "python3",
      "args": ["/home/user/salt-bridge/server.py"]
    }
  }
}
```

### Step 2: Install dom0 services

Run in **dom0** (two-step process — piping directly causes stdin conflicts with `qvm-run`):

```bash
qvm-run -p salt-bridge 'cat ~/salt-bridge/dom0-install.sh' > /tmp/sb-install.sh
bash /tmp/sb-install.sh <agent-vm> <target-vm> [<target-vm> ...]
```

For example, to authorise the `salt-bridge` VM to manage `work`, `dev`, and `test`:

```bash
bash /tmp/sb-install.sh salt-bridge work dev test
```

The installer:
- Copies all 12 qrexec service scripts plus the shared helper (`saltbridge.lib.sh`) to `/etc/qubes-rpc/`
- Writes `/etc/qubes/salt-bridge-allowed-vms` with the target VMs (one per line)
- Generates `/etc/qubes/policy.d/30-salt-bridge.policy` with one `allow` line per (service × target) pair and explicit `deny` catch-alls
- **Replaces the allowlist and policy wholesale on each run** — re-invoke with the new complete list to change which VMs are reachable

### Step 3: Restart Claude Code

The MCP server starts automatically when Claude Code launches. Verify with:

```bash
qrexec-client-vm dom0 saltbridge.VmList
```

## Project Structure

```
salt-bridge/
├── server.py                              # MCP server (runs in salt-bridge VM)
├── requirements.txt                       # Python dependencies
├── dom0-install.sh                        # Dom0 installer (run in dom0)
└── dom0-setup/
    ├── policy.d/
    │   └── 30-salt-bridge.policy          # Qrexec policy template
    └── qubes-rpc/
        ├── saltbridge.VmList              # qvm-ls wrapper
        ├── saltbridge.VmStart             # qvm-start wrapper
        ├── saltbridge.VmShutdown          # qvm-shutdown wrapper
        ├── saltbridge.VmNetworkInfo       # Network diagnostics
        ├── saltbridge.VmExec              # Command exec (user)
        ├── saltbridge.VmExecRoot          # Command exec (root)
        ├── saltbridge.VmReadFile          # File read via qvm-run
        ├── saltbridge.VmWriteFile         # File write via qvm-run
        ├── saltbridge.FirewallList        # Firewall listing
        ├── saltbridge.FirewallAdd         # Firewall rule add
        ├── saltbridge.FirewallRemove      # Firewall rule remove
        └── saltbridge.ConnectTcpPolicy    # ConnectTCP policy mgmt
```

## Updating

After modifying qrexec services, the installer, or the policy generator, re-run the dom0 installer with your current agent + target VMs:

```bash
# In dom0:
qvm-run -p salt-bridge 'cat ~/salt-bridge/dom0-install.sh' > /tmp/sb-install.sh
bash /tmp/sb-install.sh salt-bridge work dev test
```

After modifying `server.py`, restart Claude Code to reload the MCP server.

## Changing the Allowlist

To add or remove VMs that the agent can manage, re-run the installer with the **new complete list** of targets:

```bash
# Switch the allowlist from (work dev test) to (work prod):
bash /tmp/sb-install.sh salt-bridge work prod
```

The installer replaces `/etc/qubes/salt-bridge-allowed-vms` and `/etc/qubes/policy.d/30-salt-bridge.policy` wholesale on every run — there is no append mode. VMs dropped from the list become unreachable immediately: first the qrexec policy engine denies the call (no `+<vm>` allow line), then the service script's fail-closed allowlist check catches anything that slips past.

## Migration

The installer's argument shape changed. Previous versions took a single `<agent-vm>`; the current installer requires `<agent-vm>` **plus at least one `<target-vm>`**, and rejects `dom0`, reserved `@anyvm`/`@adminvm`/`@dispvm` names, or a target list that contains the agent VM. Old invocations now error with usage help — re-run with the new signature:

```bash
bash /tmp/sb-install.sh <agent-vm> <target-vm> [<target-vm> ...]
```

## How Qrexec Policies Work

For those unfamiliar with Qubes, qrexec is the inter-VM RPC system. Salt Bridge uses it like this:

```
  30-salt-bridge.policy (in dom0, generated by the installer):
  ┌──────────────────────────────────────────────────────────────┐
  │ saltbridge.VmList   *      salt-bridge  @adminvm  allow      │
  │                                                              │
  │ saltbridge.VmStart  +work  salt-bridge  @adminvm  allow      │
  │ saltbridge.VmStart  +dev   salt-bridge  @adminvm  allow      │
  │ saltbridge.VmStart  *      salt-bridge  @anyvm    deny       │
  │ saltbridge.VmStart  *      @anyvm       @anyvm    deny       │
  │                                                              │
  │ saltbridge.VmExec   +work  salt-bridge  @adminvm  allow      │
  │ saltbridge.VmExec   +dev   salt-bridge  @adminvm  allow      │
  │ ... (same per-target allow/deny block for every service)     │
  └──────────────────────────────────────────────────────────────┘
       │              │        │            │          │
   service name    target    source VM   policy tgt   action
                  (+<vm>)                 (@adminvm
                                           = dom0)

  - Only the configured agent VM can invoke saltbridge.* services.
  - Only VMs with a matching `+<vm>` allow line are reachable;
    `saltbridge.VmList` has no per-target argument and is gated
    only by source.
  - @adminvm is dom0 — where the service scripts run, not the
    VM the agent wants to reach. The real target travels in the
    service argument (`+<vm>`).
  - Everything else → denied before any script executes.
```

The `connect_tcp_policy` tool adds/removes `qubes.ConnectTCP` policy lines via its own dom0 service (`saltbridge.ConnectTcpPolicy`). Because those rules name two VMs — a source and a target — allowlist enforcement happens **inside the service script** (which checks both against `/etc/qubes/salt-bridge-allowed-vms`) rather than via per-target qrexec policy lines, which can only constrain one VM at a time.

## License

MIT

## Acknowledgments

Built by [Claude](https://claude.ai) (Anthropic) with guidance and vision from [@mr-exitgames](https://github.com/mr-exitgames).

Designed for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and the [Qubes OS](https://www.qubes-os.org/) security model.
