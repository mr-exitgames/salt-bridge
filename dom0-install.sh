#!/bin/bash
# Salt Bridge — dom0 installer
# Run this in dom0: qvm-run -p <claude-vm> 'cat /home/user/salt-bridge/dom0-install.sh' | bash -s <claude-vm-name>
set -euo pipefail

CLAUDE_VM="${1:?Usage: $0 <claude-vm-name>}"
SCRIPT_DIR="$(mktemp -d)"

echo "[*] Salt Bridge dom0 installer"
echo "[*] Claude VM: $CLAUDE_VM"

# Copy qrexec service scripts from claude-vm
echo "[*] Copying qrexec services..."
for svc in VmList VmStart VmShutdown VmNetworkInfo VmExec VmReadFile VmWriteFile; do
    qvm-run -p "$CLAUDE_VM" "cat /home/user/salt-bridge/dom0-setup/qubes-rpc/saltbridge.$svc" \
        > "/etc/qubes-rpc/saltbridge.$svc"
    chmod +x "/etc/qubes-rpc/saltbridge.$svc"
    echo "  + saltbridge.$svc"
done

# Install policy
echo "[*] Installing qrexec policy..."
qvm-run -p "$CLAUDE_VM" "cat /home/user/salt-bridge/dom0-setup/policy.d/30-salt-bridge.policy" \
    | sed "s/CLAUDE_VM/$CLAUDE_VM/g" \
    > "/etc/qubes/policy.d/30-salt-bridge.policy"
echo "  + /etc/qubes/policy.d/30-salt-bridge.policy"

echo ""
echo "[+] Salt Bridge installed successfully!"
echo "[+] $CLAUDE_VM can now manage VMs via qrexec."
echo ""
echo "To test from $CLAUDE_VM:"
echo "  qrexec-client-vm dom0 saltbridge.VmList"
