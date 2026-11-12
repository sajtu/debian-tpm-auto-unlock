#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export LC_ALL=C

## Optional automation passphrase. Do not commit a real passphrase here.
DEFAULT_SETUP_LUKSPW='your_iac_luks_passphrase'

## Preferred automation input:
##   export ENV_SETUP_LUKSPW='current LUKS passphrase'
## The variable is unset by this script during cleanup.

###############################################################################
# Debian/Ubuntu family LUKS2 + TPM2 automatic-unlock setup (generation 2)
#
# Supported design:
#   - Debian, Ubuntu, or derivatives declaring either family in ID_LIKE
#   - Encrypted root filesystem using LUKS2 (including LVM-on-LUKS)
#   - Ubuntu's installed initramfs generator is retained:
#       * initramfs-tools -> clevis-initramfs
#       * dracut          -> systemd-cryptenroll + systemd-cryptsetup
#   - Existing generator is inspected and retained; ambiguous setups stop.
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
trap 'exit 130' INT
trap 'exit 143' TERM

[[ "$EUID" -eq 0 ]] || die "Run this script with sudo or as root."

###############################################################################
# Verify Ubuntu and the existing initramfs implementation
###############################################################################

[[ -r /etc/os-release ]] || die "Cannot determine the operating system."

# shellcheck disable=SC1091
source /etc/os-release

case " ${ID:-} ${ID_LIKE:-} " in
    *' debian '*|*' ubuntu '*) ;;
    *) die "This script supports Debian, Ubuntu and compatible derivatives only." ;;
esac
printf 'Operating system:      %s\n' "${PRETTY_NAME:-$ID}"

# Inspect the running kernel's on-disk image AND installed generator ownership.
# A binary's presence alone is not proof that it manages this system.
package_installed() {
    [[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" == installed ]]
}
classify_image() {
    local listing="$1" dr=0 it=0
    if grep -Eq '(^|[ /])(usr/)?lib/dracut/|(^|[ /])dracut([/-]|$)' <<< "$listing"; then dr=1; fi
    if grep -Eq '(^|[ /])scripts/functions$|(^|[ /])conf/initramfs.conf$' <<< "$listing"; then it=1; fi
    if (( dr == 1 && it == 0 )); then printf dracut
    elif (( it == 1 && dr == 0 )); then printf initramfs-tools
    else return 1
    fi
}
info "Detecting active initramfs generator"
KERNEL_VERSION="$(uname -r)"
INITRD="/boot/initrd.img-$KERNEL_VERSION"
[[ -s "$INITRD" && -d "/lib/modules/$KERNEL_VERSION" ]] ||
    die "Missing running-kernel initramfs or modules; cannot safely select a generator."
if command -v lsinitramfs >/dev/null 2>&1; then
    IMAGE_LISTING="$(lsinitramfs "$INITRD")" || die "Cannot inspect $INITRD."
elif command -v lsinitrd >/dev/null 2>&1; then
    IMAGE_LISTING="$(lsinitrd "$INITRD")" || die "Cannot inspect $INITRD."
else
    die "Neither lsinitramfs nor lsinitrd is available; cannot safely inspect the boot image."
fi
INITRAMFS_BACKEND="$(classify_image "$IMAGE_LISTING")" ||
    die "Unknown or mixed initramfs contents; refusing to guess the generator."
package_installed "$INITRAMFS_BACKEND" || die "Image and installed generator disagree."
if [[ "$INITRAMFS_BACKEND" == dracut ]]; then OTHER_GENERATOR=initramfs-tools
else OTHER_GENERATOR=dracut; fi
if package_installed "$OTHER_GENERATOR"; then
    die "Both generator packages are installed; resolve active kernel hook ownership first."
fi
printf 'Initramfs generator:  %s\n' "$INITRAMFS_BACKEND"

info "Installing required packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
COMMON_PACKAGES=(cryptsetup jq lvm2 tpm2-tools util-linux)
if [[ "$INITRAMFS_BACKEND" == dracut ]]; then
    COMMON_PACKAGES+=(systemd-cryptsetup)
    REQUIRED_COMMANDS=(dracut lsinitrd systemd-cryptenroll)
    EXPECTED_LUKS_DEVICE="${EXPECTED_LUKS_DEVICE:-/dev/sda3}"
else
    COMMON_PACKAGES+=(clevis clevis-luks clevis-tpm2 clevis-initramfs mokutil)
    REQUIRED_COMMANDS=(clevis lsinitramfs update-initramfs)
fi
# Do not enable archives automatically or allow dependency resolution to remove
# packages. In particular, never install a generator as a side effect.
APT_PLAN="$(apt-get -s --no-remove install "${COMMON_PACKAGES[@]}")" ||
    die "Required packages are unavailable without removing installed packages."
if grep -Eq "^Inst ($OTHER_GENERATOR|$OTHER_GENERATOR-core)( |$)" <<< "$APT_PLAN"; then
    die "Package installation would introduce the other initramfs generator."
fi
apt-get --no-remove install -y "${COMMON_PACKAGES[@]}"
package_installed "$INITRAMFS_BACKEND" || die "Generator package changed unexpectedly."
if package_installed "$OTHER_GENERATOR"; then die "Conflicting generator appeared."; fi
REQUIRED_COMMANDS+=(awk blkid cryptsetup findmnt grep lsblk mktemp jq tpm2_getcap tpm2_pcrread)
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
        awk '$2 == "crypto_LUKS" { print $1 }'
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

[[ "$DETECTED_LUKS_DEVICE" != *$'\n'* ]] || die "Multiple encrypted root ancestors detected; refusing to guess."
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
ROOT_CRYPT_OPTIONS="$(awk -v uuid="$LUKS_UUID" '$1 !~ /^#/ && $2 == "UUID=" uuid {print $4}' /etc/crypttab)"
if [[ "$INITRAMFS_BACKEND" == initramfs-tools && "$ROOT_CRYPT_OPTIONS" == *tpm2-* ]]; then
    die "Root crypttab contains systemd TPM options; review before using Clevis."
fi
if [[ "$INITRAMFS_BACKEND" == dracut && "$ROOT_CRYPT_OPTIONS" == *tpm2-device=* && ",$ROOT_CRYPT_OPTIONS," != *,tpm2-device=auto,* ]]; then
    die "Root crypttab has a conflicting TPM device option."
fi

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
    KEYFILE="$test_keyfile"
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

if [[ "$INITRAMFS_BACKEND" == dracut ]]; then
    MODE_DEFAULT=1
cat <<'EOF'
1) PCR 0+2 — Template or staging deployment

   Use when this disk may initially boot through a different boot path,
   such as a template, staging OS, cloning process, or initial deployment.

   The final deployed VM must later be resealed to PCR 7.

2) PCR 7 — Final deployment

   Use when this is the final installed system and it will boot normally
   from its permanent virtual disk and vTPM.
EOF

else
    MODE_DEFAULT=2
cat <<'EOF'
1) PCR 0+2 — Template or staging deployment

   Temporary enrollment for a template, staging disk, cloning workflow, or
   initial deployment. The final machine must later be rebound to PCR 7.

2) PCR 7 — Final deployment

   Bind to the Secure Boot policy state of the final installed system.
EOF

fi

while true; do
    printf '\n'
    read -r -p "Selection [$MODE_DEFAULT]: " selection
    selection="${selection:-$MODE_DEFAULT}"

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

if [[ "$INITRAMFS_BACKEND" == initramfs-tools && "$PCR_SELECTION" == '7' && "${SECURE_BOOT_STATE:-}" != *enabled* ]]; then
    warn "PCR 7 was selected while Secure Boot does not appear to be enabled."
    warn "Auto-unlock can work, but PCR 7 provides a weaker boot-policy signal."
    read -r -p "Continue anyway? [y/N]: " response
    yes_answer "$response" || die "Cancelled."
fi

###############################################################################
# Back up the LUKS header and handle existing Clevis TPM2 bindings
###############################################################################

# A recovery credential must belong to a slot independent of ALL tokens.
# This prevents even malformed token metadata from causing its removal.
METADATA="$(cryptsetup luksDump --dump-json-metadata "$LUKS_DEVICE")"
RECOVERY_SLOT=''
KEYFILE="$(mktemp /run/luks-recovery-check.XXXXXXXX)"
printf '%s' "$UNLOCK_LUKSPW" > "$KEYFILE"
CANDIDATE_SLOTS="$(jq -r '. as $m | .keyslots | keys[] | . as $s |
    select(([ $m.tokens[]?.keyslots[]? ] | index($s)) == null)' <<< "$METADATA")"
for slot in $CANDIDATE_SLOTS; do
    if cryptsetup open --test-passphrase --key-slot "$slot" --key-file "$KEYFILE" "$LUKS_DEVICE" >/dev/null 2>&1; then
        RECOVERY_SLOT="$slot"
        break
    fi
done
secure_remove "$KEYFILE"
KEYFILE=''
[[ -n "$RECOVERY_SLOT" ]] || die "Supplied recovery passphrase has no independent, token-free keyslot."
RECOVERY_METADATA="$(jq -cS --arg slot "$RECOVERY_SLOT" '.keyslots[$slot]' <<< "$METADATA")"

info "Backing up the LUKS2 header"

[[ ! -L "$STATE_DIR" ]] || die "State directory must not be a symlink."
install -d -o root -g root -m 0700 "$STATE_DIR"

BACKUP_DIR="$(mktemp -d "$STATE_DIR/header-backup.XXXXXXXX")"
HEADER_BACKUP="$BACKUP_DIR/luks-header.img"
cryptsetup luksHeaderBackup "$LUKS_DEVICE" --header-backup-file "$HEADER_BACKUP"
chmod 0600 "$HEADER_BACKUP"
[[ -s "$HEADER_BACKUP" ]] || die "LUKS header backup is empty."
cryptsetup luksDump "$HEADER_BACKUP" >/dev/null || die "Header backup cannot be read."
printf 'LUKS header backup:   %s\n' "$HEADER_BACKUP"

if [[ "$INITRAMFS_BACKEND" == dracut ]]; then
WIPE_ARGS=()
info "Checking existing TPM enrollment"

LUKS_DUMP="$(cryptsetup luksDump "$LUKS_DEVICE")"
if grep -q 'systemd-tpm2' <<< "$LUKS_DUMP"; then

    warn "A systemd TPM2 token is already enrolled."

    read -r -p "Replace the existing TPM enrollment? [y/N]: " response

    if yes_answer "$response"; then
        WIPE_ARGS=(--wipe-slot=tpm2)
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
    "${WIPE_ARGS[@]}" \
    --unlock-key-file="$KEYFILE" \
    --tpm2-device=auto \
    --tpm2-pcrs="$PCR_SELECTION" \
    "$LUKS_DEVICE"

secure_remove "$KEYFILE"
KEYFILE=''

info "Configuring /etc/crypttab"

LUKS_UUID="$(blkid -s UUID -o value "$LUKS_DEVICE")"
[[ -n "$LUKS_UUID" ]] ||
    die "Could not determine the LUKS UUID."

CRYPTTAB='/etc/crypttab'
CRYPTTAB_BACKUP="/etc/crypttab.before-tpm.$(date +%Y%m%d-%H%M%S)"

[[ -f "$CRYPTTAB" ]] ||
    die "$CRYPTTAB does not exist."

cp -a "$CRYPTTAB" "$CRYPTTAB_BACKUP"
CRYPTTAB_TMP="$(mktemp /etc/crypttab.tpm.XXXXXXXX)"

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
' "$CRYPTTAB" > "$CRYPTTAB_TMP"

install -o root -g root -m 0644 \
    "$CRYPTTAB_TMP" "$CRYPTTAB"

rm -f "$CRYPTTAB_TMP"

printf 'Crypt mapping:         %s\n' "$CRYPT_NAME"
printf 'LUKS UUID:             %s\n' "$LUKS_UUID"
printf 'crypttab backup:       %s\n' "$CRYPTTAB_BACKUP"

###############################################################################
# Configure dracut
###############################################################################

info "Configuring dracut"

mkdir -p /etc/dracut.conf.d

if [[ -e /etc/dracut.conf.d/90-luks-tpm.conf ]]; then
    cp -a /etc/dracut.conf.d/90-luks-tpm.conf "$BACKUP_DIR/90-luks-tpm.conf"
fi
[[ ! -L /etc/dracut.conf.d/90-luks-tpm.conf ]] || die "Dracut config must not be a symlink."
cat > /etc/dracut.conf.d/90-luks-tpm.conf <<'EOF'
hostonly="yes"
add_dracutmodules+=" systemd crypt "
add_drivers+=" dm_crypt dm_mod tpm tpm_crb tpm_tis tpm_tis_core "
EOF

else
# Refuse stale systemd TPM options rather than silently changing another setup.
if awk -v uuid="$LUKS_UUID" '$2 == "UUID=" uuid {print $4}' /etc/crypttab |
    grep -q 'tpm2-'; then
    die "Root crypttab has systemd TPM options; review them before using Clevis."
fi
info "Checking existing Clevis TPM2 bindings"

CLEVIS_LIST="$(clevis luks list -d "$LUKS_DEVICE")" || die "Cannot list Clevis bindings."
mapfile -t EXISTING_TPM_SLOTS < <(
    printf '%s\n' "$CLEVIS_LIST" |
        awk '$2 == "tpm2" { sub(/:$/, "", $1); print $1 }'
)

if (( ${#EXISTING_TPM_SLOTS[@]} > 0 )); then
    warn "Existing Clevis TPM2 slot(s): ${EXISTING_TPM_SLOTS[*]}"
    read -r -p "Replace the existing Clevis TPM2 binding(s)? [y/N]: " response

    if yes_answer "$response"; then
        : # Retire these slots only after the new binding succeeds.
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


CLEVIS_LIST="$(clevis luks list -d "$LUKS_DEVICE")" || die "Cannot list new Clevis bindings."
mapfile -t NEW_TPM_SLOTS < <(
    printf '%s\n' "$CLEVIS_LIST" |
        awk '$2 == "tpm2" { sub(/:$/, "", $1); print $1 }'
)

(( ${#NEW_TPM_SLOTS[@]} > 0 )) ||
    die "Clevis did not report a TPM2 binding after enrollment."

printf 'Clevis TPM2 slot(s):  %s\n' "${NEW_TPM_SLOTS[*]}"

NEW_SLOT_FOUND=0
for slot in "${NEW_TPM_SLOTS[@]}"; do
    [[ " ${EXISTING_TPM_SLOTS[*]} " == *" $slot "* ]] || NEW_SLOT_FOUND=1
done
(( NEW_SLOT_FOUND )) || die "No new Clevis TPM2 slot was created; old bindings retained."
for slot in "${EXISTING_TPM_SLOTS[@]}"; do
    clevis luks unbind -f -d "$LUKS_DEVICE" -s "$slot"
done
fi
AFTER_METADATA="$(cryptsetup luksDump --dump-json-metadata "$LUKS_DEVICE")"
[[ "$(jq -cS --arg slot "$RECOVERY_SLOT" '.keyslots[$slot]' <<< "$AFTER_METADATA")" == "$RECOVERY_METADATA" ]] ||
    die "Recovery keyslot metadata changed unexpectedly."
# Verify the supplied recovery passphrase still works after TPM slot changes.
test_passphrase "$UNLOCK_LUKSPW" || die "Recovery passphrase verification failed."
unset UNLOCK_LUKSPW ENV_SETUP_LUKSPW

###############################################################################
# Record enrollment state
###############################################################################

###############################################################################
# Rebuild and inspect initramfs
###############################################################################

info "Rebuilding $INITRAMFS_BACKEND initramfs"
# Preserve the running kernel's original image; do not automatically restore it.
cp -a "$INITRD" "$BACKUP_DIR/initrd.before-tpm"
printf 'Original initramfs backup: %s\n' "$BACKUP_DIR/initrd.before-tpm"

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

if [[ "$INITRAMFS_BACKEND" == initramfs-tools ]]; then
    grep -Eq 'scripts/local-top/clevis$' <<< "$INITRD_LISTING" ||
        die "The rebuilt initramfs lacks the Clevis early-boot hook."
else
    grep -q 'systemd-cryptsetup' <<< "$INITRD_LISTING" || die "Missing systemd-cryptsetup in initramfs."
    grep -q 'libcryptsetup-token-systemd-tpm2' <<< "$INITRD_LISTING" || die "Missing systemd TPM2 token plugin in initramfs."
    grep -q 'etc/crypttab' <<< "$INITRD_LISTING" || die "Missing crypttab in initramfs."
fi

grep -Eq 'tpm2|libtss2' <<< "$INITRD_LISTING" ||
    warn "TPM2 components were not obvious in the initramfs listing; inspect it manually."

if command -v update-grub >/dev/null 2>&1; then
    update-grub
fi

###############################################################################
# Final verification
###############################################################################

info "Verifying enrollment"

if [[ "$INITRAMFS_BACKEND" == initramfs-tools ]]; then
CLEVIS_LIST="$(clevis luks list -d "$LUKS_DEVICE")"
printf '%s\n' "$CLEVIS_LIST"

grep -q 'tpm2' <<< "$CLEVIS_LIST" ||
    die "A Clevis TPM2 binding was not found after the initramfs rebuild."

cryptsetup luksDump "$LUKS_DEVICE" |
    grep -A20 -B3 -Ei 'Tokens:|clevis' || true

else
LUKS_DUMP="$(cryptsetup luksDump "$LUKS_DEVICE")"
grep -q 'systemd-tpm2' <<< "$LUKS_DUMP" || die "Missing systemd TPM2 token."
printf '%s\n' "$LUKS_DUMP" | grep -A25 -B3 -E 'Tokens:|systemd-tpm2|tpm2-pcrs' || true
fi

info "Recording deployment state"
for state_file in "$STATE_DIR/enrollment.conf" "$RESEAL_MARKER"; do
    [[ ! -L "$state_file" ]] || die "State files must not be symlinks."
done

{
    printf 'LUKS_DEVICE=%q\n' "$LUKS_DEVICE"
    printf 'LUKS_UUID=%q\n' "$LUKS_UUID"
    printf 'CRYPT_NAME=%q\n' "$CRYPT_NAME"
    printf 'PCR_SELECTION=%q\n' "$PCR_SELECTION"
    printf 'DEPLOYMENT_MODE=%q\n' "$DEPLOYMENT_MODE"
    printf 'INITRAMFS_BACKEND=%q\n' "$INITRAMFS_BACKEND"
    printf 'HEADER_BACKUP=%q\n' "$HEADER_BACKUP"
    printf 'RECOVERY_SLOT=%q\n' "$RECOVERY_SLOT"
} > "$STATE_DIR/enrollment.conf"

chmod 0600 "$STATE_DIR/enrollment.conf"

if [[ "$DEPLOYMENT_MODE" == 'template' ]]; then
    cat > "$RESEAL_MARKER" <<EOF
This system is temporarily bound using TPM PCR 0+2.

After final deployment:
  1. Boot the final machine using its permanent disk and TPM.
  2. Verify the unique recovery passphrase.
  3. Replace the PCR 0+2 TPM enrollment using the recorded backend.
  4. Enroll the final TPM using PCR 7.
  5. Rebuild the installed initramfs implementation.
  6. Verify an attended reboot before relying on unattended boot.
EOF
    chmod 0600 "$RESEAL_MARKER"
    printf 'Created reseal marker: %s\n' "$RESEAL_MARKER"
else
    rm -f "$RESEAL_MARKER"
fi

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
