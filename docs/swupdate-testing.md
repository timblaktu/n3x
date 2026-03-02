# SWUpdate VM Testing Guide

VM-based testing infrastructure for validating SWUpdate OTA functionality without physical hardware.

## Overview

The SWUpdate VM tests validate the complete OTA workflow in QEMU virtual machines:

| Test | Purpose | What It Validates |
|------|---------|-------------------|
| `test-swupdate-bundle-validation` | Bundle structure | sw-description parsing, checksums, hardware compatibility |
| `test-swupdate-apply` | Partition update | Writing ext4 image to inactive (APP_b) partition |
| `test-swupdate-boot-switch` | A/B switching | GRUB environment update and reboot into updated partition |
| `test-swupdate-network-ota` | Network update | Multi-VM setup with HTTP-served updates |

### What Can Be Tested in VMs

- SWUpdate parses .swu bundle structure
- Bundle checksum validation
- Raw handler writes ext4 to partition
- Post-update scripts execute
- GRUB environment modification for A/B switching
- Reboot into updated partition
- Rollback detection
- Network-based OTA pull from HTTP server

### What Requires Physical Hardware

- `nvbootctrl` commands (Tegra QSPI interface)
- Jetson A/B slot switching (requires actual bootloader)
- USB recovery mode flashing
- Hardware-specific firmware updates

## Prerequisites

1. **Build SWUpdate-enabled ISAR image**:
   ```bash
   nix develop --command kas-build \
     kas/base.yml:kas/machine/qemu-amd64.yml:kas/image/base.yml:kas/feature/swupdate.yml
   ```

2. **Register artifact in nix store** (if not already done):
   ```bash
   # Build and register via automated script
   nix run '.#isar-build-all' -- --variant base-swupdate
   git add lib/isar/artifact-hashes.nix
   ```

3. **Verify artifact is available**:
   ```bash
   nix eval '.#debianArtifacts.qemuamd64.swupdate.wic' --raw
   ```

## Running Tests

### Individual Tests

Run a single test (builds and executes):
```bash
# Bundle validation test
nix build '.#checks.x86_64-linux.test-swupdate-bundle-validation'

# Apply test
nix build '.#checks.x86_64-linux.test-swupdate-apply'

# Boot switch test
nix build '.#checks.x86_64-linux.test-swupdate-boot-switch'

# Network OTA test
nix build '.#checks.x86_64-linux.test-swupdate-network-ota'
```

### Interactive Mode

For debugging, run tests interactively:
```bash
# Build driver
nix build '.#test-swupdate-apply-driver'

# Run interactively
./result/bin/run-test-interactive
```

In interactive mode, you get a Python REPL where you can:
```python
# Start VM
testvm.start()

# Wait for boot
testvm.wait_for_unit("nixos-test-backdoor.service")

# Run commands
testvm.succeed("swupdate --version")
testvm.succeed("blkid")

# Check output without failing
result = testvm.execute("some_command")
print(f"Exit code: {result[0]}, Output: {result[1]}")

# Shutdown
testvm.shutdown()
```

### Full Test Suite

Run all SWUpdate tests:
```bash
nix flake check --print-build-logs 2>&1 | grep -E "(swupdate|PASS|FAIL)"
```

Note: Tests require KVM support. They will be skipped in sandboxed builds without `requiredSystemFeatures = [ "kvm" ]`.

## Test Architecture

### Image Requirements

The test images use the `kas/feature/swupdate.yml` overlay which provides:
- SWUpdate binary and configuration (`/etc/swupdate.cfg`)
- A/B partition layout (APP + APP_b + data)
- GRUB configuration for partition switching
- `grub-editenv` for modifying boot variables

### Partition Layout

```
GPT Disk Layout:
┌──────────┬───────────────┬───────────────┬──────────────────────┐
│ EFI      │ APP           │ APP_b         │ data                 │
│ (ESP)    │ (rootfs-a)    │ (rootfs-b)    │ (persistent)         │
│ 256MB    │ 2GB           │ 2GB           │ remaining            │
│ vfat     │ ext4          │ ext4          │ ext4                 │
│ /boot    │ / (active)    │ (inactive)    │ /data                │
└──────────┴───────────────┴───────────────┴──────────────────────┘
```

### A/B Switching Mechanism

Boot partition is controlled via GRUB environment variable `rootfs_slot`:
```bash
# Check current slot
grub-editenv /boot/efi/EFI/BOOT/grubenv list

# Switch to slot B
grub-editenv /boot/efi/EFI/BOOT/grubenv set rootfs_slot=b

# Switch back to slot A
grub-editenv /boot/efi/EFI/BOOT/grubenv set rootfs_slot=a
```

The GRUB config reads this variable to determine which partition to boot:
```grub
load_env -f /boot/efi/EFI/BOOT/grubenv
if [ "$rootfs_slot" == "b" ]; then
  set root_part=APP_b
else
  set root_part=APP
fi
```

## Adding New SWUpdate Tests

1. **Create test file** at `nix/tests/swupdate-<name>.nix`:
   ```nix
   { pkgs ? import <nixpkgs> { }
   , lib ? pkgs.lib
   }:

   let
     debianArtifacts = import ../debian-artifacts.nix { inherit pkgs lib; };
     mkDebianTest = pkgs.callPackage ../lib/mk-debian-test.nix { inherit pkgs lib; };

     test = mkDebianTest {
       name = "swupdate-<name>";

       machines = {
         testvm = {
           image = debianArtifacts.qemuamd64.swupdate.wic;
           memory = 2048;
           cpus = 2;
         };
       };

       testScript = ''
         testvm.wait_for_unit("nixos-test-backdoor.service")
         # Your test logic here
         print("Test PASSED")
       '';
     };
   in
   test
   ```

2. **Register in flake.nix**:
   - Add import in `swupdateTests` attribute set
   - Add `.test` to `checks.${system}`
   - Add `.driver` to `packages.${system}`

3. **Validate**:
   ```bash
   nix flake check
   nix build '.#test-swupdate-<name>-driver'
   ```

## Troubleshooting

### "nixos-test-backdoor.service" not found

The Debian backend image must include the test backdoor package. Verify:
```bash
# In the VM or extracted rootfs
systemctl status nixos-test-backdoor.service
```

If missing, ensure `kas/test-overlay.yml` is included in the build.

### Tests timeout waiting for boot

Common causes:
- Image doesn't have serial console configured
- Wrong QEMU machine type
- Missing kernel boot parameters

Check boot with verbose output:
```bash
# In interactive mode
testvm.start()
# Watch console output for errors
```

### KVM not available

Tests require KVM. Verify:
```bash
ls -la /dev/kvm
```

If running in WSL2, ensure nested virtualization is enabled.

### Partition not found by label

Verify partition labels in the image:
```bash
# Mount and check
sudo losetup -fP build/tmp/deploy/images/qemuamd64/*.wic
sudo blkid /dev/loop0*
```

### SWUpdate validation fails

Check sw-description syntax:
```bash
# In VM
swupdate -c -i /path/to/bundle.swu -v 2>&1
```

Common issues:
- Mismatched SHA256 checksums
- Hardware compatibility string mismatch
- Invalid libconfig syntax

## Related Documentation

- [Test Framework README](../tests/README.md) - NixOS test driver usage and test catalog
- [jetson-swupdate-and-ota.md](jetson-swupdate-and-ota.md) - Full OTA reference including SWUpdate, nv_update_engine, and Jetson integration

## Test File Reference

| File | Purpose |
|------|---------|
| `nix/tests/swupdate-bundle-validation.nix` | Validates .swu bundle parsing and checksums |
| `nix/tests/swupdate-apply.nix` | Tests writing update to APP_b partition |
| `nix/tests/swupdate-boot-switch.nix` | Tests A/B partition switching with reboot |
| `nix/tests/swupdate-network-ota.nix` | Tests multi-VM HTTP-based OTA |
| `nix/lib/mk-debian-test.nix` | Test framework for Debian backend images |
| `nix/debian-artifacts.nix` | Artifact registry (WIC image paths) |
| `kas/feature/swupdate.yml` | Kas overlay enabling SWUpdate |
| `meta-n3x/wic/sdimage-efi-ab.wks` | A/B partition layout template |
