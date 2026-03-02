# Jetson Orin Nano: SWUpdate and OTA Updates

This document covers the OTA (Over-The-Air) update landscape for the Jetson Orin Nano in the n3x project. It consolidates the project's SWUpdate implementation, NVIDIA's native A/B update mechanism, and the integration considerations for each approach.

**Audience**: Developers working on the n3x ISAR/Debian backend who want to iterate on Jetson images without USB Recovery Mode after the initial flash.

## Architecture Overview

The Jetson Orin Nano has a two-level storage architecture relevant to OTA updates:

```
                    DEVELOPMENT HOST (NixOS/WSL2)
    +-----------------------------------------------------------+
    |  nix develop (flake.nix)                                  |
    |  +-- kas-container -> ISAR build system                   |
    |  +-- qemu -> Testing (existing test framework)            |
    |  +-- jetpack-nixos flash tools -> Initial flashing        |
    |                                                           |
    |  Build Outputs:                                           |
    |  +-- n3x-image-*.tar.gz (rootfs tarball)                  |
    |  +-- n3x-image-*.swu    (OTA update bundle)               |
    +-----------------------------------------------------------+
                              |
              USB Recovery Mode (initial flash only)
                              |
                              v
    +-----------------------------------------------------------+
    |              JETSON ORIN NANO TARGET                       |
    |                                                           |
    |  QSPI Flash (Bootloader)      NVMe/SD (Rootfs)           |
    |  +-- MB1/MB2 (A/B)            +-- APP (Slot A)            |
    |  +-- UEFI (A/B)               +-- APP_b (Slot B)          |
    |                                                           |
    |  Running System:                                          |
    |  +-- Debian Trixie (ISAR-built)                           |
    |  +-- nvbootctrl (slot management)                         |
    |  +-- SWUpdate daemon (optional)                           |
    |  +-- Suricatta/hawkBit client (optional)                  |
    +-----------------------------------------------------------+
```

**QSPI-NOR flash** stores the boot chain (MB1, MB2, UEFI/EDK2) with built-in A/B redundancy managed by NVIDIA's firmware. This is updated via `l4t_initrd_flash.sh` during USB flash and is not typically modified during OTA updates.

**NVMe/SD storage** holds the rootfs. With `ROOTFS_AB=1` at flash time, two rootfs partitions (APP and APP_b) are created, enabling A/B rootfs updates without USB.

## NVIDIA Native A/B Mechanism

L4T R36.x includes a built-in A/B update system that operates at two levels:

### Bootloader A/B (QSPI)

The QSPI flash always has two copies of each bootloader component (MB1, MB2, UEFI). Slot management is handled by `nvbootctrl`:

```bash
# Query bootloader slot status
sudo nvbootctrl dump-slots-info

# Get current active bootloader slot
sudo nvbootctrl get-current-slot

# Set active bootloader slot (0=A, 1=B)
sudo nvbootctrl set-active-boot-slot 0
```

Bootloader A/B is always active and managed automatically by the firmware. No user configuration is needed.

### Rootfs A/B (NVMe)

Rootfs A/B is **optional** and must be enabled at flash time:

```bash
# Flash with dual rootfs partitions
sudo ROOTFS_AB=1 ROOTFS_RETRY_COUNT_MAX=3 \
    ./tools/kernel_flash/l4t_initrd_flash.sh \
    --external-device nvme0n1p1 \
    -p "-c bootloader/generic/cfg/flash_t234_qspi.xml" \
    -c ./tools/kernel_flash/flash_l4t_t234_nvme_rootfs_ab.xml \
    --showlogs --network usb0 \
    jetson-orin-nano-devkit external
```

**Key parameters**:
- `ROOTFS_AB=1` — creates dual partitions: APP (slot A) and APP_b (slot B)
- `ROOTFS_RETRY_COUNT_MAX=3` — automatic rollback after 3 consecutive boot failures
- `flash_l4t_t234_nvme_rootfs_ab.xml` — partition layout with A/B rootfs

### Slot Management with nvbootctrl

The `-t rootfs` flag targets rootfs slots (without it, commands target bootloader slots):

```bash
# Query rootfs slot status
sudo nvbootctrl -t rootfs dump-slots-info

# Get current rootfs slot
sudo nvbootctrl -t rootfs get-current-slot

# Set next boot to slot B
sudo nvbootctrl -t rootfs set-active-boot-slot 1

# Mark current boot as successful (prevents rollback)
sudo nvbootctrl -t rootfs mark-boot-successful
```

### Update Flow with nv_update_engine

NVIDIA provides `nv_update_engine` and the `nv_ota_start.sh` wrapper script for performing updates:

1. `nv_update_engine` writes the new rootfs to the inactive slot
2. `nvbootctrl -t rootfs set-active-boot-slot` switches to the updated slot
3. System reboots into the new rootfs
4. `l4t-rootfs-validation-config.service` runs post-boot validation
5. `nv-l4tbootloader-config.service` marks the boot as successful
6. If boot fails (no successful mark within retry limit), firmware automatically switches back

The entire flow can be scripted via `nv_ota_start.sh`, which abstracts the update and slot-switching operations.

### Automatic Failover

The boot failure counter is managed in QSPI metadata. If the system fails to mark a boot as successful after `ROOTFS_RETRY_COUNT_MAX` consecutive attempts, the firmware automatically switches to the other rootfs slot on the next boot. This provides hardware-level rollback protection independent of any userspace software.

## SWUpdate Framework

[SWUpdate](https://sbabic.github.io/swupdate/) is a third-party OTA framework with fleet management capabilities (via hawkBit/Suricatta). The n3x project includes SWUpdate support with GRUB-based A/B partition switching, currently validated on QEMU x86_64.

### Partition Layout

The SWUpdate-enabled images use a different partition layout than the standard NVIDIA flash:

```
+---------------------------------------------------------------------+
| NVMe Disk (GPT)                                                     |
+----------+---------------+---------------+--------------------------+
| EFI      | APP           | APP_b         | data                     |
| (ESP)    | rootfs-a      | rootfs-b      | persistent               |
| 256MB    | 2GB           | 2GB           | 1GB                      |
| vfat     | ext4          | ext4          | ext4                     |
| GRUB +   | / (active)    | (standby)     | /data                    |
| grubenv  |               |               |                          |
+----------+---------------+---------------+--------------------------+
```

### Update Flow

1. System boots from slot A (APP partition)
2. SWUpdate receives an update bundle (`.swu` file) -- via web UI, curl, or hawkBit server
3. SWUpdate writes the new rootfs to slot B (APP_b partition)
4. SWUpdate sets `rootfs_slot=b` in GRUB environment
5. System reboots into slot B
6. Next update targets slot A (now the standby partition)

Recovery is built in: if the new rootfs fails to boot, GRUB's recovery menu entry always boots slot A.

### Building a SWUpdate-Enabled Image

The SWUpdate feature is enabled by appending the `kas/feature/swupdate.yml` overlay:

```bash
cd backends/debian
kas-build kas/base.yml:kas/machine/qemu-amd64.yml:kas/packages/debug.yml:kas/image/base.yml:kas/feature/swupdate.yml:kas/boot/grub.yml
```

This overlay:
- Installs SWUpdate from Debian repositories (via the `swupdate-config` recipe)
- Switches the partition layout to A/B (`sdimage-efi-ab.wks`)
- Configures GRUB for A/B slot selection via grubenv
- Enables ext4 image output (for update bundles)

**Note**: The SWUpdate partition layout uses WIC disk images, not rootfs tarballs. The initial flash of a SWUpdate-enabled image to Jetson requires a different approach than the standard tarball flash. The SWUpdate overlay is currently validated on QEMU x86_64. Adapting it for Jetson requires creating a Jetson-specific WKS file or using a different partition strategy that works with `l4t_initrd_flash.sh`.

### Configuration on the Device

Once booted from a SWUpdate-enabled image, SWUpdate is pre-configured:

- **Config file**: `/etc/swupdate.cfg` -- sets `bootloader = "grub"`, enables verbose logging
- **Daemon args**: `/etc/default/swupdate` -- runs with `-v -f /etc/swupdate.cfg`
- **GRUB integration**: `grub-editenv` manages `/boot/efi/EFI/BOOT/grubenv` for slot switching
- **Hardware compatibility**: Set to `n3x` by default (overridable per machine via `SWUPDATE_HW_COMPAT`)

### Web Interface

SWUpdate includes a built-in web UI for manual updates:

```bash
# On the target device:
swupdate -v -f /etc/swupdate.cfg -w "--document-root /usr/share/swupdate/www --port 8080"
```

Open `http://<device-ip>:8080` to upload `.swu` bundles, monitor progress, and view logs.

### Creating Update Bundles

An SWUpdate bundle (`.swu` file) is a cpio archive containing a `sw-description` metadata file and the update payload.

**Using the project's Nix-based bundle generator** (for Jetson rootfs tarballs):

The project includes `backends/debian/swupdate/bundle.nix` which creates `.swu` bundles from ISAR rootfs artifacts. The Nix bundle generation for Jetson (`swupdate-bundle-jetson-server`, `swupdate-bundle-jetson-base`) is currently commented out in `flake.nix` pending Jetson-specific partition layout integration.

**Creating a bundle manually** (for development/testing):

```bash
mkdir bundle-work && cd bundle-work

# Create sw-description (libconfig format)
cat > sw-description << 'SWDESC'
software = {
    version = "2026.03.01";
    hardware-compatibility = [ "n3x" ];

    images: (
        {
            filename = "rootfs.ext4";
            type = "raw";
            device = "/dev/disk/by-label/APP_b";
            sha256 = "PLACEHOLDER";
        }
    );
};
SWDESC

# Copy the ext4 rootfs image (produced when IMAGE_FSTYPES includes ext4)
cp /path/to/n3x-image-base-debian-trixie-*.ext4 rootfs.ext4

# Compute SHA256 and substitute
SHA256=$(sha256sum rootfs.ext4 | cut -d' ' -f1)
sed -i "s/PLACEHOLDER/$SHA256/" sw-description

# Create the .swu bundle (sw-description MUST be first in the archive)
(echo sw-description; echo rootfs.ext4) | cpio -o -H crc > update.swu
```

**Applying an update from the command line:**

```bash
# On the target device:
swupdate -v -f /etc/swupdate.cfg -i update.swu

# After successful apply, switch boot slot and reboot:
grub-editenv /boot/efi/EFI/BOOT/grubenv set rootfs_slot=b
reboot
```

## Comparison: nv_update_engine vs SWUpdate

| Aspect | nv_update_engine | SWUpdate |
|--------|------------------|----------|
| Type | Low-level partition manager | High-level OTA orchestrator |
| Source | Built into L4T R36 | Third-party, Debian-packaged |
| Slot management | `nvbootctrl` (native QSPI metadata) | GRUB grubenv or custom handler |
| Network fleet mgmt | No | Yes (hawkBit/Suricatta) |
| Update bundle format | Raw partition images | `.swu` cpio with metadata |
| Rollback trigger | Boot failure counter in firmware | Configurable per handler |
| Bootloader awareness | Native UEFI/nvbootctrl integration | Requires custom handler for nvbootctrl |
| Rootfs A/B | Native (flash with `ROOTFS_AB=1`) | GRUB chain-load or nvbootctrl handler |
| Signing/verification | None built-in | CMS/PKCS#7, GPG, or custom |
| Web UI | No | Yes (port 8080) |

**When to use which**:

- **nv_update_engine**: Simplest path if you only need local A/B updates on a single device with no fleet management. No additional software required beyond what L4T provides. Best for early development and single-device workflows.

- **SWUpdate**: Required for fleet management (hawkBit), signed update bundles, web-based update UI, or integration with CI/CD pipelines that produce `.swu` artifacts. More setup, but more capable for production deployments.

- **Both together**: SWUpdate can use `nvbootctrl` as its bootloader backend instead of GRUB. This combines SWUpdate's orchestration (fleet management, signing, web UI) with NVIDIA's native slot management. Requires a custom SWUpdate handler (see below).

## Jetson Integration Requirements

### For nv_update_engine (Native)

1. **Flash with `ROOTFS_AB=1`** to create dual rootfs partitions
2. No additional software needed -- `nv_update_engine`, `nvbootctrl`, and the validation services are included in the `nvidia-l4t-tools` package already in the ISAR image
3. Write updates to the inactive slot and switch with `nvbootctrl -t rootfs set-active-boot-slot`

### For SWUpdate with GRUB (Current QEMU Approach)

1. **Custom flash layout**: Create a `flash_l4t_t234_nvme.xml` that includes the A/B+EFI partition layout used by `sdimage-efi-ab.wks`
2. **GRUB as secondary bootloader**: Install GRUB under NVIDIA's UEFI, using the same grubenv-based switching validated in QEMU tests
3. **WIC image adaptation**: The SWUpdate overlay produces WIC disk images, but `l4t_initrd_flash.sh` expects rootfs tarballs or specific partition images. A bridge is needed.

### For SWUpdate with nvbootctrl (Recommended for Production)

1. **Flash with `ROOTFS_AB=1`** (same as native approach)
2. **Custom SWUpdate handler**: Write a handler that calls `nvbootctrl -t rootfs` for slot switching instead of `grub-editenv`. No public reference implementation exists -- this is custom integration work.
3. **Handler interface**: SWUpdate calls the handler with `get` (current slot), `set` (switch slot), and `confirm` (mark boot successful). Map these to `nvbootctrl` commands:
   ```bash
   # get: nvbootctrl -t rootfs get-current-slot
   # set: nvbootctrl -t rootfs set-active-boot-slot <0|1>
   # confirm: nvbootctrl -t rootfs mark-boot-successful
   ```

## Project Status

### What Works

- **QEMU x86_64 SWUpdate tests**: Four VM-based tests validated:
  - `debian-test-swupdate-bundle-validation` -- SWUpdate installation, A/B layout, bundle creation/validation, hardware compatibility
  - `debian-test-swupdate-apply` -- Signed update bundle (CMS/X.509), apply to slot B, verify content
  - `debian-test-swupdate-boot-switch` -- Full A/B cycle: boot A, update B, switch, verify B, rollback (excluded from CI due to grubenv/vfat interaction)
  - `debian-test-swupdate-network-ota` -- Two-VM test: HTTP-based bundle download and apply

Run tests with:
```bash
nix build '.#checks.x86_64-linux.debian-test-swupdate-bundle-validation' -L
nix build '.#checks.x86_64-linux.debian-test-swupdate-apply' -L
```

### What's Planned / TBD

- Jetson-specific SWUpdate partition layout (`flash_l4t_t234_nvme.xml` with A/B)
- Custom SWUpdate handler for `nvbootctrl` integration
- Nix bundle generation for Jetson targets (currently commented out in `flake.nix`)
- End-to-end Jetson A/B update test (flash, update, switch, verify)
- hawkBit server integration for fleet management

## Key Files

### SWUpdate
- `backends/debian/kas/feature/swupdate.yml` -- SWUpdate feature overlay
- `backends/debian/meta-n3x/recipes-core/swupdate/swupdate-config_1.0.bb` -- SWUpdate config recipe
- `backends/debian/meta-n3x/wic/sdimage-efi-ab.wks` -- A/B partition layout
- `backends/debian/meta-n3x/wic/grub-ab.cfg` -- GRUB A/B boot config
- `backends/debian/swupdate/bundle.nix` -- Nix-based bundle generator

### NVIDIA BSP (relevant to OTA)
- `backends/debian/meta-n3x/recipes-bsp/nvidia-l4t/nvidia-l4t-tools_36.4.4.bb` -- Provides nvbootctrl
- `backends/debian/versions.nix` -- L4T version pins

### Tests
- `tests/debian/swupdate-bundle-validation.nix`
- `tests/debian/swupdate-apply.nix`
- `tests/debian/swupdate-boot-switch.nix`
- `tests/debian/swupdate-network-ota.nix`

## References

- [NVIDIA R36.4 Update Mechanism](https://docs.nvidia.com/jetson/archives/r36.4/DeveloperGuide/SD/SoftwarePackagesAndTheUpdateMechanism.html)
- [NVIDIA R36.4.4 Update and Redundancy](https://docs.nvidia.com/jetson/archives/r36.4.4/DeveloperGuide/SD/Bootloader/UpdateAndRedundancy.html)
- [RidgeRun A/B Filesystem Redundancy Guide](https://developer.ridgerun.com/wiki/index.php/How_to_Use_A/B_Filesystem_Redundancy_and_OTA_with_NVIDIA_Jetpack)
- [SWUpdate Documentation](https://sbabic.github.io/swupdate/)
- [isar-cip-core SWUpdate Integration](https://gitlab.com/cip-project/cip-core/isar-cip-core)
- [jetpack-nixos](https://github.com/anduril/jetpack-nixos) -- NVIDIA BSP tooling for Nix
- [hawkBit](https://www.eclipse.org/hawkbit/) -- OTA fleet management
