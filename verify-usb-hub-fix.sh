#!/usr/bin/env bash
# Verify: GenesysLogic GL3590 hub LPM fix (UGREEN Revodok CM818, CachyOS)
#
# Device: UGREEN Revodok CM818 (P/N 45363), 6-in-1 USB-C hub
# Product: https://www.amazon.com/dp/B0D1XLNWP2
# Chipset: GenesysLogic GL3590 USB ID: 05e3:0625
# Companion USB2 hub: 05e3:0610 IC_359020, firmware 64.0 (bcdDevice=64.00)
# fwupd: device detected, no LVFS firmware available for this config
# OS: CachyOS (Arch-based), Limine bootloader, BTRFS subvol=/@
#
# Symptom: KDED repeatedly shows 'GenesysLogic USB3.2 Hub connected/disconnected'
# every ~5 seconds. Devices still usable but loop causes plasma/kded spam.
# dmesg: usb 2-4: Failed to suspend device, error -19
#        xhci_hcd: WARN Set TR Deq Ptr cmd failed (slot/ep state error)
#        hub 2-4:1.0: config failed, cant get hub status (err -5)
#
# Root cause: XHCI hardware enables USB3 LPM U1 state transitions automatically at
# device enumeration. The GL3590 firmware cannot handle U1 link-state entry ->
# XHCI slot error (ENODEV/-19) -> kernel forces USB disconnect -> hub re-enumerates -> repeats.
# USB 3.2 Gen2 / 10 Gbps data speed is completely unaffected by fix.
#
# Fix verification (3 layers, all scoped to 05e3:0625 only):
# 1. Runtime: /sys/module/usbcore/parameters/quirks contains '05e3:0625:k'
# 2. Device: /sys/bus/usb/devices/*/quirks == 0x400 (USB_QUIRK_NO_LPM)
#    usb3_hardware_lpm_u1 file absent (LPM disabled)
#    power/control == 'on' (no auto-suspend)
# 3. Permanent: /etc/modprobe.d/usb-genesyslogic-nolpm.conf exists
#    /etc/default/limine contains usbcore.quirks=05e3:0625:k
#    /etc/udev/rules.d/99-usb-genesyslogic-nolpm.rules exists
# 4. Stability: No recent dmesg errors, hub runtime_status=active
#
# CRITICAL - encoding bug: usbcore.quirks uses LETTER encoding (k=bit10=USB_QUIRK_NO_LPM)
# Writing hex '0x0400' silently fails (device quirks stays 0x0). Only '05e3:0625:k' works.
#
# Firmware note: fwupd detects hub as updatable but no LVFS package for BONDING_78 config.
# A vendor firmware update could fix this permanently.
#
# Usage: sudo bash verify-usb-hub-fix.sh

set -euo pipefail

VID="05e3"
PID="0625"
PASS=0; FAIL=0

ok()   { echo "  [PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $*"; }

echo "=== 1. Runtime quirk ==="
QUIRKS=$(cat /sys/module/usbcore/parameters/quirks 2>/dev/null)
echo "  /sys/module/usbcore/parameters/quirks = '${QUIRKS}'"
if echo "${QUIRKS}" | grep -q "${VID}:${PID}:k"; then
    ok "NO_LPM quirk (letter 'k') is present in runtime quirks table"
else
    fail "Expected '${VID}:${PID}:k' — run fix script as root to apply"
fi

echo ""
echo "=== 2. Device quirks (requires hub connected) ==="
HUB_SYS=""
for d in /sys/bus/usb/devices/*/; do
    [[ "$(cat "$d/idVendor" 2>/dev/null)" == "${VID}" ]] && \
    [[ "$(cat "$d/idProduct" 2>/dev/null)" == "${PID}" ]] && \
    HUB_SYS="${d%/}" && break
done

if [[ -n "${HUB_SYS}" ]]; then
    DEV_QUIRKS=$(cat "${HUB_SYS}/quirks" 2>/dev/null || echo "?")
    SPEED=$(cat "${HUB_SYS}/speed" 2>/dev/null || echo "?")
    VERSION=$(cat "${HUB_SYS}/version" 2>/dev/null | tr -d ' ' || echo "?")
    CTRL=$(cat "${HUB_SYS}/power/control" 2>/dev/null || echo "?")
    RUNTIME=$(cat "${HUB_SYS}/power/runtime_status" 2>/dev/null || echo "?")
    LPM_U1=$(cat "${HUB_SYS}/power/usb3_hardware_lpm_u1" 2>/dev/null || echo "disabled (file absent = LPM off)")
    echo "  Hub sysfs  : ${HUB_SYS}"
    echo "  USB version: ${VERSION}  Speed: ${SPEED} Mbps"
    echo "  Device quirks  : ${DEV_QUIRKS}  (expected: 0x400)"
    echo "  power/control  : ${CTRL}        (expected: on)"
    echo "  runtime_status : ${RUNTIME}     (expected: active)"
    echo "  usb3_lpm_u1    : ${LPM_U1}"
    [[ "${DEV_QUIRKS}" == "0x400" ]] && ok "USB_QUIRK_NO_LPM (0x400) applied to device" || fail "Device quirks not 0x400 — hub needs replug after quirk was written"
    [[ "${CTRL}" == "on" ]]          && ok "power/control=on (autosuspend disabled)"     || fail "power/control is not 'on'"
    [[ "${RUNTIME}" == "active" ]]   && ok "Hub runtime status is active (not suspended)" || warn "Hub is not active: ${RUNTIME}"
    lsusb | grep -q "${VID}:${PID}" && ok "Hub visible in lsusb: $(lsusb | grep ${VID}:${PID})" || fail "Hub not in lsusb"
else
    warn "Hub not found in sysfs — replug it and rerun"
fi

echo ""
echo "=== 3. Udev rule ==="
UDEV_RULE="/etc/udev/rules.d/99-usb-genesyslogic-nolpm.rules"
if [[ -f "${UDEV_RULE}" ]]; then
    ok "${UDEV_RULE} exists"
    cat "${UDEV_RULE}" | sed 's/^/    /'
else
    fail "${UDEV_RULE} missing"
fi

echo ""
echo "=== 4. modprobe.d ==="
MODPROBE_FILE="/etc/modprobe.d/usb-genesyslogic-nolpm.conf"
if [[ -f "${MODPROBE_FILE}" ]]; then
    ok "${MODPROBE_FILE} exists"
    cat "${MODPROBE_FILE}" | sed 's/^/    /'
    grep -q "quirks=${VID}:${PID}:k" "${MODPROBE_FILE}" && ok "Correct quirk format (letter 'k')" || fail "Wrong format in modprobe.d"
else
    fail "${MODPROBE_FILE} not found"
fi

echo ""
echo "=== 5. Boot cmdline (Limine) ==="
if grep -q "usbcore.quirks=${VID}:${PID}:k" /etc/default/limine; then
    ok "Correct usbcore.quirks in /etc/default/limine"
    grep "usbcore.quirks" /etc/default/limine | sed 's/^/    /'
else
    fail "usbcore.quirks missing or wrong format in /etc/default/limine"
fi

echo ""
echo "=== 6. Recent kernel errors ==="
RECENT_ERRS=$(sudo dmesg 2>/dev/null | awk -v now="$(awk '{print $1}' /proc/uptime | cut -d. -f1)" \
    'BEGIN{thresh=now-120} /\[/ {t=$1+0; if(t>thresh && (/05e3|suspend.*error|hub.*config.*fail/)) print}' | wc -l)
if [[ "${RECENT_ERRS}" -eq 0 ]]; then
    ok "No hub errors in the last 2 minutes"
else
    fail "${RECENT_ERRS} hub-related error(s) in the last 2 minutes:"
    sudo dmesg 2>/dev/null | grep -E "05e3|suspend.*error|hub.*config.*fail" | tail -5 | sed 's/^/    /'
fi

echo ""
echo "=============================="
echo "  PASS: ${PASS}  FAIL: ${FAIL}"
echo "=============================="
[[ "${FAIL}" -eq 0 ]] && echo "All checks passed. Hub is stable." || echo "Some checks failed — see above."
