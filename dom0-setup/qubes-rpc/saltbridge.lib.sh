#!/bin/bash
# Salt Bridge — shared helpers for dom0 qrexec services.
# This file is sourced by the saltbridge.* service scripts; it is never
# invoked directly (no qrexec policy authorises it as a service).

SB_ALLOWLIST="/etc/qubes/salt-bridge-allowed-vms"
SB_VM_NAME_RE='^[a-zA-Z][a-zA-Z0-9_-]*$'

sb_log_deny() {
    logger -t salt-bridge -p auth.warning -- "$1" 2>/dev/null || true
}

sb_validate_vm_name() {
    local vm="$1" label="${2:-VM}"
    if [[ ! "$vm" =~ $SB_VM_NAME_RE ]]; then
        sb_log_deny "invalid $label name '$vm' from ${QREXEC_REMOTE_DOMAIN:-unknown}"
        echo "ERROR: Invalid $label name: '$vm'" >&2
        exit 1
    fi
    if [[ "$vm" == "dom0" || "$vm" == "@adminvm" || "$vm" == "@anyvm" ]]; then
        sb_log_deny "disallowed $label '$vm' from ${QREXEC_REMOTE_DOMAIN:-unknown}"
        echo "ERROR: '$vm' is not a valid target" >&2
        exit 1
    fi
}

sb_require_vm_arg() {
    # Require the target VM to be supplied as the qrexec service argument
    # (e.g. `saltbridge.VmExec+work`). Sets $SB_VM on success.
    if [[ -z "${QREXEC_SERVICE_ARGUMENT:-}" ]]; then
        sb_log_deny "missing service argument for ${QREXEC_SERVICE_FULL_NAME:-service} from ${QREXEC_REMOTE_DOMAIN:-unknown}"
        echo "ERROR: target VM must be passed as the qrexec service argument (e.g. saltbridge.<Service>+<vm>)" >&2
        exit 1
    fi
    SB_VM="$QREXEC_SERVICE_ARGUMENT"
    sb_validate_vm_name "$SB_VM" "target VM"
}

sb_check_allowlist() {
    # Reject if $1 is not listed in the dom0 allowlist file. Fail-closed on
    # missing / symlinked / empty / unreadable allowlist — never default-allow.
    local vm="$1"
    if [[ ! -f "$SB_ALLOWLIST" || -L "$SB_ALLOWLIST" ]]; then
        sb_log_deny "allowlist missing or is symlink; denying '$vm'"
        echo "ERROR: Salt Bridge allowlist is not installed or is invalid" >&2
        exit 1
    fi
    if ! grep -Fxq -- "$vm" "$SB_ALLOWLIST"; then
        sb_log_deny "'$vm' not in allowlist; denied ${QREXEC_SERVICE_FULL_NAME:-service} from ${QREXEC_REMOTE_DOMAIN:-unknown}"
        echo "ERROR: VM '$vm' is not in the Salt Bridge allowlist" >&2
        exit 1
    fi
}
