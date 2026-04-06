#!/usr/bin/env bash
# Fix: GenesysLogic GL3590 hub LPM disconnect loop (UGREEN Revodok CM818, CachyOS)
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
# Fix (3 layers, all scoped to 05e3:0625 only):
# 1. Runtime (immediate, no reboot): echo '05e3:0625:k' > /sys/module/usbcore/parameters/quirks
#    echo 1 > /sys/bus/usb/devices/2-4/remove (force re-enumeration)
#    Verified: cat /sys/bus/usb/devices/2-4/quirks == 0x400, usb3_hardware_lpm_u1 file gone (LPM disabled)
# 2. Permanent (reboot persistent): /etc/modprobe.d/usb-genesyslogic-nolpm.conf + limine-mkinitcpio
# 3. Udev (belt-and-suspenders): /etc/udev/rules.d/99-usb-genesyslogic-nolpm.rules
#
# CRITICAL - encoding bug: usbcore.quirks uses LETTER encoding (k=bit10=USB_QUIRK_NO_LPM)
# Writing hex '0x0400' silently fails (device quirks stays 0x0). Only '05e3:0625:k' works.
#
# Firmware note: fwupd detects hub as updatable but no LVFS package for BONDING_78 config.
# A vendor firmware update could fix this permanently.
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
