#!/usr/bin/env python3
"""Salt Bridge — Qubes OS MCP Server for cross-VM management."""

import json
import subprocess
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("salt-bridge", instructions="""
You are connected to a Qubes OS system via Salt Bridge.
Use list_vms to discover the VM topology before taking action.
VM names are strict — always verify with list_vms first.
For network debugging, vm_network_info gives you IPs, routes, DNS, and WireGuard status.
exec_in_vm runs commands as the default user in the target VM.
""")

QREXEC_TARGET = "dom0"
TIMEOUT = 30


def call_dom0(service: str, input_data: str = "", timeout: int = TIMEOUT) -> str:
    """Call a qrexec service in dom0."""
    try:
        result = subprocess.run(
            ["qrexec-client-vm", QREXEC_TARGET, service],
            input=input_data,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return f"ERROR: Command timed out after {timeout}s"

    output = result.stdout
    if result.stderr:
        output += f"\nSTDERR: {result.stderr}"
    if result.returncode != 0:
        output += f"\nEXIT CODE: {result.returncode}"
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
    """Execute a shell command in a target VM as the default user. Returns combined stdout/stderr."""
    payload = json.dumps({"vm": vm_name, "cmd": command})
    return call_dom0("saltbridge.VmExec", payload, timeout=timeout_seconds + 5)


@mcp.tool()
def exec_in_vm_root(vm_name: str, command: str, timeout_seconds: int = 30) -> str:
    """Execute a shell command in a target VM as root. Use for template VMs or when sudo is unavailable."""
    payload = json.dumps({"vm": vm_name, "cmd": command})
    return call_dom0("saltbridge.VmExecRoot", payload, timeout=timeout_seconds + 5)


@mcp.tool()
def read_file_in_vm(vm_name: str, file_path: str) -> str:
    """Read a file from a target VM."""
    payload = json.dumps({"vm": vm_name, "path": file_path})
    return call_dom0("saltbridge.VmReadFile", payload)


@mcp.tool()
def write_file_in_vm(vm_name: str, file_path: str, content: str) -> str:
    """Write content to a file in a target VM. Creates parent directories if needed."""
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
