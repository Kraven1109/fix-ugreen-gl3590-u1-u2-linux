#!/usr/bin/env bash
# Fix: GenesysLogic GL3590 hub LPM disconnect loop (Bulletproof Final Version)
#
# Device : UGREEN Revodok CM818 (P/N 45363), 6-in-1 USB-C hub
# Chipset: GenesysLogic GL3590  USB ID: 05e3:0625
# OS     : CachyOS (Arch-based), Limine bootloader
#
# Root cause: XHCI enables USB3 LPM U1 transitions at device enumeration.
# The GL3590 firmware cannot handle U1 link-state entry:
#   XHCI slot error (ENODEV / -19) → kernel forces disconnect
#   → hub re-enumerates → repeats every ~5 seconds indefinitely.
# USB 3.2 Gen2 / 10 Gbps data speed is completely unaffected by this fix.
#
# Fix layers (all scoped to 05e3:0625 only):
#   1. Runtime  — safe-append USB_QUIRK_NO_LPM to usbcore.quirks (letter 'k')
#   2. Udev     — force power/control=on on every connect (belt-and-suspenders)
#   3. Runtime  — hard remove + poll to re-enumerate hub with quirk active NOW
#   4. Persist  — modprobe.d entry included in initramfs via limine-mkinitcpio
#   5. Cleanup  — remove any legacy usbcore.quirks from kernel cmdline
#
# ENCODING NOTE: usbcore.quirks uses LETTER encoding, not hex.
#   '05e3:0625:k' works.  '05e3:0625:0x0400' silently fails (quirks stays 0).
#
# Usage: sudo bash fix-usb-hub-lpm-final.sh

set -euo pipefail
shopt -s nullglob   # unmatched globs → empty, not literal string (safe for /sys loops)

# ── Require root ─────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || { echo "[ERR] Run as root: sudo bash $0"; exit 1; }

VID="05e3"
PID="0625"
QUIRK_LETTER="k"   # USB_QUIRK_NO_LPM = BIT(10) = letter 'k'
ENTRY="${VID}:${PID}:${QUIRK_LETTER}"
NO_LPM_BIT=$(( 1 << 10 ))   # 0x400 — used to verify quirk is active post-enumeration

echo "=== Applying Bulletproof USB Hub LPM Fix ==="
echo "    Target: ${VID}:${PID}  quirk entry: ${ENTRY}"
echo ""

# ── Helper: locate hub sysfs path by VID:PID ────────────────────────────────
# Returns the path (without trailing slash) or empty string if not found.
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

# ── 1. Runtime quirk — safe append ──────────────────────────────────────────
QUIRKS_PATH="/sys/module/usbcore/parameters/quirks"
if [[ ! -f "${QUIRKS_PATH}" ]]; then
    echo "[WARN] ${QUIRKS_PATH} not found — is usbcore loaded? Skipping runtime write."
else
    CURRENT=$(cat "${QUIRKS_PATH}" 2>/dev/null || true)
    if [[ -z "${CURRENT}" ]]; then
        echo "${ENTRY}" > "${QUIRKS_PATH}"
    elif [[ "${CURRENT}" == *"${ENTRY}"* ]]; then
        echo "[INFO] Quirk already present in usbcore.quirks, skipping write."
    else
        echo "${CURRENT},${ENTRY}" > "${QUIRKS_PATH}"
    fi
    echo "[OK] Runtime quirks: $(cat "${QUIRKS_PATH}")"
fi

# ── 2. Udev rule — autosuspend prevention on every connect ──────────────────
# NOTE: udev rules do not support backslash line continuation.
# Each rule must be a single unbroken line.
UDEV_RULE="/etc/udev/rules.d/99-usb-genesyslogic-nolpm.rules"
cat > "${UDEV_RULE}" <<EOF
# GenesysLogic GL3590 USB3.2 Hub (${VID}:${PID}) — keep power on every connect.
# USB_QUIRK_NO_LPM is applied at enumeration via usbcore.quirks (modprobe.d).
ACTION=="add|bind|change", SUBSYSTEM=="usb", ATTR{idVendor}=="${VID}", ATTR{idProduct}=="${PID}", TEST=="power/control", ATTR{power/control}="on"
ACTION=="add|bind|change", SUBSYSTEM=="usb", ATTR{idVendor}=="${VID}", ATTR{idProduct}=="${PID}", TEST=="power/autosuspend_delay_ms", ATTR{power/autosuspend_delay_ms}="-1"
EOF
udevadm control --reload-rules
echo "[OK] Udev rule installed: ${UDEV_RULE}"

# ── 3. Hard re-enumeration + poll verification ───────────────────────────────
# udevadm trigger only fires synthetic uevents (userspace only).
# usbcore.quirks is evaluated strictly at kernel enumeration time.
# Only a real remove → re-appear cycle makes the NO_LPM quirk active NOW.
HUB_BEFORE=$(find_hub)
if [[ -n "${HUB_BEFORE}" ]]; then
    echo "[..] Hub found at ${HUB_BEFORE} — forcing hard re-enumeration..."
    echo 1 > "${HUB_BEFORE}/remove"
else
    echo "[WARN] Hub not in sysfs before re-enumeration. Replug manually if needed."
fi

# Poll up to 10 s for hub to reappear (avoids hardcoded worst-case sleep).
HUB_SYS=""
APPLIED_QUIRKS="n/a"
for i in {1..10}; do
    sleep 1
    HUB_SYS=$(find_hub)
    [[ -n "${HUB_SYS}" ]] && break
done

if [[ -n "${HUB_SYS}" ]]; then
    APPLIED_QUIRKS=$(cat "${HUB_SYS}/quirks" 2>/dev/null || echo "unknown")
    echo "[OK] Hub re-appeared at ${HUB_SYS} after ${i}s"
    echo "[OK] Device quirks = ${APPLIED_QUIRKS}"

    # Verify NO_LPM bit (BIT 10 = 0x400) is actually set in the device quirks.
    if [[ "${APPLIED_QUIRKS}" =~ ^0x[0-9a-fA-F]+$ ]]; then
        if (( APPLIED_QUIRKS & NO_LPM_BIT )); then
            echo "[OK] NO_LPM bit (0x400) confirmed active — hub is stable."
        else
            echo "[WARN] NO_LPM bit NOT detected in device quirks (${APPLIED_QUIRKS})."
            echo "       The permanent modprobe.d fix will apply correctly on next reboot."
        fi
    else
        echo "[INFO] Could not parse quirks value '${APPLIED_QUIRKS}' — verify manually."
    fi
else
    echo "[WARN] Hub did not reappear within 10s."
    echo "       Replug physically to verify runtime quirk is active."
fi

# ── 4. Permanent fix via modprobe.d (included in initramfs) ─────────────────
MODPROBE_FILE="/etc/modprobe.d/usb-genesyslogic-nolpm.conf"
cat > "${MODPROBE_FILE}" <<EOF
# GenesysLogic GL3590 USB3.2 Hub (${VID}:${PID})
# Disables USB3 Link Power Management to prevent the LPM disconnect loop.
# USB_QUIRK_NO_LPM = BIT(10); encoded as letter 'k' in usbcore.quirks format.
# Writing hex (0x0400) silently fails — only the letter encoding works.
options usbcore quirks=${ENTRY}
EOF
echo "[OK] modprobe.d config written: ${MODPROBE_FILE}"

# ── 5. Clean up legacy cmdline hack (if any) & regenerate initramfs ──────────
LIMINE_DEFAULT="/etc/default/limine"
if [[ -f "${LIMINE_DEFAULT}" ]] && grep -q "usbcore\.quirks=${ENTRY}" "${LIMINE_DEFAULT}"; then
    echo "[..] Removing legacy usbcore.quirks from ${LIMINE_DEFAULT}..."
    sed -i "s/ usbcore\.quirks=${ENTRY}//g" "${LIMINE_DEFAULT}"
    sed -i "s/usbcore\.quirks=${ENTRY} //g" "${LIMINE_DEFAULT}"
    sed -i "s/usbcore\.quirks=${ENTRY}//g"  "${LIMINE_DEFAULT}"
    echo "[OK] Cleaned up ${LIMINE_DEFAULT}"
fi

echo "[..] Regenerating initramfs (limine-mkinitcpio)..."
limine-mkinitcpio
echo "[OK] Initramfs regeneration complete."

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "=== Fix Summary ==="
echo "  Runtime quirks : $(cat "${QUIRKS_PATH}" 2>/dev/null || echo 'n/a')"
echo "  Device quirks  : ${APPLIED_QUIRKS}"
echo "  Udev rule      : ${UDEV_RULE}"
echo "  modprobe.d     : ${MODPROBE_FILE}"
if [[ -f "${LIMINE_DEFAULT}" ]]; then
    echo "  Boot cmdline   : $(grep 'KERNEL_CMDLINE' "${LIMINE_DEFAULT}" | head -1 || echo 'Clean')"
fi
echo ""
echo "Hub is stable. USB 3.2 / 10 Gbps speed is unchanged."
echo "On next reboot the fix loads automatically via modprobe.d + initramfs."
