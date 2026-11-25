#!/bin/bash

# Helper: remove the VDDE blocks from a disassembled ACPI table.
#
# The Intel graphics SSDT of the Fujitsu U9311 powers the eDP panel down
# (VDDE = Zero) while the display is still in use, which leaves the internal
# panel black after a resume. The upstream patch removes these blocks; this
# helper is used as a fallback when the textual patch does not apply cleanly
# (e.g. after a firmware update changed the surrounding context).
#
# $1: path of the disassembled table (*.dsl)
function acpi-remove-vdde-blocks() {
    local dsl="$1"

    # Remove every "If ((VDDE == One)) { VDDE = Zero; ... }" statement.
    # GNU sed is used in NUL-separated mode (-z) so that the pattern can
    # span multiple lines.
    sed -i -z -E 's/[[:space:]]*If[[:space:]]*\(\(VDDE[[:space:]]*==[[:space:]]*One\)\)[[:space:]]*\{[^}]*VDDE[[:space:]]*=[[:space:]]*Zero[^}]*\}//g' "${dsl}"
}

# Helper: read the OEM revision of a disassembled ACPI table.
#
# $1: path of the disassembled table (*.dsl)
function acpi-read-oem-revision() {
    local dsl="$1"

    grep -m1 -E '^[[:space:]]*DefinitionBlock' "${dsl}" | grep -oE '0x[0-9A-Fa-f]{8}' | tail -1
}

# Helper: bump the OEM revision of a disassembled ACPI table.
#
# The kernel only replaces a firmware table with an initrd override table
# when the override carries a more recent OEM revision. The new revision is
# printed on stdout.
#
# $1: path of the disassembled table (*.dsl)
function acpi-bump-oem-revision() {
    local dsl="$1"
    local rev new_rev

    rev=$(acpi-read-oem-revision "${dsl}")
    if [ -z "${rev}" ]; then
        return 1
    fi

    new_rev=$(printf '0x%08X' $(( rev + 1 )))
    sed -i -E "/^[[:space:]]*DefinitionBlock/ s/${rev}/${new_rev}/" "${dsl}"

    echo "${new_rev}"
}

# Helper: print the OEM revision (offset 24 of the ACPI header) of a table.
#
# $1: path of the binary table (*.aml)
function acpi-get-oem-revision() {
    printf '0x%s\n' "$(od -An -tx4 -j24 -N4 "$1" | tr -d ' \n')"
}

# shell function to patch the ACPI tables on a Fujitsu U9311 laptop to fix the VDD issue.
# This function targets Arch Linux (and derivatives) that build the initramfs
# with mkinitcpio.
function patch-arch() {
    echo "[patch-arch] For Arch Linux."

    # Repository root: this file lives in <repo>/lib/.
    local REPO_ROOT
    REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

    # Working directory for the patching process.
    local SRC="${REPO_ROOT}/acpi_temp"

    # Directory watched by the mkinitcpio 'acpi_override' hook.
    local OVERRIDE_DIR=/etc/initcpio/acpi_override

    # mkinitcpio configuration file.
    local MKINITCPIO_CONF=/etc/mkinitcpio.conf

    # Initramfs image to regenerate (see /etc/mkinitcpio.d/*.preset).
    local INITRAMFS=/boot/initramfs-linux.img

    mkdir -p "${SRC}"
    cd "${SRC}" || return 1

    # Install the required packages: acpica provides iasl, patch applies the diff.
    echo "[patch-arch] Checking the required packages (acpica, patch)..."
    if ! command -v iasl >/dev/null 2>&1 || ! command -v patch >/dev/null 2>&1; then
        echo "[patch-arch] Installing required packages for patching..."
        sudo pacman -S --needed --noconfirm acpica patch ||
            sudo pacman -Sy --needed --noconfirm acpica patch ||
            {
                echo "[patch-arch] Failed to install the required packages. Exiting."
                return 1
            }
    fi

    # Extract the ACPI table from the firmware.
    echo "[patch-arch] Extracting SSDT4 from the firmware..."
    sudo cat /sys/firmware/acpi/tables/SSDT4 > SSDT4.aml
    if [ ! -s SSDT4.aml ]; then
        echo "[patch-arch] Failed to read /sys/firmware/acpi/tables/SSDT4. Exiting."
        return 1
    fi
    # Keep a pristine copy for comparison.
    cp SSDT4.aml SSDT4.aml.orig

    # Create a patch file to modify the ACPI table.
    echo "[patch-arch] Creating patch file fujitsu-vdd.patch..."
    cat <<-EOF | tee fujitsu-vdd.patch
	--- SSDT4.dsl.orig    2024-07-29 18:33:14.782373152 +0200
	+++ SSDT4.dsl 2024-07-29 18:38:33.021477685 +0200
	@@ -18,7 +18,7 @@
	  *     Compiler ID      "INTL"
	  *     Compiler Version 0x20160422 (538313762)
	  */
	-DefinitionBlock ("", "SSDT", 2, "INTEL ", "IgfxSsdt", 0x00003000)
	+DefinitionBlock ("", "SSDT", 2, "INTEL ", "IgfxSsdt", 0x00003001)  
	 {
	     External (_SB_.PC00, DeviceObj)
	     External (_SB_.PC00.GFX0, DeviceObj)
	@@ -115,11 +115,6 @@
	         {
	             If ((PDRD () == Zero))
	             {
	-                If ((VDDE == One))
	-                {
	-                    VDDE = Zero
	-                    Sleep (0x01F4)
	-                }
	             }
	 
	             NDID = 0x02
	@@ -2479,11 +2474,6 @@
	             {
	                 If ((PDRD () == Zero))
	                 {
	-                    If ((VDDE == One))
	-                    {
	-                        VDDE = Zero
	-                        Sleep (0x01F4)
	-                    }
	                 }
	             }
	EOF

    # Disassemble the ACPI table to a human-readable format.
    echo "[patch-arch] Disassembling the ACPI table..."
    iasl -d SSDT4.aml > iasl-disassemble.log 2>&1
    if [ $? -ne 0 ] || [ ! -f SSDT4.dsl ]; then
        echo "[patch-arch] Failed to disassemble the ACPI table. Exiting."
        cat iasl-disassemble.log
        return 1
    fi
    # Keep a pristine copy of the disassembled table.
    cp SSDT4.dsl SSDT4.dsl.pristine

    # Sanity check: this workaround only applies to the Intel graphics SSDT.
    if ! grep -q 'IgfxSsdt' SSDT4.dsl; then
        echo "[patch-arch] SSDT4 is not the Intel graphics table (IgfxSsdt). Exiting."
        return 1
    fi

    # Sanity check: there must be something to patch. If the firmware no longer
    # powers the panel down through VDDE, this workaround is unnecessary and
    # installing an override would be pointless.
    local vdde_before
    vdde_before=$(grep -c 'VDDE[[:space:]]*=[[:space:]]*Zero' SSDT4.dsl || true)
    if [ "${vdde_before}" -eq 0 ]; then
        echo "[patch-arch] No 'VDDE = Zero' block found in SSDT4."
        echo "[patch-arch] The firmware may already be fixed; nothing to do. Exiting."
        return 1
    fi
    echo "[patch-arch] Found ${vdde_before} 'VDDE = Zero' block(s) to remove."

    # Apply the patch to the disassembled ACPI table.
    echo "[patch-arch] Applying the patch to the disassembled ACPI table..."
    if ! patch -p0 --batch --no-backup-if-mismatch -i fujitsu-vdd.patch; then
        echo "[patch-arch] The patch did not apply cleanly, falling back to a direct edit of the source..."
        # Discard a partially patched file and start from the pristine source.
        cp SSDT4.dsl.pristine SSDT4.dsl
        rm -f SSDT4.dsl.rej SSDT4.dsl.orig

        acpi-remove-vdde-blocks SSDT4.dsl
        acpi-bump-oem-revision SSDT4.dsl > /dev/null
    fi

    # Verify that the source really was modified.
    echo "[patch-arch] Verifying the patched source..."
    if grep -q 'VDDE[[:space:]]*=[[:space:]]*Zero' SSDT4.dsl; then
        echo "[patch-arch] The 'VDDE = Zero' blocks are still present. Exiting."
        return 1
    fi
    if cmp -s SSDT4.dsl SSDT4.dsl.pristine; then
        echo "[patch-arch] The patched source is identical to the original. Exiting."
        return 1
    fi

    local orig_rev new_rev
    orig_rev=$(acpi-get-oem-revision SSDT4.aml.orig)
    new_rev=$(acpi-read-oem-revision SSDT4.dsl)
    if [ -z "${new_rev}" ] || [ $(( new_rev )) -le $(( orig_rev )) ]; then
        echo "[patch-arch] Failed to raise the OEM revision of the table. Exiting."
        return 1
    fi
    echo "[patch-arch] OEM revision raised from ${orig_rev} to ${new_rev}."

    # Reassemble the patched ACPI table back to binary format.
    echo "[patch-arch] Reassembling the patched ACPI table..."
    rm -f SSDT4.aml
    iasl -sa SSDT4.dsl > iasl-compile.log 2>&1
    if [ $? -ne 0 ] || [ ! -s SSDT4.aml ]; then
        echo "[patch-arch] Failed to reassemble the patched ACPI table. Exiting."
        grep -E 'Error|Failure' iasl-compile.log || cat iasl-compile.log
        return 1
    fi

    # The compiled table must carry the raised OEM revision, otherwise the
    # kernel ignores the override.
    local compiled_rev
    compiled_rev=$(acpi-get-oem-revision SSDT4.aml)
    if [ $(( compiled_rev )) -le $(( orig_rev )) ]; then
        echo "[patch-arch] The compiled table does not carry a newer OEM revision. Exiting."
        return 1
    fi

    # Back to the original directory.
    echo "[patch-arch] Back to the original directory..."
    cd - > /dev/null || return 1

    # Install the patched table where the mkinitcpio 'acpi_override' hook
    # picks it up.
    echo "[patch-arch] Installing the patched table into ${OVERRIDE_DIR}..."
    sudo mkdir -p "${OVERRIDE_DIR}"
    sudo cp "${SRC}/SSDT4.aml" "${OVERRIDE_DIR}/SSDT4.aml"
    sudo chmod 644 "${OVERRIDE_DIR}/SSDT4.aml"

    # Enable the acpi_override hook in the mkinitcpio configuration.
    echo "[patch-arch] Enabling the acpi_override hook in ${MKINITCPIO_CONF}..."
    if ! grep -E '^HOOKS=' "${MKINITCPIO_CONF}" | grep -q 'acpi_override'; then
        if ! grep -qE '^HOOKS=' "${MKINITCPIO_CONF}"; then
            echo "[patch-arch] No HOOKS entry found in ${MKINITCPIO_CONF}. Exiting."
            return 1
        fi
        sudo sed -i -E '/^HOOKS=/ s/\)/ acpi_override)/' "${MKINITCPIO_CONF}"
    fi

    # Regenerate the initramfs so that the patched table is embedded in it.
    echo "[patch-arch] Regenerating the initramfs..."
    sudo mkinitcpio -P
    if [ $? -ne 0 ]; then
        echo "[patch-arch] Failed to regenerate the initramfs. Exiting."
        return 1
    fi

    # Confirm that the table really ended up in the initramfs.
    if [ -f "${INITRAMFS}" ]; then
        if lsinitcpio "${INITRAMFS}" 2>/dev/null | grep -q 'kernel/firmware/acpi/SSDT4.aml'; then
            echo "[patch-arch] The patched table is embedded in ${INITRAMFS}."
        else
            echo "[patch-arch] Warning: the patched table was not found in ${INITRAMFS}."
        fi
    fi

    echo "[patch-arch] ACPI patch applied successfully. Please reboot your system for the changes to take effect."
    echo "[patch-arch] After the reboot, verify the patch with:"
    echo "[patch-arch]     journalctl -k | grep -i 'Table Upgrade'"
    return 0
}

# shell function to remove the ACPI patch on Arch Linux.
function remove-patch-arch() {
    local OVERRIDE_DIR=/etc/initcpio/acpi_override
    local MKINITCPIO_CONF=/etc/mkinitcpio.conf

    echo "[remove-patch-arch] Removing the ACPI patch..."

    sudo rm -f "${OVERRIDE_DIR}/SSDT4.aml"

    if grep -E '^HOOKS=' "${MKINITCPIO_CONF}" | grep -q 'acpi_override'; then
        sudo sed -i -E '/^HOOKS=/ s/ acpi_override//' "${MKINITCPIO_CONF}"
    fi

    echo "[remove-patch-arch] Regenerating the initramfs..."
    sudo mkinitcpio -P

    echo "[remove-patch-arch] The ACPI patch has been removed. Please reboot your system."
    return 0
}
