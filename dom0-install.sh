#!/bin/bash
# Salt Bridge — dom0 installer
# Run in dom0 (two steps — piping directly won't work due to stdin conflicts):
#   qvm-run -p <claude-vm> 'cat /home/user/salt-bridge/dom0-install.sh' > /tmp/sb-install.sh
#   bash /tmp/sb-install.sh <claude-vm-name>
set -eu

CLAUDE_VM="${1:?Usage: $0 <claude-vm-name>}"

echo "[*] Salt Bridge dom0 installer"
echo "[*] Claude VM: $CLAUDE_VM"

# Verify the VM exists
if ! qvm-check "$CLAUDE_VM" &>/dev/null; then
    echo "ERROR: VM '$CLAUDE_VM' does not exist" >&2
    exit 1
fi

# Ensure directories exist
mkdir -p /etc/qubes-rpc /etc/qubes/policy.d

# Copy qrexec service scripts from claude-vm
echo "[*] Copying qrexec services..."
for svc in VmList VmStart VmShutdown VmNetworkInfo VmExec VmExecRoot VmReadFile VmWriteFile; do
    if qvm-run -p "$CLAUDE_VM" "cat /home/user/salt-bridge/dom0-setup/qubes-rpc/saltbridge.$svc" \
        > "/etc/qubes-rpc/saltbridge.$svc" 2>/dev/null; then
        chmod +x "/etc/qubes-rpc/saltbridge.$svc"
        echo "  + saltbridge.$svc"
    else
        rm -f "/etc/qubes-rpc/saltbridge.$svc"
        echo "  ~ saltbridge.$svc (not found in VM, skipping)"
    fi
done

# Install policy
POLICY="/etc/qubes/policy.d/30-salt-bridge.policy"
echo "[*] Installing qrexec policy..."

# Fetch policy template and substitute VM name
POLICY_CONTENT=$(qvm-run -p "$CLAUDE_VM" "cat /home/user/salt-bridge/dom0-setup/policy.d/30-salt-bridge.policy" 2>/dev/null \
    | sed "s/CLAUDE_VM/$CLAUDE_VM/g")

if [[ -z "$POLICY_CONTENT" ]]; then
    echo "ERROR: Failed to read policy template from $CLAUDE_VM" >&2
    exit 1
fi

if [[ -f "$POLICY" ]] && grep -q "$CLAUDE_VM" "$POLICY"; then
    echo "  ~ $CLAUDE_VM already in policy, overwriting"
    echo "$POLICY_CONTENT" > "$POLICY"
elif [[ -f "$POLICY" ]]; then
    echo "" >> "$POLICY"
    echo "## Added: $CLAUDE_VM ($(date +%Y-%m-%d))" >> "$POLICY"
    echo "$POLICY_CONTENT" | grep "$CLAUDE_VM" >> "$POLICY"
    echo "  + Appended $CLAUDE_VM to existing policy"
else
    echo "$POLICY_CONTENT" > "$POLICY"
    echo "  + Created $POLICY"
fi

echo ""
echo "[+] Salt Bridge installed successfully!"
echo "[+] $CLAUDE_VM can now manage VMs via qrexec."
echo ""
echo "Current policy:"
cat "$POLICY"
echo ""
echo "To test from $CLAUDE_VM:"
echo "  qrexec-client-vm dom0 saltbridge.VmList"
