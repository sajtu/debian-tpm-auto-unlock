# Debian LUKS2 TPM2 Automatic Unlock (debian-tpm-auto-unlock)
Setup auto-unlock for LUKS secured root filesystem on Debian
git clone git@github.com:/sajtu/debian-tpm-auto-unlock

This script configures TPM2-backed automatic unlocking for the encrypted root volume of a Debian 13 system using `systemd-cryptenroll` and dracut.

> [!WARNING]
> This script changes the LUKS2 header, `/etc/crypttab`, and the system initramfs. A mistake can make the system unbootable. Test it on disposable virtual machines before using it on production systems, retain a verified recovery passphrase, and have console access available for the first reboot.

## Intended environment

The script is designed for a narrowly defined system layout:

- Debian 13
- LUKS2-encrypted root filesystem
- LVM inside the encrypted volume
- One encrypted root device
- dracut as the initramfs generator
- A physical TPM 2.0 or VM vTPM
- Root disk normally located at `/dev/sda3`
- Console access for recovery and first-boot testing

Other storage layouts may require changes.

## What the script does

The script:

1. Confirms that it is running as root on Debian.
2. Installs the required cryptsetup, systemd, TPM, LVM, and dracut packages.
3. Locates the LUKS device underneath the mounted root filesystem.
4. Confirms that the device uses LUKS2.
5. Detects a TPM 2.0 device.
6. Verifies the existing LUKS recovery passphrase.
7. Enrolls the TPM using the selected PCR policy.
8. Adds `tpm2-device=auto` to the root entry in `/etc/crypttab`.
9. Configures dracut to include systemd, cryptsetup, device-mapper, and TPM support.
10. Records the selected deployment mode.
11. Rebuilds the initramfs.
12. Confirms that a systemd TPM2 token appears in the LUKS2 metadata.

## Security model

TPM automatic unlock protects primarily against removal of the encrypted disk and attempts to unlock it away from the enrolled TPM.

It does not protect against every attack on a running or already-unlocked system. TPM-only unlocking also does not require a human authentication factor unless a TPM PIN is configured separately.

### PCR 7

PCR 7 normally represents the UEFI Secure Boot policy. This mode should be used only when Secure Boot is enabled and its configuration is controlled.

PCR 7 alone does not necessarily measure every kernel or initramfs byte in a traditional Debian/GRUB boot configuration. Environments requiring stronger boot-integrity guarantees should evaluate Unified Kernel Images and signed PCR policies.

### PCR 0+2

PCR 0 and PCR 2 contain measurements associated with platform firmware and related executable code. These values can change after firmware, virtual hardware, or platform updates.

This repository uses PCR 0+2 only as a temporary project-specific staging policy. It should not be interpreted as a generally recommended template policy.

## Deployment modes

### Final deployment

Use final mode when the machine is already attached to its permanent disk and unique TPM or vTPM.

The script enrolls the current TPM using PCR 7. Secure Boot should be enabled before enrollment.

### Template or staging deployment

Use template mode only when an external post-deployment process will complete enrollment on the final VM.

A TPM token is cryptographically tied to the TPM against which it was enrolled. A token created on a template TPM will not work with a newly created vTPM.

After deployment, the final machine must:

1. Boot using the temporary recovery passphrase.
2. Add and verify a unique recovery passphrase.
3. Enroll its own TPM using the final PCR policy.
4. Verify that the TPM can unlock the volume.
5. Rebuild and inspect every installed kernel’s initramfs.
6. Reboot and verify unattended unlock.
7. Remove the temporary passphrase only after all previous checks succeed.

Do not clone or share vTPM state between deployed systems.

## Prerequisites

Before running the script, confirm that:

- A current backup exists.
- A valid LUKS recovery passphrase is available.
- The recovery passphrase has been tested.
- Console or hypervisor access is available.
- The virtual machine has a unique TPM 2.0 device.
- Secure Boot is enabled when using a PCR 7 policy.
- The machine is already configured to use dracut.
- The root storage layout matches the supported assumptions.
- No unattended reboot is scheduled during enrollment.

A LUKS header backup should be stored offline in a protected location. The header contains security-sensitive keyslot metadata.

## Usage

Make the script executable:

```console
chmod 0700 setup-luks-tpm.sh
```

Run it from a root console:

```console
sudo ./setup-luks-tpm.sh
```

Follow the prompts to:

- Confirm any unexpected LUKS device.
- Supply the current LUKS passphrase.
- Select the deployment mode.
- Authorize replacement of an existing TPM enrollment.

Do not reboot until the verification steps have completed.

## Files changed

The script may create or modify:

- `/etc/crypttab`
- `/etc/dracut.conf.d/90-luks-tpm.conf`
- `/boot/initrd.img-*`
- `/var/lib/luks-tpm-autounlock/enrollment.conf`
- `/var/lib/luks-tpm-autounlock/pending-pcr7-reseal`

A timestamped `/etc/crypttab.before-tpm.*` backup is created before `/etc/crypttab` is changed.

## Verification

Before rebooting, verify the token metadata:

```console
sudo systemd-cryptenroll /dev/sda3
sudo cryptsetup luksDump /dev/sda3
```

Inspect the initramfs:

```console
sudo lsinitrd -m /boot/initrd.img-$(uname -r)
sudo lsinitrd /boot/initrd.img-$(uname -r) |
    grep -E 'crypttab|systemd-cryptsetup|tpm'
```

Metadata presence alone does not prove that TPM unsealing works. The release process should also perform a noninteractive test unlock using `systemd-cryptsetup` before rebooting.

For systems with more than one installed kernel, inspect every initramfs that GRUB may boot.

## First reboot

Keep the VM console open during the first reboot:

```console
sudo reboot
```

Expected behavior:

- The TPM unlocks the root volume automatically.
- The system reaches its normal login target without requesting the LUKS passphrase.

If TPM unlock fails, enter the retained recovery passphrase at the console.

Do not remove the recovery passphrase after only one successful boot. Retain at least one tested recovery method.

## Recovery

If the machine requests a passphrase:

1. Enter the retained LUKS recovery passphrase.
2. Confirm the current Secure Boot and TPM state.
3. Inspect the TPM token:

   ```console
   sudo cryptsetup luksDump /dev/sda3
   ```

4. Inspect the boot log:

   ```console
   sudo journalctl -b | grep -Ei 'crypt|tpm|luks'
   ```

5. Inspect the initramfs:

   ```console
   sudo lsinitrd /boot/initrd.img-$(uname -r)
   ```

6. Re-enroll the TPM only after confirming that a working recovery passphrase remains.

Never wipe the last known-good LUKS keyslot.

## PCR changes and updates

TPM unlocking may stop working when measured boot state changes. Depending on the selected PCRs, this can happen after:

- Firmware updates
- Secure Boot key changes
- Bootloader changes
- Virtual hardware changes
- TPM or vTPM replacement
- Some kernel or initramfs changes
- Changes to the VM boot path

Always retain the recovery passphrase during system and firmware updates.

## Limitations

The script currently:

- Supports Debian only.
- Assumes one encrypted root volume.
- Does not configure encrypted swap or additional LUKS volumes.
- Expects `/etc/crypttab` to identify the root device as `UUID=<uuid>`.
- Does not rotate the recovery passphrase.
- Does not create or export a recovery key.
- Does not prove TPM unsealing before reboot.
- Does not automatically restore all changes after a partial failure.
- Rebuilds only the running kernel’s initramfs unless modified.
- Uses an interactive workflow and is not suitable for unattended provisioning as written.

## References

- [systemd-cryptenroll](https://manpages.debian.org/trixie/systemd/systemd-cryptenroll.1.en.html)
- [systemd crypttab](https://www.freedesktop.org/software/systemd/man/crypttab.html)
- [Debian dracut](https://packages.debian.org/stable/utils/dracut)
- [dracut configuration](https://manpages.debian.org/trixie/dracut-core/dracut.conf.5.en.html)
- [lsinitrd](https://manpages.debian.org/trixie/dracut-core/lsinitrd.1.en.html)

## License

See LICENSE (MIT License) file.
