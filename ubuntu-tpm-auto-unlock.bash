#!/usr/bin/env bash
set -Eeuo pipefail

## Optional automation passphrase. Do not commit a real passphrase here.
DEFAULT_SETUP_LUKSPW='your_iac_luks_passphrase'

## Preferred automation input:
##   export ENV_SETUP_LUKSPW='current LUKS passphrase'
## The variable is unset by this script during cleanup.

###############################################################################
# Ubuntu LUKS2 + TPM2 automatic-unlock setup
#
# Supported design:
#   - Ubuntu 22.04, 24.04, or 26.04
#   - Encrypted root filesystem using LUKS2 (including LVM-on-LUKS)
#   - Ubuntu's installed initramfs generator is retained:
#       * initramfs-tools -> clevis-initramfs
#       * dracut          -> clevis-dracut
#   - Clevis provides the TPM2 binding and early-boot unlock integration
#
# Enrollment modes:
#   PCR 0+2 = temporary template/staging enrollment
#   PCR 7   = final deployed-system enrollment
#
# The existing recovery passphrase is retained. A LUKS header backup is made
# before any token or keyslot is changed.
###############################################################################

EXPECTED_LUKS_DEVICE="${EXPECTED_LUKS_DEVICE:-}"
STATE_DIR='/var/lib/luks-tpm-autounlock'
RESEAL_MARKER="$STATE_DIR/pending-pcr7-reseal"

UNLOCK_LUKSPW="${ENV_SETUP_LUKSPW:-$DEFAULT_SETUP_LUKSPW}"
LUKS_DEVICE=''
LUKS_UUID=''
CRYPT_NAME=''
PCR_SELECTION=''
PCR_CLEVIS=''
DEPLOYMENT_MODE=''
INITRAMFS_BACKEND=''
KEYFILE=''
HEADER_BACKUP=''

die() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf '\nWARNING: %s\n' "$*" >&2
}

info() {
    printf '\n== %s ==\n' "$*"
}

yes_answer() {
    [[ "${1:-}" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

secure_remove() {
    local file="${1:-}"

    [[ -n "$file" && -e "$file" ]] || return 0

    if command -v shred >/dev/null 2>&1; then
        shred -u "$file" 2>/dev/null || rm -f "$file"
    else
        rm -f "$file"
    fi
}

cleanup() {
    secure_remove "${KEYFILE:-}"
    unset UNLOCK_LUKSPW ENV_SETUP_LUKSPW
}

trap cleanup EXIT

[[ "$EUID" -eq 0 ]] || die "Run this script with sudo or as root."

###############################################################################
# Verify Ubuntu and the existing initramfs implementation
###############################################################################

[[ -r /etc/os-release ]] || die "Cannot determine the operating system."

# shellcheck disable=SC1091
source /etc/os-release

[[ "${ID:-}" == 'ubuntu' ]] || die "This script supports Ubuntu only."

case "${VERSION_ID:-}" in
    22.04|24.04|26.04) ;;
    *)
        warn "Ubuntu ${VERSION_ID:-unknown} has not been tested by this script."
        read -r -p "Continue on this Ubuntu release? [y/N]: " response
        yes_answer "$response" || die "Cancelled."
        ;;
esac

printf 'Operating system:      %s\n' "${PRETTY_NAME:-Ubuntu}"

if dpkg-query -W -f='${db:Status-Status}\n' initramfs-tools 2>/dev/null |
    grep -q '^installed$'; then
    INITRAMFS_BACKEND='initramfs-tools'
elif dpkg-query -W -f='${db:Status-Status}\n' dracut 2>/dev/null |
    grep -q '^installed$'; then
    INITRAMFS_BACKEND='dracut'
else
    die "Could not identify an installed initramfs generator."
fi

printf 'Initramfs generator:  %s\n' "$INITRAMFS_BACKEND"

###############################################################################
# Install dependencies without replacing the installed initramfs generator
###############################################################################

info "Installing required Ubuntu packages"

export DEBIAN_FRONTEND=noninteractive
apt-get update

if ! apt-cache show clevis-tpm2 >/dev/null 2>&1; then
    warn "Clevis packages are unavailable; enabling Ubuntu's Universe archive."
    apt-get install -y software-properties-common
    add-apt-repository -y universe
    apt-get update
fi

COMMON_PACKAGES=(
    clevis
    clevis-luks
    clevis-tpm2
    cryptsetup
    jq
    lvm2
    mokutil
    tpm2-tools
    util-linux
)

if [[ "$INITRAMFS_BACKEND" == 'initramfs-tools' ]]; then
    INTEGRATION_PACKAGE='clevis-initramfs'
else
    INTEGRATION_PACKAGE='clevis-dracut'
fi

apt-get install -y "${COMMON_PACKAGES[@]}" "$INTEGRATION_PACKAGE"

REQUIRED_COMMANDS=(
    awk
    blkid
    clevis
    cryptsetup
    findmnt
    grep
    lsblk
    mktemp
    tpm2_pcrread
)

if [[ "$INITRAMFS_BACKEND" == 'initramfs-tools' ]]; then
    REQUIRED_COMMANDS+=(lsinitramfs update-initramfs)
else
    REQUIRED_COMMANDS+=(dracut lsinitrd)
fi

for command_name in "${REQUIRED_COMMANDS[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "Required command is unavailable after installation: $command_name"
done

###############################################################################
# Detect encrypted root device
###############################################################################

info "Detecting encrypted root volume"

ROOT_SOURCE="$(findmnt -n -o SOURCE /)"
[[ -n "$ROOT_SOURCE" ]] || die "Could not determine the root filesystem."

DETECTED_LUKS_DEVICE="$(
    lsblk -s -n -p -o PATH,FSTYPE "$ROOT_SOURCE" |
        awk '$2 == "crypto_LUKS" { print $1; exit }'
)"

[[ -n "$DETECTED_LUKS_DEVICE" ]] ||
    die "Could not find a crypto_LUKS device beneath $ROOT_SOURCE."

printf 'Root filesystem:      %s\n' "$ROOT_SOURCE"
printf 'Detected LUKS device: %s\n' "$DETECTED_LUKS_DEVICE"

if [[ -n "$EXPECTED_LUKS_DEVICE" ]]; then
    printf 'Expected LUKS device: %s\n' "$EXPECTED_LUKS_DEVICE"

    if [[ "$DETECTED_LUKS_DEVICE" != "$EXPECTED_LUKS_DEVICE" ]]; then
        warn "The detected LUKS device differs from EXPECTED_LUKS_DEVICE."
        read -r -p "Continue using $DETECTED_LUKS_DEVICE? [y/N]: " response
        yes_answer "$response" || die "Cancelled."
    fi
fi

LUKS_DEVICE="$DETECTED_LUKS_DEVICE"

cryptsetup isLuks "$LUKS_DEVICE" || die "$LUKS_DEVICE is not a LUKS volume."

LUKS_VERSION="$(
    cryptsetup luksDump "$LUKS_DEVICE" |
        awk '/^Version:/ { print $2; exit }'
)"

[[ "$LUKS_VERSION" == '2' ]] ||
    die "TPM enrollment requires LUKS2; detected LUKS${LUKS_VERSION:-unknown}."

printf 'LUKS version:         %s\n' "$LUKS_VERSION"

###############################################################################
# Verify crypttab describes the encrypted root
###############################################################################

info "Checking /etc/crypttab"

LUKS_UUID="$(blkid -s UUID -o value "$LUKS_DEVICE")"
[[ -n "$LUKS_UUID" ]] || die "Could not determine the LUKS UUID."

[[ -f /etc/crypttab ]] || die "/etc/crypttab does not exist."

CRYPT_NAME="$(
    awk -v uuid="$LUKS_UUID" '
        $1 !~ /^#/ && $2 == "UUID=" uuid { print $1; exit }
    ' /etc/crypttab
)"

[[ -n "$CRYPT_NAME" ]] ||
    die "Could not find root LUKS UUID=$LUKS_UUID in /etc/crypttab."

printf 'Crypt mapping:         %s\n' "$CRYPT_NAME"
printf 'LUKS UUID:             %s\n' "$LUKS_UUID"

# Clevis' early-boot hook answers the existing cryptroot password request.
# Do not add systemd's tpm2-device= option: this script creates a Clevis token,
# not a systemd-cryptenroll token.

###############################################################################
# Verify TPM 2.0
###############################################################################

info "Checking TPM 2.0"

if [[ -c /dev/tpmrm0 ]]; then
    TPM_DEVICE='/dev/tpmrm0'
elif [[ -c /dev/tpm0 ]]; then
    TPM_DEVICE='/dev/tpm0'
else
    die "No TPM device was found. Enable TPM 2.0 in firmware or attach a vTPM."
fi

printf 'TPM device:            %s\n' "$TPM_DEVICE"
tpm2_getcap properties-fixed >/dev/null || die "The TPM 2.0 could not be queried."

if command -v mokutil >/dev/null 2>&1; then
    SECURE_BOOT_STATE="$(mokutil --sb-state 2>/dev/null || true)"
    printf 'Secure Boot:           %s\n' "${SECURE_BOOT_STATE:-unknown}"
fi

###############################################################################
# Verify current LUKS passphrase
###############################################################################

test_passphrase() {
    local candidate="$1"
    local test_keyfile

    [[ -n "$candidate" ]] || return 1

    test_keyfile="$(mktemp /run/luks-passphrase-test.XXXXXX)"
    chmod 0600 "$test_keyfile"
    printf '%s' "$candidate" > "$test_keyfile"

    if cryptsetup open --test-passphrase --key-file="$test_keyfile" \
        "$LUKS_DEVICE" >/dev/null 2>&1; then
        secure_remove "$test_keyfile"
        return 0
    fi

    secure_remove "$test_keyfile"
    return 1
}

info "Verifying current LUKS passphrase"

if [[ "$UNLOCK_LUKSPW" == 'your_iac_luks_passphrase' ]]; then
    UNLOCK_LUKSPW=''
fi

while ! test_passphrase "$UNLOCK_LUKSPW"; do
    if [[ -n "$UNLOCK_LUKSPW" ]]; then
        warn "The supplied passphrase was not accepted."
        read -r -p "Try another passphrase? [y/N]: " response
        yes_answer "$response" || die "No valid LUKS passphrase was supplied."
    fi

    [[ -t 0 ]] ||
        die "A valid ENV_SETUP_LUKSPW is required when running noninteractively."

    read -r -s -p "Enter the current LUKS passphrase: " UNLOCK_LUKSPW
    printf '\n'
done

printf 'Passphrase accepted.\n'

###############################################################################
# Select enrollment mode
###############################################################################

info "Select TPM enrollment mode"

cat <<'EOF'
1) PCR 0+2 — Template or staging deployment

   Temporary enrollment for a template, staging disk, cloning workflow, or
   initial deployment. The final machine must later be rebound to PCR 7.

2) PCR 7 — Final deployment

   Bind to the Secure Boot policy state of the final installed system.
EOF

while true; do
    printf '\n'
    read -r -p "Selection [2]: " selection
    selection="${selection:-2}"

    case "$selection" in
        1)
            PCR_SELECTION='0+2'
            PCR_CLEVIS='0,2'
            DEPLOYMENT_MODE='template'
            warn "PCR 0+2 is temporary. Rebind the final machine to PCR 7."
            read -r -p "Continue with PCR 0+2? [y/N]: " response
            yes_answer "$response" && break
            ;;
        2)
            PCR_SELECTION='7'
            PCR_CLEVIS='7'
            DEPLOYMENT_MODE='final'
            read -r -p "Enroll this system as a final PCR 7 deployment? [y/N]: " response
            yes_answer "$response" && break
            ;;
        *)
            printf 'Enter 1 or 2.\n'
            ;;
    esac
done

printf 'Selected PCR policy:  %s\n' "$PCR_SELECTION"
printf 'Deployment mode:      %s\n' "$DEPLOYMENT_MODE"

tpm2_pcrread "sha256:$PCR_CLEVIS" >/dev/null ||
    die "The TPM does not expose the requested PCRs in the SHA-256 bank."

if [[ "$PCR_SELECTION" == '7' && "${SECURE_BOOT_STATE:-}" != *enabled* ]]; then
    warn "PCR 7 was selected while Secure Boot does not appear to be enabled."
    warn "Auto-unlock can work, but PCR 7 provides a weaker boot-policy signal."
    read -r -p "Continue anyway? [y/N]: " response
    yes_answer "$response" || die "Cancelled."
fi

###############################################################################
# Back up the LUKS header and handle existing Clevis TPM2 bindings
###############################################################################

info "Backing up the LUKS2 header"

mkdir -p "$STATE_DIR"
chmod 0700 "$STATE_DIR"

HEADER_BACKUP="$STATE_DIR/luks-header-before-tpm-$(date +%Y%m%d-%H%M%S).img"
cryptsetup luksHeaderBackup "$LUKS_DEVICE" --header-backup-file "$HEADER_BACKUP"
chmod 0600 "$HEADER_BACKUP"
printf 'LUKS header backup:   %s\n' "$HEADER_BACKUP"

info "Checking existing Clevis TPM2 bindings"

mapfile -t EXISTING_TPM_SLOTS < <(
    clevis luks list -d "$LUKS_DEVICE" 2>/dev/null |
        awk '$2 == "tpm2" { sub(/:$/, "", $1); print $1 }'
)

if (( ${#EXISTING_TPM_SLOTS[@]} > 0 )); then
    warn "Existing Clevis TPM2 slot(s): ${EXISTING_TPM_SLOTS[*]}"
    read -r -p "Replace the existing Clevis TPM2 binding(s)? [y/N]: " response

    if yes_answer "$response"; then
        for slot in "${EXISTING_TPM_SLOTS[@]}"; do
            clevis luks unbind -f -d "$LUKS_DEVICE" -s "$slot"
        done
    else
        die "Existing TPM enrollment was left unchanged."
    fi
else
    printf 'No existing Clevis TPM2 binding detected.\n'
fi

###############################################################################
# Bind a new random LUKS key to the TPM
###############################################################################

info "Binding LUKS2 to TPM2 using PCR $PCR_SELECTION"

KEYFILE="$(mktemp /run/luks-tpm-bind.XXXXXX)"
chmod 0600 "$KEYFILE"
printf '%s' "$UNLOCK_LUKSPW" > "$KEYFILE"

TPM_CONFIG="$(
    printf '{"hash":"sha256","key":"ecc","pcr_bank":"sha256","pcr_ids":"%s"}' \
        "$PCR_CLEVIS"
)"

clevis luks bind -f -y \
    -k "$KEYFILE" \
    -d "$LUKS_DEVICE" \
    tpm2 "$TPM_CONFIG"

secure_remove "$KEYFILE"
KEYFILE=''
unset UNLOCK_LUKSPW ENV_SETUP_LUKSPW

mapfile -t NEW_TPM_SLOTS < <(
    clevis luks list -d "$LUKS_DEVICE" |
        awk '$2 == "tpm2" { sub(/:$/, "", $1); print $1 }'
)

(( ${#NEW_TPM_SLOTS[@]} > 0 )) ||
    die "Clevis did not report a TPM2 binding after enrollment."

printf 'Clevis TPM2 slot(s):  %s\n' "${NEW_TPM_SLOTS[*]}"

###############################################################################
# Record enrollment state
###############################################################################

info "Recording deployment state"

{
    printf 'LUKS_DEVICE=%q\n' "$LUKS_DEVICE"
    printf 'LUKS_UUID=%q\n' "$LUKS_UUID"
    printf 'CRYPT_NAME=%q\n' "$CRYPT_NAME"
    printf 'PCR_SELECTION=%q\n' "$PCR_SELECTION"
    printf 'DEPLOYMENT_MODE=%q\n' "$DEPLOYMENT_MODE"
    printf 'INITRAMFS_BACKEND=%q\n' "$INITRAMFS_BACKEND"
    printf 'HEADER_BACKUP=%q\n' "$HEADER_BACKUP"
} > "$STATE_DIR/enrollment.conf"

chmod 0600 "$STATE_DIR/enrollment.conf"

if [[ "$DEPLOYMENT_MODE" == 'template' ]]; then
    cat > "$RESEAL_MARKER" <<EOF
This system is temporarily bound using TPM PCR 0+2.

After final deployment:
  1. Boot the final machine using its permanent disk and TPM.
  2. Verify the unique recovery passphrase.
  3. Unbind the PCR 0+2 Clevis TPM2 slot.
  4. Bind a new Clevis TPM2 slot using PCR 7.
  5. Rebuild the installed initramfs implementation.
  6. Verify an attended reboot before relying on unattended boot.
EOF
    chmod 0600 "$RESEAL_MARKER"
    printf 'Created reseal marker: %s\n' "$RESEAL_MARKER"
else
    rm -f "$RESEAL_MARKER"
fi

###############################################################################
# Rebuild and inspect initramfs
###############################################################################

info "Rebuilding $INITRAMFS_BACKEND initramfs"

KERNEL_VERSION="$(uname -r)"
INITRD="/boot/initrd.img-$KERNEL_VERSION"

[[ -d "/lib/modules/$KERNEL_VERSION" ]] ||
    die "Kernel modules are missing for $KERNEL_VERSION."

if [[ "$INITRAMFS_BACKEND" == 'initramfs-tools' ]]; then
    update-initramfs -u -k all
else
    dracut --force "$INITRD" "$KERNEL_VERSION"
fi

[[ -s "$INITRD" ]] || die "No valid initramfs was found at $INITRD."

if [[ "$INITRAMFS_BACKEND" == 'initramfs-tools' ]]; then
    INITRD_LISTING="$(lsinitramfs "$INITRD")"
else
    INITRD_LISTING="$(lsinitrd "$INITRD")"
fi

grep -qi clevis <<< "$INITRD_LISTING" ||
    die "The rebuilt initramfs does not appear to contain Clevis integration."

grep -Eq 'tpm2|libtss2' <<< "$INITRD_LISTING" ||
    warn "TPM2 components were not obvious in the initramfs listing; inspect it manually."

if command -v update-grub >/dev/null 2>&1; then
    update-grub
fi

###############################################################################
# Final verification
###############################################################################

info "Verifying enrollment"

CLEVIS_LIST="$(clevis luks list -d "$LUKS_DEVICE")"
printf '%s\n' "$CLEVIS_LIST"

grep -q 'tpm2' <<< "$CLEVIS_LIST" ||
    die "A Clevis TPM2 binding was not found after the initramfs rebuild."

cryptsetup luksDump "$LUKS_DEVICE" |
    grep -A20 -B3 -Ei 'Tokens:|clevis' || true

###############################################################################
# Completion
###############################################################################

printf '\nSUCCESS\n\n'
printf 'LUKS device:          %s\n' "$LUKS_DEVICE"
printf 'Crypt mapping:        %s\n' "$CRYPT_NAME"
printf 'TPM PCR policy:       %s\n' "$PCR_SELECTION"
printf 'Deployment mode:      %s\n' "$DEPLOYMENT_MODE"
printf 'Initramfs generator:  %s\n' "$INITRAMFS_BACKEND"
printf 'Initramfs:            %s\n' "$INITRD"
printf 'LUKS header backup:   %s\n' "$HEADER_BACKUP"

cat <<'EOF'

The existing LUKS recovery passphrase remains enrolled.
No existing passphrase keyslot was removed or changed.

Do not treat installation-time checks as proof of boot-time unlock. Perform an
attended reboot with console access and confirm that the machine reaches the
login prompt without requesting the LUKS passphrase.
EOF

if [[ "$DEPLOYMENT_MODE" == 'template' ]]; then
    cat <<EOF

TEMPLATE/STAGING WARNING:

This machine is temporarily bound to PCR 0+2. Rebind it to PCR 7 after final
deployment. The reminder is stored at:

  $RESEAL_MARKER
EOF
fi

cat <<'EOF'

Reboot when ready:

    sudo reboot

If TPM automatic unlock fails, enter the existing recovery passphrase.
EOF
