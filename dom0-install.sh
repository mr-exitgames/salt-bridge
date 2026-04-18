#!/bin/bash
# Salt Bridge — dom0 installer
#
# Run in dom0 (two steps — piping directly won't work due to stdin conflicts):
#   qvm-run -p <agent-vm> 'cat /home/user/salt-bridge/dom0-install.sh' > /tmp/sb-install.sh
#   bash /tmp/sb-install.sh <agent-vm> <target-vm> [<target-vm> ...]
#
# The installer replaces the allowlist and qrexec policy wholesale on every run.
# To change which VMs the agent can reach, re-invoke with the new complete list.
set -eu

usage() {
    cat <<EOF >&2
Usage: $(basename "$0") <agent-vm> <target-vm> [<target-vm> ...]

  <agent-vm>    The VM that runs the Salt Bridge MCP server (qrexec source).
  <target-vm>   One or more VMs the agent is allowed to manage.

The installer writes /etc/qubes/salt-bridge-allowed-vms and replaces
/etc/qubes/policy.d/30-salt-bridge.policy wholesale on each run.
EOF
    exit 1
}

if [[ $# -lt 2 ]]; then
    usage
fi

VM_NAME_RE='^[a-zA-Z][a-zA-Z0-9_-]*$'
RESERVED_NAMES=("dom0" "@adminvm" "@anyvm" "@dispvm")

validate_vm_name() {
    local vm="$1" role="$2" reserved
    if [[ ! "$vm" =~ $VM_NAME_RE ]]; then
        echo "ERROR: invalid $role VM name: '$vm'" >&2
        exit 1
    fi
    for reserved in "${RESERVED_NAMES[@]}"; do
        if [[ "$vm" == "$reserved" ]]; then
            echo "ERROR: reserved name '$vm' is not allowed as $role" >&2
            exit 1
        fi
    done
}

AGENT_VM="$1"
shift
TARGETS=("$@")

validate_vm_name "$AGENT_VM" "agent"

declare -A seen=()
for target in "${TARGETS[@]}"; do
    validate_vm_name "$target" "target"
    if [[ "$target" == "$AGENT_VM" ]]; then
        echo "ERROR: agent VM '$AGENT_VM' cannot also appear in the target list" >&2
        exit 1
    fi
    if [[ -n "${seen[$target]:-}" ]]; then
        echo "ERROR: duplicate target VM '$target'" >&2
        exit 1
    fi
    seen[$target]=1
done

echo "[*] Salt Bridge dom0 installer"
echo "[*] Agent VM:  $AGENT_VM"
echo "[*] Targets:   ${TARGETS[*]}"

if ! qvm-check "$AGENT_VM" &>/dev/null; then
    echo "ERROR: agent VM '$AGENT_VM' does not exist" >&2
    exit 1
fi
for target in "${TARGETS[@]}"; do
    if ! qvm-check "$target" &>/dev/null; then
        echo "ERROR: target VM '$target' does not exist" >&2
        exit 1
    fi
done

mkdir -p /etc/qubes-rpc /etc/qubes /etc/qubes/policy.d

# ---------- Allowlist file ----------
ALLOWLIST="/etc/qubes/salt-bridge-allowed-vms"
ALLOWLIST_TMP="${ALLOWLIST}.tmp.$$"
printf '%s\n' "${TARGETS[@]}" > "$ALLOWLIST_TMP"
chown root:root "$ALLOWLIST_TMP"
chmod 0644 "$ALLOWLIST_TMP"
mv -f "$ALLOWLIST_TMP" "$ALLOWLIST"
echo "[*] Wrote allowlist: $ALLOWLIST"

# ---------- Qrexec service scripts + shared library ----------
SERVICES=(VmList VmStart VmShutdown VmNetworkInfo VmExec VmExecRoot VmReadFile VmWriteFile FirewallList FirewallAdd FirewallRemove ConnectTcpPolicy)

copy_from_agent() {
    # $1 = source path inside the agent VM, $2 = destination in dom0, $3 = mode.
    local src="$1" dst="$2" mode="$3"
    if qvm-run -p "$AGENT_VM" "cat $src" > "$dst" 2>/dev/null; then
        chmod "$mode" "$dst"
        return 0
    fi
    rm -f "$dst"
    return 1
}

echo "[*] Copying shared library..."
if copy_from_agent "/home/user/salt-bridge/dom0-setup/qubes-rpc/saltbridge.lib.sh" "/etc/qubes-rpc/saltbridge.lib.sh" 0644; then
    echo "  + saltbridge.lib.sh"
else
    echo "ERROR: failed to read saltbridge.lib.sh from $AGENT_VM" >&2
    exit 1
fi

echo "[*] Copying qrexec services..."
for svc in "${SERVICES[@]}"; do
    if copy_from_agent "/home/user/salt-bridge/dom0-setup/qubes-rpc/saltbridge.$svc" "/etc/qubes-rpc/saltbridge.$svc" 0755; then
        echo "  + saltbridge.$svc"
    else
        echo "ERROR: failed to read saltbridge.$svc from $AGENT_VM" >&2
        exit 1
    fi
done

# ---------- Generate qrexec policy ----------
POLICY="/etc/qubes/policy.d/30-salt-bridge.policy"
POLICY_TMP="${POLICY}.tmp.$$"

# Services that accept a target VM as the qrexec argument (one +<vm> allow
# line per allowlist entry, then a catch-all deny).
ARG_SERVICES=(VmStart VmShutdown VmNetworkInfo VmExec VmExecRoot VmReadFile VmWriteFile FirewallList FirewallAdd FirewallRemove)

{
    printf '## Salt Bridge — generated policy. Do not edit by hand.\n'
    printf '## Agent VM: %s\n' "$AGENT_VM"
    printf '## Allowed target VMs: %s\n' "${TARGETS[*]}"
    printf '## Generated: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    printf '## saltbridge.VmList (no target argument)\n'
    printf 'saltbridge.VmList  *  %s  @adminvm  allow\n' "$AGENT_VM"
    printf 'saltbridge.VmList  *  @anyvm  @anyvm  deny\n\n'

    for svc in "${ARG_SERVICES[@]}"; do
        printf '## saltbridge.%s\n' "$svc"
        for target in "${TARGETS[@]}"; do
            printf 'saltbridge.%s  +%s  %s  @adminvm  allow\n' "$svc" "$target" "$AGENT_VM"
        done
        printf 'saltbridge.%s  *  %s  @anyvm  deny\n' "$svc" "$AGENT_VM"
        printf 'saltbridge.%s  *  @anyvm  @anyvm  deny\n\n' "$svc"
    done

    printf '## saltbridge.ConnectTcpPolicy (two-VM; service script enforces allowlist)\n'
    printf 'saltbridge.ConnectTcpPolicy  *  %s  @adminvm  allow\n' "$AGENT_VM"
    printf 'saltbridge.ConnectTcpPolicy  *  @anyvm  @anyvm  deny\n'
} > "$POLICY_TMP"

chown root:root "$POLICY_TMP"
chmod 0644 "$POLICY_TMP"
mv -f "$POLICY_TMP" "$POLICY"
echo "[*] Wrote policy:    $POLICY"

echo ""
echo "[+] Salt Bridge installed successfully."
echo "[+] Agent:   $AGENT_VM"
echo "[+] Targets: ${TARGETS[*]}"
echo ""
echo "Test from $AGENT_VM:"
echo "  qrexec-client-vm dom0 saltbridge.VmList"
echo "  qrexec-client-vm dom0 saltbridge.VmStart+${TARGETS[0]}"
