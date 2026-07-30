#!/usr/bin/env bash
set -Eeuo pipefail

## If you need to set a default luks password that you initially
## use for your automation process, set it here.
DEFAULT_SETUP_LUKSPW='your_iac_luks_passphrase'

## You can also set environmental variable, ENV_SETUP_LUKSPW prior
## to running too:  export ENV_SETUP_LUKSPW="your_iac_luks_passphrase"

###############################################################################
# Debian LUKS2 + TPM2 automatic-unlock setup
#
# Standard build assumptions:
#   - Debian 13 minimal installation
#   - Guided encrypted LVM
#   - Single root filesystem
#   - LUKS root device normally /dev/sda3
#   - dracut handles the initramfs
#
# Enrollment modes:
#   PCR 0+2 = temporary template/staging enrollment
#   PCR 7   = final deployed-system enrollment
#
# The existing recovery passphrase is retained.
###############################################################################

# set to default password
UNLOCK_LUKSPW="$DEFAULT_SETUP_LUKSPW"

# if environment variable is set, use that.
if [[ -n $ENV_SETUP_LUKSPW ]]; then
	UNLOCK_LUKSPW="$ENV_SETUP_LUKSPW";
fi


EXPECTED_LUKS_DEVICE='/dev/sda3'
STATE_DIR='/var/lib/luks-tpm-autounlock'
RESEAL_MARKER="$STATE_DIR/pending-pcr7-reseal"

LUKS_DEVICE=''
PCR_SELECTION=''
DEPLOYMENT_MODE=''
KEYFILE=''

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
    unset UNLOCK_LUKSPW
}

trap cleanup EXIT

[[ "$EUID" -eq 0 ]] ||
    die "Run this script with sudo or as root."

###############################################################################
# Verify Debian
###############################################################################

[[ -r /etc/os-release ]] ||
    die "Cannot determine the operating system."

# shellcheck disable=SC1091
source /etc/os-release

[[ "${ID:-}" == "debian" ]] ||
    die "This script currently supports Debian only."

printf 'Operating system: %s\n' "${PRETTY_NAME:-Debian}"

###############################################################################
# Install dependencies
###############################################################################

info "Installing required packages"

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y \
    cryptsetup \
    systemd-cryptsetup \
    tpm2-tools \
    dracut \
    dracut-core \
    lvm2 \
    util-linux

REQUIRED_COMMANDS=(
    awk
    blkid
    cryptsetup
    date
    dracut
    findmnt
    grep
    lsblk
    mktemp
    systemd-cryptenroll
)

for command_name in "${REQUIRED_COMMANDS[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "Required command is unavailable after package installation: $command_name"
done

###############################################################################
# Detect encrypted root device
###############################################################################

info "Detecting encrypted root volume"

ROOT_SOURCE="$(findmnt -n -o SOURCE /)"
[[ -n "$ROOT_SOURCE" ]] ||
    die "Could not determine the mounted root filesystem."

DETECTED_LUKS_DEVICE="$(
    lsblk -s -n -p -o PATH,FSTYPE "$ROOT_SOURCE" |
        awk '$2 == "crypto_LUKS" { print $1; exit }'
)"

[[ -n "$DETECTED_LUKS_DEVICE" ]] ||
    die "Could not find the crypto_LUKS device beneath $ROOT_SOURCE."

printf 'Root filesystem:      %s\n' "$ROOT_SOURCE"
printf 'Detected LUKS device: %s\n' "$DETECTED_LUKS_DEVICE"
printf 'Expected LUKS device: %s\n' "$EXPECTED_LUKS_DEVICE"

if [[ "$DETECTED_LUKS_DEVICE" != "$EXPECTED_LUKS_DEVICE" ]]; then
    warn "The detected LUKS device differs from the standard layout."

    read -r -p \
        "Continue using $DETECTED_LUKS_DEVICE? [y/N]: " response

    yes_answer "$response" || die "Cancelled."
fi

LUKS_DEVICE="$DETECTED_LUKS_DEVICE"

cryptsetup isLuks "$LUKS_DEVICE" ||
    die "$LUKS_DEVICE is not a LUKS volume."

LUKS_VERSION="$(
    cryptsetup luksDump "$LUKS_DEVICE" |
        awk '/^Version:/ { print $2; exit }'
)"

[[ "$LUKS_VERSION" == "2" ]] ||
    die "TPM enrollment requires LUKS2; detected LUKS${LUKS_VERSION:-unknown}."

printf 'LUKS version:         %s\n' "$LUKS_VERSION"

###############################################################################
# Verify TPM
###############################################################################

info "Checking TPM 2.0"

if [[ -c /dev/tpmrm0 ]]; then
    TPM_DEVICE='/dev/tpmrm0'
elif [[ -c /dev/tpm0 ]]; then
    TPM_DEVICE='/dev/tpm0'
else
    die "No TPM device was found. Add a TPM 2.0 device to the VM."
fi

printf 'TPM device:           %s\n' "$TPM_DEVICE"

systemd-cryptenroll --tpm2-device=list || true

###############################################################################
# Verify current LUKS passphrase
###############################################################################

test_passphrase() {
    local candidate="$1"
    local test_keyfile

    test_keyfile="$(mktemp /run/luks-passphrase-test.XXXXXX)"
    chmod 0600 "$test_keyfile"
    printf '%s' "$candidate" > "$test_keyfile"

    if cryptsetup open \
        --test-passphrase \
        --key-file="$test_keyfile" \
        "$LUKS_DEVICE" >/dev/null 2>&1; then

        secure_remove "$test_keyfile"
        return 0
    fi

    secure_remove "$test_keyfile"
    return 1
}

info "Verifying current LUKS passphrase"

while ! test_passphrase "$UNLOCK_LUKSPW"; do
    warn "The expected default passphrase was not accepted."

    read -r -p "Try another passphrase? [y/N]: " response

    yes_answer "$response" ||
        die "No valid LUKS passphrase was supplied."

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

   Use when this disk may initially boot through a different boot path,
   such as a template, staging OS, cloning process, or initial deployment.

   The final deployed VM must later be resealed to PCR 7.

2) PCR 7 — Final deployment

   Use when this is the final installed system and it will boot normally
   from its permanent virtual disk and vTPM.
EOF

while true; do
    printf '\n'
    read -r -p "Selection [1]: " selection
    selection="${selection:-1}"

    case "$selection" in
        1)
            PCR_SELECTION='0+2'
            DEPLOYMENT_MODE='template'

            warn "PCR 0+2 is temporary. Reseal this VM to PCR 7 after deployment."
            read -r -p "Continue with PCR 0+2? [y/N]: " response

            yes_answer "$response" && break
            ;;

        2)
            PCR_SELECTION='7'
            DEPLOYMENT_MODE='final'

            read -r -p "Enroll this system as a final PCR 7 deployment? [y/N]: " response

            yes_answer "$response" && break
            ;;

        *)
            printf 'Enter 1 or 2.\n'
            ;;
    esac
done

printf 'Selected PCR policy: %s\n' "$PCR_SELECTION"
printf 'Deployment mode:     %s\n' "$DEPLOYMENT_MODE"

###############################################################################
# Handle existing TPM enrollment
###############################################################################

info "Checking existing TPM enrollment"

if cryptsetup luksDump "$LUKS_DEVICE" |
    grep -qE 'systemd-tpm2|type:[[:space:]]+systemd-tpm2'; then

    warn "A systemd TPM2 token is already enrolled."

    read -r -p "Replace the existing TPM enrollment? [y/N]: " response

    if yes_answer "$response"; then
        systemd-cryptenroll \
            --wipe-slot=tpm2 \
            "$LUKS_DEVICE"
    else
        die "Existing TPM enrollment was left unchanged."
    fi
else
    printf 'No existing systemd TPM2 token detected.\n'
fi

###############################################################################
# Enroll TPM
###############################################################################

info "Enrolling TPM2 using PCR $PCR_SELECTION"

KEYFILE="$(mktemp /run/luks-tpm-enroll.XXXXXX)"
chmod 0600 "$KEYFILE"
printf '%s' "$UNLOCK_LUKSPW" > "$KEYFILE"

systemd-cryptenroll \
    --unlock-key-file="$KEYFILE" \
    --tpm2-device=auto \
    --tpm2-pcrs="$PCR_SELECTION" \
    "$LUKS_DEVICE"

secure_remove "$KEYFILE"
KEYFILE=''

###############################################################################
# Update crypttab
###############################################################################

info "Configuring /etc/crypttab"

LUKS_UUID="$(blkid -s UUID -o value "$LUKS_DEVICE")"
[[ -n "$LUKS_UUID" ]] ||
    die "Could not determine the LUKS UUID."

CRYPTTAB='/etc/crypttab'
CRYPTTAB_BACKUP="/etc/crypttab.before-tpm.$(date +%Y%m%d-%H%M%S)"

[[ -f "$CRYPTTAB" ]] ||
    die "$CRYPTTAB does not exist."

cp -a "$CRYPTTAB" "$CRYPTTAB_BACKUP"

CRYPT_NAME="$(
    awk -v uuid="$LUKS_UUID" '
        $2 == "UUID=" uuid {
            print $1
            exit
        }
    ' "$CRYPTTAB"
)"

[[ -n "$CRYPT_NAME" ]] ||
    die "Could not find UUID=$LUKS_UUID in $CRYPTTAB."

awk -v uuid="$LUKS_UUID" '
BEGIN {
    OFS="\t"
}

$2 == "UUID=" uuid {
    options=$4

    if (options == "" || options == "none")
        options="luks"

    if (options !~ /(^|,)tpm2-device=auto(,|$)/)
        options=options ",tpm2-device=auto"

    $4=options
}

{
    print
}
' "$CRYPTTAB" > "${CRYPTTAB}.new"

install -o root -g root -m 0644 \
    "${CRYPTTAB}.new" "$CRYPTTAB"

rm -f "${CRYPTTAB}.new"

printf 'Crypt mapping:         %s\n' "$CRYPT_NAME"
printf 'LUKS UUID:             %s\n' "$LUKS_UUID"
printf 'crypttab backup:       %s\n' "$CRYPTTAB_BACKUP"

###############################################################################
# Configure dracut
###############################################################################

info "Configuring dracut"

mkdir -p /etc/dracut.conf.d

cat > /etc/dracut.conf.d/90-luks-tpm.conf <<'EOF'
hostonly="yes"
add_dracutmodules+=" systemd crypt "
add_drivers+=" dm_crypt dm_mod tpm tpm_crb tpm_tis tpm_tis_core "
EOF

###############################################################################
# Record enrollment state
###############################################################################

info "Recording deployment state"

mkdir -p "$STATE_DIR"
chmod 0700 "$STATE_DIR"

cat > "$STATE_DIR/enrollment.conf" <<EOF
LUKS_DEVICE='$LUKS_DEVICE'
LUKS_UUID='$LUKS_UUID'
CRYPT_NAME='$CRYPT_NAME'
PCR_SELECTION='$PCR_SELECTION'
DEPLOYMENT_MODE='$DEPLOYMENT_MODE'
EOF

chmod 0600 "$STATE_DIR/enrollment.conf"

if [[ "$DEPLOYMENT_MODE" == 'template' ]]; then
    cat > "$RESEAL_MARKER" <<EOF
This system is temporarily enrolled using TPM PCR 0+2.

After final deployment:
  1. Boot the final VM.
  2. Replace the template recovery passphrase.
  3. Wipe the PCR 0+2 TPM token.
  4. Enroll the final VM using PCR 7.
  5. Rebuild the dracut initramfs.
  6. Verify unattended reboot.
EOF

    chmod 0600 "$RESEAL_MARKER"
    printf 'Created reseal marker: %s\n' "$RESEAL_MARKER"
else
    rm -f "$RESEAL_MARKER"
    printf 'Final PCR 7 enrollment recorded.\n'
fi

###############################################################################
# Rebuild initramfs
###############################################################################

info "Rebuilding dracut initramfs"

KERNEL_VERSION="$(uname -r)"
MODULE_DIRECTORY="/lib/modules/$KERNEL_VERSION"
INITRD="/boot/initrd.img-$KERNEL_VERSION"

[[ -d "$MODULE_DIRECTORY" ]] ||
    die "Kernel modules are missing for $KERNEL_VERSION."

dracut \
    --force \
    "$INITRD" \
    "$KERNEL_VERSION"

[[ -s "$INITRD" ]] ||
    die "dracut did not create a valid initramfs at $INITRD."

if command -v update-grub >/dev/null 2>&1; then
    update-grub
fi

###############################################################################
# Verify enrollment
###############################################################################

info "Verifying TPM enrollment"

LUKS_DUMP="$(cryptsetup luksDump "$LUKS_DEVICE")"

grep -qE 'systemd-tpm2|type:[[:space:]]+systemd-tpm2' \
    <<< "$LUKS_DUMP" ||
    die "A systemd TPM2 token was not found in the LUKS2 header."

printf '%s\n' "$LUKS_DUMP" |
    grep -A25 -B3 -E 'Tokens:|systemd-tpm2|tpm2-pcrs' || true

###############################################################################
# Completion
###############################################################################

printf '\nSUCCESS\n\n'
printf 'LUKS device:       %s\n' "$LUKS_DEVICE"
printf 'Crypt mapping:     %s\n' "$CRYPT_NAME"
printf 'TPM PCR policy:    %s\n' "$PCR_SELECTION"
printf 'Deployment mode:   %s\n' "$DEPLOYMENT_MODE"
printf 'Initramfs:         %s\n' "$INITRD"

cat <<'EOF'

The existing LUKS recovery passphrase remains enrolled.
No recovery keyslot was removed or changed.
EOF

if [[ "$DEPLOYMENT_MODE" == 'template' ]]; then
    cat <<EOF

TEMPLATE/STAGING WARNING:

This system is temporarily bound to PCR 0+2.

After Terraform deploys the final VM, the post-deployment process must:

  1. Add and verify a unique recovery passphrase.
  2. Remove the temporary template passphrase.
  3. Remove the PCR 0+2 TPM enrollment.
  4. Enroll the final VM's TPM using PCR 7.
  5. Rebuild dracut.
  6. Reboot and verify automatic unlock.

Marker:
  $RESEAL_MARKER
EOF
else
    cat <<'EOF'

This system is enrolled as a final PCR 7 deployment.
EOF
fi

cat <<'EOF'

Reboot when ready:

    sudo reboot

If TPM automatic unlock fails, use the existing recovery passphrase.
EOF
