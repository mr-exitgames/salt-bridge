# Salt Bridge

A privileged MCP server for managing Qubes OS systems from Claude Code. Provides cross-VM command execution, file operations, firewall management, and TCP port forwarding policy — all mediated through dom0 qrexec services.

> **Warning:** Salt Bridge grants near-dom0-level access to a single VM. Any compromise of that VM effectively compromises your entire Qubes system. Use a dedicated, minimal AppVM.

## How it works

```
salt-bridge VM          dom0                    target VM
─────────────           ────                    ─────────
Claude Code             qrexec policy           AppVM/TemplateVM
  │                       │                       │
  ├─ MCP server ──►  qrexec service  ──►  qvm-run / qvm-firewall
  │  (server.py)      (saltbridge.*)          executes command
  │                       │                       │
  ◄── structured ──── stdout/stderr ◄──── result piped back
     tool result
```

The MCP server (`server.py`) runs in the Salt Bridge VM. Each tool call invokes `qrexec-client-vm dom0 saltbridge.<Service>`, which dom0's qrexec policy either allows or denies. The dom0 service scripts then execute `qvm-run`, `qvm-firewall`, etc. against the target VM.

## MCP Tools

| Tool | Description |
|---|---|
| `list_vms` | List all VMs with state, type, netvm, IP, label |
| `start_vm` | Start a VM |
| `shutdown_vm` | Gracefully shut down a VM |
| `vm_network_info` | IPs, routes, DNS, iptables, WireGuard status |
| `exec_in_vm` | Run a command as the default user |
| `exec_in_vm_root` | Run a command as root (for templates, minimal VMs) |
| `read_file_in_vm` | Read a file from any VM |
| `write_file_in_vm` | Write a file to any VM |
| `firewall_list` | List qvm-firewall rules for a VM |
| `firewall_add` | Add a firewall rule (accept/drop with dst/proto/port) |
| `firewall_remove` | Remove a firewall rule by number |
| `connect_tcp_policy` | Manage qubes.ConnectTCP qrexec policy rules |

### Security restrictions

- `exec_in_vm`, `exec_in_vm_root`, `read_file_in_vm`, and `write_file_in_vm` refuse to target `dom0` / `@adminvm`.
- Only the VM named in the dom0 policy can call any Salt Bridge service.
- VM names are validated against `^[a-zA-Z][a-zA-Z0-9_-]*$`.

## Installation

### Prerequisites

- Qubes OS 4.x
- Python 3 with `mcp[cli]>=1.0.0` in the Salt Bridge VM
- A dedicated AppVM for Salt Bridge (recommended)

### 1. Install in the Salt Bridge VM

```bash
pip install --break-system-packages "mcp[cli]>=1.0.0"
```

Add to `~/.mcp.json`:

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

### 2. Install in dom0

Two-step process (piping directly causes stdin conflicts with `qvm-run`):

```bash
qvm-run -p <salt-bridge-vm> 'cat /home/user/salt-bridge/dom0-install.sh' > /tmp/sb-install.sh
bash /tmp/sb-install.sh <salt-bridge-vm>
```

The installer:
- Copies all qrexec service scripts to `/etc/qubes-rpc/`
- Creates `/etc/qubes/policy.d/30-salt-bridge.policy` granting access to the named VM
- Supports adding multiple VMs by re-running (appends to existing policy)

### 3. Restart Claude Code

The MCP server starts automatically when Claude Code launches.

## File structure

```
salt-bridge/
├── server.py                          # MCP server (runs in salt-bridge VM)
├── dom0-install.sh                    # dom0 installer script
├── dom0-setup/
│   ├── policy.d/
│   │   └── 30-salt-bridge.policy      # qrexec policy template
│   └── qubes-rpc/
│       ├── saltbridge.VmList          # qvm-ls wrapper
│       ├── saltbridge.VmStart         # qvm-start wrapper
│       ├── saltbridge.VmShutdown      # qvm-shutdown wrapper
│       ├── saltbridge.VmNetworkInfo   # Network diagnostics
│       ├── saltbridge.VmExec          # qvm-run (user)
│       ├── saltbridge.VmExecRoot      # qvm-run -u root
│       ├── saltbridge.VmReadFile      # Read file via qvm-run
│       ├── saltbridge.VmWriteFile     # Write file via qvm-run
│       ├── saltbridge.FirewallList    # qvm-firewall list
│       ├── saltbridge.FirewallAdd     # qvm-firewall add
│       ├── saltbridge.FirewallRemove  # qvm-firewall del
│       └── saltbridge.ConnectTcpPolicy # Manage ConnectTCP rules
└── requirements.txt
```

## Related projects

- **[Calcium Channel](../calcium-channel)** — Least-privilege MCP-over-qrexec mesh. Routes MCP server connections between isolated VMs with per-server ACLs. Unlike Salt Bridge, Calcium Channel *strengthens* Qubes isolation rather than bypassing it.
