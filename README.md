# Salt Bridge

**An MCP server that gives [Claude Code](https://docs.anthropic.com/en/docs/claude-code) full cross-VM management of a [Qubes OS](https://www.qubes-os.org/) system — command execution, file I/O, firewall rules, and network policy — all through dom0 qrexec.**

> [!CAUTION]
> ## This tool fundamentally breaks the Qubes OS security model.
>
> Qubes OS achieves security through **isolation** — each VM is a compartment, and no single VM can reach into another. Salt Bridge **deliberately removes that boundary** by granting one VM the ability to execute commands, read/write files, and modify firewall rules across *every other VM on the system*.
>
> **What this means in practice:**
> - A single compromised VM (the salt-bridge AppVM) = full compromise of every VM on the machine
> - Any MCP client bug, prompt injection, or supply-chain attack in that VM has dom0-equivalent reach
> - The qrexec policy grants blanket `allow` — there are no per-VM or per-command prompts
>
> **Salt Bridge is a development and administration tool.** It is designed for:
> - Qubes development machines where you are building/testing Qubes itself
> - Lab and experimentation environments
> - Machines where convenience outweighs compartmentalization
>
> **Do NOT install Salt Bridge on a Qubes system that holds sensitive data** — personal credentials, private keys, confidential documents, cryptocurrency wallets, or anything you rely on Qubes isolation to protect. If you need AI-assisted cross-VM tooling *with* isolation guarantees, see [Calcium Channel](https://github.com/mr-exitgames/calcium-channel) — a least-privilege MCP-over-qrexec mesh that routes MCP connections between isolated VMs with per-server ACLs, strengthening Qubes isolation rather than bypassing it.

## How It Works

Salt Bridge is an [MCP](https://modelcontextprotocol.io/) server that runs inside a dedicated Qubes VM. Claude Code connects to it like any MCP server, and each tool call crosses the Qubes security boundary via qrexec — the same mechanism Qubes itself uses for inter-VM communication.

```
                         qrexec boundary
                              │
  ┌──────────────────┐        │        ┌──────────┐       ┌──────────────┐
  │  salt-bridge VM  │        │        │   dom0   │       │  target VMs  │
  │                  │        │        │          │       │              │
  │  Claude Code     │        │        │          │       │  ┌────────┐  │
  │    │             │        │        │          │       │  │ work   │  │
  │    ▼             │        │        │          │       │  └────────┘  │
  │  MCP Server ─────────qrexec──────▶ Service ──────▶    │  ┌────────┐  │
  │  (server.py)     │        │        │ Scripts  │       │  │ vault  │  │
  │    ▲             │        │        │          │       │  └────────┘  │
  │    │             │        │        │ qvm-run  │       │  ┌────────┐  │
  │  Tool Result ◄───────────────────── qvm-fw    │◄──────│  │ dev    │  │
  │                  │        │        │ qvm-ls   │       │  └────────┘  │
  └──────────────────┘        │        └──────────┘       └──────────────┘
                              │
```

**The flow:**

1. Claude Code invokes an MCP tool (e.g. `exec_in_vm`)
2. `server.py` calls `qrexec-client-vm dom0 saltbridge.<Service>`
3. Dom0 qrexec policy checks if the calling VM is authorized
4. The dom0 service script runs the appropriate `qvm-*` command against the target
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
  │  1. Qrexec Policy (dom0)                            │
  │     Only the named VM can call saltbridge.* services│
  │                                                     │
  │  2. Target Blocking (dom0 + server.py)              │
  │     dom0 and the salt-bridge VM itself are          │
  │     rejected as targets for exec/read/write         │
  │                                                     │
  │  3. Input Validation (dom0 service scripts)         │
  │     VM names: ^[a-zA-Z][a-zA-Z0-9_-]*$              │
  │     Firewall args: ^[a-zA-Z0-9=\.:/\ -]+$           │
  │     Ports: integer 1–65535                          │
  │                                                     │
  │  4. Resource Limits (server.py)                     │
  │     Output capped at 2 MB (prevents OOM)            │
  │     30-second timeout per command                   │
  │                                                     │
  └─────────────────────────────────────────────────────┘
```

- **dom0 is never a valid target** for `exec_in_vm`, `exec_in_vm_root`, `read_file_in_vm`, or `write_file_in_vm` — enforced in both the dom0 service scripts and `server.py`.
- Only the VM explicitly named in the dom0 qrexec policy can invoke any Salt Bridge service. All other VMs are denied by default.
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
bash /tmp/sb-install.sh salt-bridge
```

Replace `salt-bridge` with whatever you named your VM. The installer:
- Copies all 12 qrexec service scripts to `/etc/qubes-rpc/`
- Creates `/etc/qubes/policy.d/30-salt-bridge.policy` authorizing that VM
- Can be re-run to add additional VMs or update services

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

After modifying qrexec services or policy, re-run the dom0 installer:

```bash
# In dom0:
qvm-run -p salt-bridge 'cat ~/salt-bridge/dom0-install.sh' > /tmp/sb-install.sh
bash /tmp/sb-install.sh salt-bridge
```

After modifying `server.py`, restart Claude Code to reload the MCP server.

## How Qrexec Policies Work

For those unfamiliar with Qubes, qrexec is the inter-VM RPC system. Salt Bridge uses it like this:

```
  30-salt-bridge.policy (in dom0):
  ┌────────────────────────────────────────────────────────┐
  │ saltbridge.VmList  *  salt-bridge  @adminvm  allow     │
  │ saltbridge.VmExec  *  salt-bridge  @adminvm  allow     │
  │ saltbridge.VmStart *  salt-bridge  @adminvm  allow     │
  │ ...                                                    │
  └────────────────────────────────────────────────────────┘
       │              │       │            │         │
   service name    arg   source VM    target VM   action

  Only "salt-bridge" VM can call these services.
  All other VMs → denied by default.
```

The `connect_tcp_policy` tool manages a separate policy file (`30-salt-bridge-tcp.policy`) for `qubes.ConnectTCP` rules, enabling TCP port forwarding between VMs without network routing.

## License

MIT

## Acknowledgments

Built by [Claude](https://claude.ai) (Anthropic) with guidance and vision from [@mr-exitgames](https://github.com/mr-exitgames).

Designed for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and the [Qubes OS](https://www.qubes-os.org/) security model.
