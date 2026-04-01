#!/usr/bin/env python3
"""Salt Bridge — Qubes OS MCP Server for cross-VM management."""

import json
import os
import select
import subprocess
import threading
import time
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("salt-bridge", instructions="""
You are connected to a Qubes OS system via Salt Bridge.
Use list_vms to discover the VM topology before taking action.
VM names are strict — always verify with list_vms first.
For network debugging, vm_network_info gives you IPs, routes, DNS, and WireGuard status.
exec_in_vm runs commands as the default user in the target VM.

IMPORTANT constraints:
- exec_in_vm, exec_in_vm_root, read_file_in_vm, and write_file_in_vm do NOT work on dom0/adminvm — the qrexec policy blocks it. Do not attempt to target dom0 with these tools.
- These tools also cannot target 'salt-bridge' itself. Use local tools (Read, Write, Bash, Grep, Glob) for files in this VM.

Dom0 policy management:
- connect_tcp_policy can add/remove/list qubes.ConnectTCP rules in dom0. Use it when a VM needs TCP access to another VM via qrexec (e.g. SSH through qrexec-client-vm). This is the correct tool for managing those rules — do not ask the user to edit dom0 policy files manually.
""")

QREXEC_TARGET = "dom0"
TIMEOUT = 30
MAX_OUTPUT = 2 * 1024 * 1024  # 2MB cap — prevents OOM from large command output

# The MCP server runs inside this VM — targeting it via qrexec is unnecessary
# and creates confusing self-referential loops. Use local tools (Read, Grep,
# Bash, etc.) instead when operating on salt-bridge itself.
_SELF_VM = "salt-bridge"


def _reject_self(vm_name: str, tool: str) -> str | None:
    """Return an error string if vm_name targets the MCP server's own VM."""
    if vm_name.lower() == _SELF_VM:
        return (
            f"ERROR: {tool} cannot target '{_SELF_VM}' — that is the VM this MCP "
            "server runs in. Use local tools (Read, Write, Bash, Grep, Glob) directly."
        )
    return None


def call_dom0(service: str, input_data: str = "", timeout: int = TIMEOUT) -> str:
    """Call a qrexec service in dom0."""
    try:
        proc = subprocess.Popen(
            ["qrexec-client-vm", QREXEC_TARGET, service],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except Exception as e:
        return f"ERROR: {e}"

    stderr_buf: list[bytes] = []

    def _read_stderr():
        data = proc.stderr.read(MAX_OUTPUT)
        stderr_buf.append(data)

    stderr_thread = threading.Thread(target=_read_stderr, daemon=True)
    stderr_thread.start()

    if input_data:
        proc.stdin.write(input_data.encode())
    proc.stdin.close()

    chunks: list[bytes] = []
    total = 0
    truncated = False
    deadline = time.monotonic() + timeout
    stdout_fd = proc.stdout.fileno()
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                proc.kill()
                return f"ERROR: Command timed out after {timeout}s"
            ready, _, _ = select.select([stdout_fd], [], [], min(remaining, 1.0))
            if not ready:
                continue  # select timed out — loop to recheck deadline
            chunk = os.read(stdout_fd, 65536)
            if not chunk:
                break
            if total + len(chunk) > MAX_OUTPUT:
                chunks.append(chunk[:MAX_OUTPUT - total])
                truncated = True
                proc.kill()
                break
            chunks.append(chunk)
            total += len(chunk)
    finally:
        proc.stdout.close()

    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()

    stderr_thread.join(timeout=2)

    stdout = b"".join(chunks).decode(errors="replace")
    stderr = (stderr_buf[0] if stderr_buf else b"").decode(errors="replace")

    if truncated:
        stdout += f"\n[TRUNCATED: output exceeded {MAX_OUTPUT // 1024}KB — pipe to a file or filter the command]"

    output = stdout
    if stderr:
        output += f"\nSTDERR: {stderr}"
    if (rc := proc.returncode) is not None and rc not in (0, -9):
        output += f"\nEXIT CODE: {rc}"
    return output


@mcp.tool()
def list_vms() -> str:
    """List all Qubes VMs with name, state, type, netvm, IP, and label."""
    return call_dom0("saltbridge.VmList")


@mcp.tool()
def start_vm(vm_name: str) -> str:
    """Start a Qubes VM."""
    return call_dom0("saltbridge.VmStart", vm_name)


@mcp.tool()
def shutdown_vm(vm_name: str) -> str:
    """Gracefully shutdown a Qubes VM."""
    return call_dom0("saltbridge.VmShutdown", vm_name)


@mcp.tool()
def vm_network_info(vm_name: str) -> str:
    """Get detailed network info for a VM: IPs, routes, DNS, interfaces, and WireGuard status."""
    return call_dom0("saltbridge.VmNetworkInfo", vm_name, timeout=15)


@mcp.tool()
def exec_in_vm(vm_name: str, command: str, timeout_seconds: int = 30) -> str:
    """Execute a shell command in a target VM as the default user. Returns combined stdout/stderr. dom0 is not a valid target — the policy blocks it."""
    if err := _reject_self(vm_name, "exec_in_vm"):
        return err
    payload = json.dumps({"vm": vm_name, "cmd": command})
    return call_dom0("saltbridge.VmExec", payload, timeout=timeout_seconds + 5)


@mcp.tool()
def exec_in_vm_root(vm_name: str, command: str, timeout_seconds: int = 30) -> str:
    """Execute a shell command in a target VM as root. Use for template VMs or when sudo is unavailable. dom0 is not a valid target — the policy blocks it."""
    if err := _reject_self(vm_name, "exec_in_vm_root"):
        return err
    payload = json.dumps({"vm": vm_name, "cmd": command})
    return call_dom0("saltbridge.VmExecRoot", payload, timeout=timeout_seconds + 5)


@mcp.tool()
def read_file_in_vm(vm_name: str, file_path: str) -> str:
    """Read a file from a target VM. dom0 is not a valid target — the policy blocks it."""
    if err := _reject_self(vm_name, "read_file_in_vm"):
        return err
    payload = json.dumps({"vm": vm_name, "path": file_path})
    return call_dom0("saltbridge.VmReadFile", payload)


@mcp.tool()
def write_file_in_vm(vm_name: str, file_path: str, content: str) -> str:
    """Write content to a file in a target VM. Creates parent directories if needed. dom0 is not a valid target — the policy blocks it."""
    if err := _reject_self(vm_name, "write_file_in_vm"):
        return err
    payload = json.dumps({"vm": vm_name, "path": file_path, "content": content})
    return call_dom0("saltbridge.VmWriteFile", payload)


@mcp.tool()
def firewall_list(vm_name: str) -> str:
    """List all firewall rules for a VM."""
    return call_dom0("saltbridge.FirewallList", vm_name)


@mcp.tool()
def firewall_add(vm_name: str, action: str, args: str = "") -> str:
    """Add a firewall rule to a VM. Action is 'accept' or 'drop'. Args are qvm-firewall parameters like 'dsthost=10.137.0.20 proto=tcp dstports=22'."""
    payload = json.dumps({"vm": vm_name, "action": action, "args": args})
    return call_dom0("saltbridge.FirewallAdd", payload)


@mcp.tool()
def firewall_remove(vm_name: str, rule_number: int) -> str:
    """Remove a firewall rule from a VM by rule number. Use firewall_list to see rule numbers."""
    payload = json.dumps({"vm": vm_name, "rule_number": rule_number})
    return call_dom0("saltbridge.FirewallRemove", payload)


@mcp.tool()
def connect_tcp_policy(action: str, source: str = "", target: str = "", port: int = 0) -> str:
    """Manage qubes.ConnectTCP qrexec policy rules. Action: 'list', 'add', or 'remove'. For add/remove, specify source VM, target VM, and port."""
    payload = json.dumps({"action": action, "source": source, "target": target, "port": port})
    return call_dom0("saltbridge.ConnectTcpPolicy", payload)


if __name__ == "__main__":
    mcp.run()
