#!/bin/bash
# Salt Bridge — dom0 installer (bootstrap)
#
# Run in dom0 (two steps — piping directly won't work due to stdin conflicts):
#   qvm-run -p <agent-vm> 'cat /home/user/salt-bridge/dom0-install.sh' > /tmp/sb-install.sh
#   bash /tmp/sb-install.sh <agent-vm> <target-vm> [<target-vm> ...]
#
# On success, writes a self-contained updater to $PWD/salt-bridge-update.sh
# with all service files embedded — future reconfigures/reinstalls do not
# need to reach back into the agent VM.
set -eu

# BEGIN COMMON
# Shared install logic — copied verbatim into the generated update script.

VM_NAME_RE='^[a-zA-Z][a-zA-Z0-9_-]*$'
RESERVED_NAMES=("dom0" "@adminvm" "@anyvm" "@dispvm")
SERVICES=(VmList VmStart VmShutdown VmNetworkInfo VmExec VmExecRoot VmReadFile VmWriteFile FirewallList FirewallAdd FirewallRemove ConnectTcpPolicy)
ARG_SERVICES=(VmStart VmShutdown VmNetworkInfo VmExec VmExecRoot VmReadFile VmWriteFile FirewallList FirewallAdd FirewallRemove)

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

validate_args() {
    local agent_vm="$1"
    shift
    local targets=("$@")
    local target
    declare -A seen=()

    validate_vm_name "$agent_vm" "agent"
    for target in "${targets[@]}"; do
        validate_vm_name "$target" "target"
        if [[ "$target" == "$agent_vm" ]]; then
            echo "ERROR: agent VM '$agent_vm' cannot also appear in the target list" >&2
            exit 1
        fi
        if [[ -n "${seen[$target]:-}" ]]; then
            echo "ERROR: duplicate target VM '$target'" >&2
            exit 1
        fi
        seen[$target]=1
    done

    if ! qvm-check "$agent_vm" &>/dev/null; then
        echo "ERROR: agent VM '$agent_vm' does not exist" >&2
        exit 1
    fi
    for target in "${targets[@]}"; do
        if ! qvm-check "$target" &>/dev/null; then
            echo "ERROR: target VM '$target' does not exist" >&2
            exit 1
        fi
    done
}

install_services() {
    local src_dir="$1" svc
    mkdir -p /etc/qubes-rpc
    install -m 0644 -o root -g root "$src_dir/saltbridge.lib.sh" /etc/qubes-rpc/saltbridge.lib.sh
    echo "  + saltbridge.lib.sh"
    for svc in "${SERVICES[@]}"; do
        install -m 0755 -o root -g root "$src_dir/saltbridge.$svc" "/etc/qubes-rpc/saltbridge.$svc"
        echo "  + saltbridge.$svc"
    done
}

write_allowlist() {
    local allowlist="/etc/qubes/salt-bridge-allowed-vms"
    local tmp="${allowlist}.tmp.$$"
    printf '%s\n' "$@" > "$tmp"
    chown root:root "$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$allowlist"
}

write_policy() {
    local agent_vm="$1"
    shift
    local targets=("$@")
    local policy="/etc/qubes/policy.d/30-salt-bridge.policy"
    local tmp="${policy}.tmp.$$"
    local svc target

    {
        printf '## Salt Bridge — generated policy. Do not edit by hand.\n'
        printf '## Agent VM: %s\n' "$agent_vm"
        printf '## Allowed target VMs: %s\n' "${targets[*]}"
        printf '## Generated: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

        printf '## saltbridge.VmList (no target argument)\n'
        printf 'saltbridge.VmList  *  %s  @adminvm  allow\n' "$agent_vm"
        printf 'saltbridge.VmList  *  @anyvm  @anyvm  deny\n\n'

        for svc in "${ARG_SERVICES[@]}"; do
            printf '## saltbridge.%s\n' "$svc"
            for target in "${targets[@]}"; do
                printf 'saltbridge.%s  +%s  %s  @adminvm  allow\n' "$svc" "$target" "$agent_vm"
            done
            printf 'saltbridge.%s  *  %s  @anyvm  deny\n' "$svc" "$agent_vm"
            printf 'saltbridge.%s  *  @anyvm  @anyvm  deny\n\n' "$svc"
        done

        printf '## saltbridge.ConnectTcpPolicy (two-VM; service script enforces allowlist)\n'
        printf 'saltbridge.ConnectTcpPolicy  *  %s  @adminvm  allow\n' "$agent_vm"
        printf 'saltbridge.ConnectTcpPolicy  *  @anyvm  @anyvm  deny\n'
    } > "$tmp"

    chown root:root "$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$policy"
}

apply_install() {
    local src_dir="$1" agent_vm="$2"
    shift 2
    local targets=("$@")

    mkdir -p /etc/qubes-rpc /etc/qubes /etc/qubes/policy.d

    echo "[*] Salt Bridge dom0 installer"
    echo "[*] Agent VM:  $agent_vm"
    echo "[*] Targets:   ${targets[*]}"

    validate_args "$agent_vm" "${targets[@]}"

    write_allowlist "${targets[@]}"
    echo "[*] Wrote allowlist: /etc/qubes/salt-bridge-allowed-vms"

    echo "[*] Installing qrexec services..."
    install_services "$src_dir"

    write_policy "$agent_vm" "${targets[@]}"
    echo "[*] Wrote policy:    /etc/qubes/policy.d/30-salt-bridge.policy"
}
# END COMMON

usage() {
    cat <<EOF >&2
Usage: $(basename "$0") <agent-vm> <target-vm> [<target-vm> ...]

  <agent-vm>    The VM that runs the Salt Bridge MCP server (qrexec source).
  <target-vm>   One or more VMs the agent is allowed to manage.

The installer writes /etc/qubes/salt-bridge-allowed-vms, replaces
/etc/qubes/policy.d/30-salt-bridge.policy wholesale, and drops a
self-contained updater at \$PWD/salt-bridge-update.sh for future
reinstalls/allowlist changes without needing the agent VM.
EOF
    exit 1
}

if [[ $# -lt 2 ]]; then
    usage
fi

AGENT_VM="$1"
shift
TARGETS=("$@")

# Validate up front so we don't pull files on bad input.
validate_args "$AGENT_VM" "${TARGETS[@]}"

TMPDIR=$(mktemp -d -t sb-install.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

echo "[*] Fetching service files from $AGENT_VM..."
for f in saltbridge.lib.sh "${SERVICES[@]/#/saltbridge.}"; do
    if ! qvm-run -p "$AGENT_VM" "cat /home/user/salt-bridge/dom0-setup/qubes-rpc/$f" > "$TMPDIR/$f" 2>/dev/null; then
        echo "ERROR: failed to read $f from $AGENT_VM" >&2
        exit 1
    fi
    if [[ ! -s "$TMPDIR/$f" ]]; then
        echo "ERROR: fetched $f from $AGENT_VM is empty" >&2
        exit 1
    fi
done

apply_install "$TMPDIR" "$AGENT_VM" "${TARGETS[@]}"

# ---------- Emit self-contained update script ----------
UPDATE_SCRIPT="$PWD/salt-bridge-update.sh"
UPDATE_TMP="${UPDATE_SCRIPT}.tmp.$$"

{
    cat <<'HEADER_EOF'
#!/bin/bash
# Salt Bridge — self-contained dom0 update script
#
# Auto-generated by dom0-install.sh. Contains base64-embedded copies of
# every qrexec service file, so it can reinstall services, rewrite the
# allowlist, and regenerate qrexec policy without reaching back into
# the agent VM.
#
# Usage:
#   bash salt-bridge-update.sh <agent-vm> <target-vm> [<target-vm> ...]
set -eu

HEADER_EOF

    # Embed the shared install logic verbatim.
    awk '/^# BEGIN COMMON$/,/^# END COMMON$/' "$0"

    # Embed service files as base64 heredocs and an extractor function.
    printf '\nextract_bundle() {\n'
    printf '    local dst_dir="$1"\n'
    printf '    mkdir -p "$dst_dir"\n'
    for f in saltbridge.lib.sh "${SERVICES[@]/#/saltbridge.}"; do
        printf '    base64 -d > "$dst_dir/%s" <<'"'"'SB_B64_EOF'"'"'\n' "$f"
        base64 < "$TMPDIR/$f"
        printf 'SB_B64_EOF\n'
    done
    printf '}\n\n'

    cat <<'FOOTER_EOF'
usage() {
    cat <<USAGE_EOF >&2
Usage: $(basename "$0") <agent-vm> <target-vm> [<target-vm> ...]

Self-contained Salt Bridge updater. Extracts the embedded qrexec service
files to a temp dir, then replaces the allowlist, services, and qrexec
policy in dom0. The agent VM is never contacted.

Re-run this any time to change the allowlist — the installer is
destructive: it replaces the allowlist and policy wholesale.
USAGE_EOF
    exit 1
}

if [[ $# -lt 2 ]]; then
    usage
fi

AGENT_VM="$1"
shift
TARGETS=("$@")

TMPDIR=$(mktemp -d -t sb-update.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

extract_bundle "$TMPDIR"
apply_install "$TMPDIR" "$AGENT_VM" "${TARGETS[@]}"

echo ""
echo "[+] Salt Bridge updated successfully."
echo "[+] Agent:   $AGENT_VM"
echo "[+] Targets: ${TARGETS[*]}"
FOOTER_EOF
} > "$UPDATE_TMP"

chmod 0755 "$UPDATE_TMP"
mv -f "$UPDATE_TMP" "$UPDATE_SCRIPT"

echo ""
echo "[+] Salt Bridge installed successfully."
echo "[+] Agent:   $AGENT_VM"
echo "[+] Targets: ${TARGETS[*]}"
echo ""
echo "Self-contained updater written to:"
echo "  $UPDATE_SCRIPT"
echo ""
echo "Re-run any time to change the allowlist or reinstall services"
echo "without touching the agent VM:"
echo "  bash $UPDATE_SCRIPT $AGENT_VM ${TARGETS[*]}"
echo ""
echo "Test from $AGENT_VM:"
echo "  qrexec-client-vm dom0 saltbridge.VmList"
echo "  qrexec-client-vm dom0 saltbridge.VmStart+${TARGETS[0]}"
