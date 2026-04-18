#!/usr/bin/env bash
# Verify: GenesysLogic GL3590 hub LPM fix (UGREEN Revodok CM818, CachyOS)
#
# Device : UGREEN Revodok CM818 (P/N 45363), 6-in-1 USB-C hub
# Chipset: GenesysLogic GL3590  USB ID: 05e3:0625
# OS     : CachyOS (Arch-based), Limine bootloader
#
# Checks (in order):
#   1. Runtime  — usbcore.quirks contains '05e3:0625:k'
#   2. Device   — NO_LPM bit (0x400) set, power/control=on, LPM file absent
#   3. Udev     — 99-usb-genesyslogic-nolpm.rules exists and is well-formed
#   4. Persist  — modprobe.d file exists with correct letter encoding
#   5. Persist  — kernel cmdline has the quirk (/etc/kernel/cmdline + Limine)
#   6. Persist  — systemd service exists and is enabled
#   7. Stability— no hub errors in dmesg in the last 2 minutes
#
# Usage: sudo bash verify-usb-hub-fix.sh

set -euo pipefail
shopt -s nullglob   # unmatched globs -> empty, not literal string

# ── Require root (needed for dmesg on hardened systems) ─────────────────────
[[ $EUID -eq 0 ]] || { echo "[ERR] Run as root: sudo bash $0"; exit 1; }

VID="05e3"
PID="0625"
NO_LPM_BIT=$(( 1 << 10 ))   # 0x400 — USB_QUIRK_NO_LPM
PASS=0; FAIL=0; WARN=0

ok()   { echo "  [PASS] $*"; (( PASS++ )) || true; }
fail() { echo "  [FAIL] $*"; (( FAIL++ )) || true; }
warn() { echo "  [WARN] $*"; (( WARN++ )) || true; }
info() { echo "         $*"; }

# ── Helper: locate hub sysfs path ───────────────────────────────────────────
find_hub() {
    for d in /sys/bus/usb/devices/*/; do
        [[ -f "${d}idVendor"  ]] || continue
        [[ -f "${d}idProduct" ]] || continue
        [[ "$(< "${d}idVendor")"  == "${VID}" ]] || continue
        [[ "$(< "${d}idProduct")" == "${PID}" ]] || continue
        echo "${d%/}"
        return 0
    done
    echo ""
}

echo "=== USB Hub LPM Fix Verification ==="
echo "    Target: ${VID}:${PID} (GenesysLogic GL3590)"
echo ""

# ── 1. Runtime quirk ─────────────────────────────────────────────────────────
echo "── 1. Runtime quirk (/sys/module/usbcore/parameters/quirks)"
QUIRKS_PATH="/sys/module/usbcore/parameters/quirks"
if [[ -f "${QUIRKS_PATH}" ]]; then
    RUNTIME_QUIRKS=$(cat "${QUIRKS_PATH}" 2>/dev/null || true)
    info "Value: '${RUNTIME_QUIRKS}'"
    if [[ "${RUNTIME_QUIRKS}" == *"${VID}:${PID}:k"* ]]; then
        ok "NO_LPM quirk (letter 'k') present in runtime quirks table"
    else
        fail "Expected '${VID}:${PID}:k' not found — run fix script as root"
    fi
else
    fail "${QUIRKS_PATH} not found — is usbcore loaded?"
fi

# ── 2. Device sysfs ──────────────────────────────────────────────────────────
echo ""
echo "── 2. Device sysfs (requires hub physically connected)"
HUB_SYS=$(find_hub)

if [[ -n "${HUB_SYS}" ]]; then
    DEV_QUIRKS=$(cat "${HUB_SYS}/quirks"        2>/dev/null || echo "?")
    SPEED=$(     cat "${HUB_SYS}/speed"         2>/dev/null || echo "?")
    VERSION=$(   cat "${HUB_SYS}/version"       2>/dev/null | tr -d ' ' || echo "?")
    CTRL=$(      cat "${HUB_SYS}/power/control" 2>/dev/null || echo "?")
    RUNTIME=$(   cat "${HUB_SYS}/power/runtime_status" 2>/dev/null || echo "?")
    LPM_U1_FILE="${HUB_SYS}/power/usb3_hardware_lpm_u1"

    info "Sysfs path : ${HUB_SYS}"
    info "USB version: ${VERSION}   Speed: ${SPEED} Mbps"
    info "quirks     : ${DEV_QUIRKS}   (NO_LPM bit = 0x400)"
    info "power/control       : ${CTRL}"
    info "power/runtime_status: ${RUNTIME}"

    if [[ "${DEV_QUIRKS}" =~ ^0x[0-9a-fA-F]+$ ]] && (( DEV_QUIRKS & NO_LPM_BIT )); then
        ok "USB_QUIRK_NO_LPM bit (0x400) confirmed set on live device"
    elif [[ "${DEV_QUIRKS}" == "?" ]]; then
        fail "Could not read device quirks"
    else
        fail "NO_LPM bit NOT set in device quirks (${DEV_QUIRKS}) — replug hub after fix"
    fi

    [[ "${CTRL}" == "on" ]]     && ok "power/control=on (autosuspend disabled)" \
                                || fail "power/control is '${CTRL}', expected 'on'"

    [[ "${RUNTIME}" == "active" ]] && ok "Hub runtime_status=active (not suspended)" \
                                   || warn "Hub runtime_status='${RUNTIME}' (expected active)"

    if [[ ! -f "${LPM_U1_FILE}" ]]; then
        ok "usb3_hardware_lpm_u1 absent — LPM U1 hardware transitions disabled"
    else
        LPM_VAL=$(cat "${LPM_U1_FILE}" 2>/dev/null || echo "?")
        warn "usb3_hardware_lpm_u1 exists with value '${LPM_VAL}' — LPM may still be active"
    fi

    LSUSB_LINE=$(lsusb | grep "${VID}:${PID}" || true)
    if [[ -n "${LSUSB_LINE}" ]]; then
        ok "Hub visible in lsusb"
        info "${LSUSB_LINE}"
    else
        fail "Hub not found in lsusb output"
    fi
else
    warn "Hub not found in sysfs — replug it and rerun to verify device checks"
fi

# ── 3. Udev rule ─────────────────────────────────────────────────────────────
echo ""
echo "── 3. Udev rule"
UDEV_RULE="/etc/udev/rules.d/99-usb-genesyslogic-nolpm.rules"
if [[ -f "${UDEV_RULE}" ]]; then
    ok "${UDEV_RULE} exists"
    grep -q 'power/control.*"on"' "${UDEV_RULE}" \
        && ok "Rule sets power/control=on" \
        || fail "power/control=on not found in udev rule"
    grep -q 'autosuspend_delay_ms.*"-1"' "${UDEV_RULE}" \
        && ok "Rule sets autosuspend_delay_ms=-1" \
        || fail "autosuspend_delay_ms=-1 not found in udev rule"
else
    fail "${UDEV_RULE} missing — run fix script to install"
fi

# ── 4. modprobe.d (permanent, baked into initramfs) ──────────────────────────
echo ""
echo "── 4. modprobe.d (permanent fix)"
MODPROBE_FILE="/etc/modprobe.d/usb-genesyslogic-nolpm.conf"
if [[ -f "${MODPROBE_FILE}" ]]; then
    ok "${MODPROBE_FILE} exists"
    if grep -q "quirks=${VID}:${PID}:k" "${MODPROBE_FILE}"; then
        ok "Correct quirk encoding (letter 'k', not hex)"
    else
        fail "Wrong or missing quirk in ${MODPROBE_FILE} — hex encoding silently fails"
    fi
else
    fail "${MODPROBE_FILE} not found — run fix script to create"
fi

# ── 5. Kernel cmdline persistence ────────────────────────────────────────────
# The quirk MUST be in the kernel cmdline so it is applied on every boot
# regardless of whether usbcore is a built-in or loadable module.
echo ""
echo "── 5. Kernel cmdline persistence"

KERNEL_CMDLINE_FILE="/etc/kernel/cmdline"
if [[ -f "${KERNEL_CMDLINE_FILE}" ]]; then
    if grep -q "usbcore\.quirks=${VID}:${PID}:k" "${KERNEL_CMDLINE_FILE}"; then
        ok "${KERNEL_CMDLINE_FILE} contains usbcore.quirks=${VID}:${PID}:k"
        info "$(cat "${KERNEL_CMDLINE_FILE}")"
    else
        fail "usbcore.quirks=${VID}:${PID}:k NOT found in ${KERNEL_CMDLINE_FILE} — run fix script"
        info "Current content: $(cat "${KERNEL_CMDLINE_FILE}")"
    fi
else
    fail "${KERNEL_CMDLINE_FILE} does not exist — run fix script to create it"
fi

LIMINE_DEFAULT="/etc/default/limine"
if [[ ! -f "${LIMINE_DEFAULT}" ]]; then
    warn "${LIMINE_DEFAULT} not found — skip (non-Limine system or not yet configured)"
elif grep -q "usbcore\.quirks=${VID}:${PID}:k" "${LIMINE_DEFAULT}"; then
    ok "KERNEL_CMDLINE in ${LIMINE_DEFAULT} contains the quirk"
    grep "usbcore.quirks" "${LIMINE_DEFAULT}" | sed 's/^/         /'
else
    # /etc/kernel/cmdline (checked above) is the primary persistence mechanism.
    # /etc/default/limine is belt-and-suspenders; missing it is not fatal.
    warn "usbcore.quirks not in ${LIMINE_DEFAULT} (non-critical — /etc/kernel/cmdline is the primary source)"
fi

# ── 6. Systemd service ───────────────────────────────────────────────────────
echo ""
echo "── 6. Systemd service (boot-time fallback)"
SERVICE="usb-genesyslogic-lpm-fix.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE}"
if [[ -f "${SERVICE_FILE}" ]]; then
    ok "${SERVICE_FILE} exists"
    ENABLED=$(systemctl is-enabled "${SERVICE}" 2>/dev/null || echo "unknown")
    if [[ "${ENABLED}" == "enabled" ]]; then
        ok "Service is enabled (runs on every boot)"
    else
        fail "Service exists but is NOT enabled (status: ${ENABLED}) — run: systemctl enable ${SERVICE}"
    fi
    ACTIVE=$(systemctl is-active "${SERVICE}" 2>/dev/null || echo "inactive")
    [[ "${ACTIVE}" == "active" ]] \
        && ok "Service is currently active" \
        || warn "Service current state: ${ACTIVE} (normal if just installed)"
else
    fail "${SERVICE_FILE} missing — run fix script to create and enable it"
fi

# ── 7. Recent dmesg stability ────────────────────────────────────────────────
echo ""
echo "── 7. Recent kernel errors (last 2 minutes)"
if command -v journalctl &>/dev/null; then
    ERR_LINES=$(journalctl -k --since "2 minutes ago" 2>/dev/null \
        | grep -E "05e3|usb.*suspend.*error|hub.*config.*fail|WARN.*TR Deq" || true)
else
    ERR_LINES=$(dmesg 2>/dev/null \
        | grep -E "05e3|usb.*suspend.*error|hub.*config.*fail|WARN.*TR Deq" || true)
fi

if [[ -z "${ERR_LINES}" ]]; then
    ERR_COUNT=0
else
    ERR_COUNT=$(echo "${ERR_LINES}" | wc -l)
fi

if [[ "${ERR_COUNT}" -eq 0 ]]; then
    ok "No hub-related errors in the last 2 minutes"
else
    fail "${ERR_COUNT} hub-related error(s) detected:"
    echo "${ERR_LINES}" | tail -10 | sed 's/^/         /'
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════"
printf "  PASS: %-3d  FAIL: %-3d  WARN: %d\n" "${PASS}" "${FAIL}" "${WARN}"
echo "══════════════════════════════════════"
if [[ "${FAIL}" -eq 0 && "${WARN}" -eq 0 ]]; then
    echo "  All checks passed. Hub is stable."
elif [[ "${FAIL}" -eq 0 ]]; then
    echo "  No failures — warnings above are informational."
else
    echo "  Fix is incomplete. Address [FAIL] items above."
    exit 1
fi
