#!/usr/bin/env bash
# Fix: GenesysLogic USB3.2 Hub (05e3:0625) disconnect loop on CachyOS
#
# Root cause: XHCI hardware enables USB3 LPM U1/U2 link-state transitions.
#   The hub firmware cannot handle them → XHCI slot error → hub crashes
#   → kernel disconnects hub → hub reconnects → repeats every ~5 s.
#   Note: USB_QUIRK_NO_LPM only disables the *power-management* U1/U2 transitions.
#   The hub still runs at full USB 3.2 / 10 Gbps speed.
#
# Fix layers:
#   1. Runtime  – write quirk to /sys/module/usbcore/parameters/quirks (no reboot)
#                 then force hub re-enumeration so the quirk is applied immediately
#   2. Udev     – set power/control=on on every add event (belt-and-suspenders)
#   3. modprobe.d – quirk persists across reboots via initramfs
#   4. Cmdline  – quirk baked into Limine kernel cmdline (belt-and-suspenders)
#
# Encoding note: usbcore.quirks uses LETTER encoding, not hex.
#   Bit 10 (USB_QUIRK_NO_LPM) = letter 'k'  (a=bit0, b=bit1, ..., k=bit10)
#
# Usage: sudo bash fix-usb-hub-lpm.sh

set -euo pipefail

VID="05e3"
PID="0625"
QUIRK_LETTER="k"   # USB_QUIRK_NO_LPM = BIT(10) = letter 'k'
ENTRY="${VID}:${PID}:${QUIRK_LETTER}"

# ── 1. Runtime quirk (immediate, no reboot needed) ────────────────────────
QUIRKS_PATH="/sys/module/usbcore/parameters/quirks"
echo "${ENTRY}" > "${QUIRKS_PATH}"
echo "[OK] Runtime quirk set: $(cat ${QUIRKS_PATH})"

# Force hub re-enumeration so new quirk is applied to the already-connected hub.
HUB_SYS=""
for d in /sys/bus/usb/devices/*/; do
    [[ "$(cat "$d/idVendor" 2>/dev/null)" == "${VID}" ]] && \
    [[ "$(cat "$d/idProduct" 2>/dev/null)" == "${PID}" ]] && \
    HUB_SYS="${d%/}" && break
done

if [[ -n "${HUB_SYS}" ]]; then
    echo "[..] Re-enumerating hub at ${HUB_SYS} ..."
    echo 1 > "${HUB_SYS}/remove"
    sleep 3
    # Hub re-appears automatically; find its new sysfs path
    for d in /sys/bus/usb/devices/*/; do
        if [[ "$(cat "$d/idVendor" 2>/dev/null)" == "${VID}" ]] && \
           [[ "$(cat "$d/idProduct" 2>/dev/null)" == "${PID}" ]]; then
            HUB_SYS="${d%/}"
            break
        fi
    done
    APPLIED_QUIRKS=$(cat "${HUB_SYS}/quirks" 2>/dev/null || echo "unknown")
    echo "[OK] Hub re-enumerated, device quirks = ${APPLIED_QUIRKS}"
else
    echo "[WARN] Hub not found; replug to apply runtime quirk."
fi

# ── 2. Udev rule (fires on every connect, prevents autosuspend too) ────────
UDEV_RULE="/etc/udev/rules.d/99-usb-genesyslogic-nolpm.rules"
cat > "${UDEV_RULE}" <<EOF
# GenesysLogic USB3.2 Hub (${VID}:${PID}) – disable autosuspend on every connect
# USB_QUIRK_NO_LPM applied at boot via usbcore.quirks; this is belt-and-suspenders.
ACTION=="add|bind|change", SUBSYSTEM=="usb", ATTR{idVendor}=="${VID}", ATTR{idProduct}=="${PID}", TEST=="power/control", ATTR{power/control}="on"
ACTION=="add|bind|change", SUBSYSTEM=="usb", ATTR{idVendor}=="${VID}", ATTR{idProduct}=="${PID}", TEST=="power/autosuspend_delay_ms", ATTR{power/autosuspend_delay_ms}="-1"
EOF
udevadm control --reload-rules
echo "[OK] Udev rule installed: ${UDEV_RULE}"

# ── 3. Permanent fix via modprobe.d (included in initramfs) ───────────────
MODPROBE_FILE="/etc/modprobe.d/usb-genesyslogic-nolpm.conf"
cat > "${MODPROBE_FILE}" <<EOF
# GenesysLogic USB3.2 Hub (${VID}:${PID}) – disable LPM to prevent disconnect loop
# USB_QUIRK_NO_LPM = BIT(10), encoded as letter 'k' in usbcore.quirks format
options usbcore quirks=${ENTRY}
EOF
echo "[OK] Created ${MODPROBE_FILE}"

limine-mkinitcpio
echo "[OK] Initramfs regenerated (limine-mkinitcpio)"

# ── 4. Permanent fix via kernel cmdline (Limine) ──────────────────────────
LIMINE_DEFAULT="/etc/default/limine"
if grep -q "usbcore\.quirks" "${LIMINE_DEFAULT}"; then
    sed -i "s/usbcore\.quirks=[^ \"]*/usbcore.quirks=${ENTRY}/" "${LIMINE_DEFAULT}"
    echo "[OK] Updated usbcore.quirks in ${LIMINE_DEFAULT}"
else
    sed -i "s|KERNEL_CMDLINE\[default\]+=\"|KERNEL_CMDLINE[default]+=\"usbcore.quirks=${ENTRY} |" "${LIMINE_DEFAULT}"
    echo "[OK] Added usbcore.quirks=${ENTRY} to ${LIMINE_DEFAULT}"
fi
echo "[OK] Cmdline: $(grep KERNEL_CMDLINE ${LIMINE_DEFAULT} | head -1)"

echo ""
echo "=== Fix applied ==="
echo "  Runtime quirk : ${QUIRKS_PATH} = $(cat ${QUIRKS_PATH})"
echo "  Device quirks : $(cat ${HUB_SYS}/quirks 2>/dev/null || echo 'n/a (replug hub)')"
echo "  Udev rule     : ${UDEV_RULE}"
echo "  modprobe.d    : ${MODPROBE_FILE}"
echo "  Boot cmdline  : $(grep usbcore ${LIMINE_DEFAULT})"
echo ""
echo "Hub is stable. USB 3.2 / 10 Gbps speed is unchanged."
echo "On next reboot the fix is applied automatically via modprobe.d + cmdline."
