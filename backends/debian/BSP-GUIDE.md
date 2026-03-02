# BSP Development Guide

This guide is for **Level 1 developers** who need to modify ISAR machine configurations, add BSP packages, or work with platform-specific recipes. For general ISAR build instructions, see [README.md](README.md).

## Overview

BSP (Board Support Package) development in n3x involves:

1. **Machine Configurations** - Hardware abstraction (`conf/machine/*.conf`)
2. **BSP Recipes** - Vendor packages (`recipes-bsp/`)
3. **Cross-Build Helpers** - Platform detection bypass (`.bbclass` files)
4. **kas Machine Overlays** - Build configuration (`kas/machine/*.yml`)

## Directory Structure

```
meta-n3x/
├── conf/
│   ├── layer.conf                      # Layer registration
│   ├── machine/                        # Machine-specific configs
│   │   ├── jetson-orin-nano.conf      # NVIDIA Jetson Orin Nano
│   │   └── amd-v3c18i.conf            # AMD V3000 series (Fox board)
│   └── multiconfig/                    # ISAR multiconfig targets
│       ├── jetson-orin-nano-trixie.conf
│       └── amd-v3c18i-trixie.conf
├── classes/
│   └── nvidia-l4t-cross-build.bbclass  # L4T platform detection bypass
├── recipes-bsp/
│   └── nvidia-l4t/                     # NVIDIA L4T BSP packages
│       ├── nvidia-l4t-core_36.4.4.bb   # L4T base platform support
│       └── nvidia-l4t-tools_36.4.4.bb  # Jetson tools (nvbootctrl, etc.)
└── recipes-kernel/
    ├── linux/                          # Kernel recipes
    │   ├── linux-tegra_6.12.69.bb     # Tegra234 kernel 6.12 LTS
    │   └── files/
    │       └── tegra234-enable.cfg    # Tegra234 Kconfig fragment
    └── nvidia-oot/                     # OOT modules (placeholder)
        └── README.md
```

## 1. Machine Configuration

Machine configurations define hardware properties for a target platform.

### File Location

```
meta-n3x/conf/machine/{machine-name}.conf
```

### Required Variables

| Variable | Purpose | Example |
|----------|---------|---------|
| `DISTRO_ARCH` | CPU architecture | `amd64`, `arm64` |
| `KERNEL_NAME` | Kernel arch prefix | `amd64`, `arm64` |
| `IMAGE_FSTYPES` | Output image formats | `wic`, `tar.gz` |
| `WKS_FILE` | Partition layout template | `efi-plus-pcbios` |
| `MACHINE_SERIAL` | Serial console device | `ttyS0`, `ttyTCU0` |
| `BAUDRATE_TTY` | Serial baud rate | `115200` |

### Example: AMD V3000 Series

See: `meta-n3x/conf/machine/amd-v3c18i.conf`

```bash
# AMD Ryzen Embedded V3C18I (Fox board)
DISTRO_ARCH ?= "amd64"
KERNEL_NAME ?= "amd64"
IMAGE_FSTYPES ?= "wic"
WKS_FILE ?= "efi-plus-pcbios"

# Serial console: UART0 on J38 connector maps to ttyS4
MACHINE_SERIAL ?= "ttyS4"
BAUDRATE_TTY ?= "115200"

# AMD microcode for security updates
IMAGE_PREINSTALL:append = " amd64-microcode"

# UEFI boot with GRUB
IMAGER_INSTALL:wic += "${GRUB_BOOTLOADER_INSTALL}"
```

### Example: Jetson Orin Nano

See: `meta-n3x/conf/machine/jetson-orin-nano.conf`

```bash
# NVIDIA Jetson Orin Nano (T234 SoC)
DISTRO_ARCH ?= "arm64"
KERNEL_NAME ?= "arm64"

# Output tar.gz for L4T flash integration (not WIC)
IMAGE_FSTYPES ?= "tar.gz"

# Tegra Combined UART
MACHINE_SERIAL ?= "ttyTCU0"
BAUDRATE_TTY ?= "115200"
```

**Key difference**: Jetson uses `tar.gz` instead of `wic` because the L4T flash tool handles partitioning.

### Adding a New Machine

1. **Create machine config**:
   ```bash
   # meta-n3x/conf/machine/my-board.conf
   DISTRO_ARCH ?= "amd64"  # or arm64
   KERNEL_NAME ?= "amd64"
   IMAGE_FSTYPES ?= "wic"
   WKS_FILE ?= "efi-plus-pcbios"
   MACHINE_SERIAL ?= "ttyS0"  # Check board documentation
   BAUDRATE_TTY ?= "115200"

   # Add any required firmware
   IMAGE_PREINSTALL:append = " firmware-package"
   ```

2. **Create multiconfig**:
   ```bash
   # meta-n3x/conf/multiconfig/my-board-trixie.conf
   MACHINE = "my-board"
   DISTRO = "debian-trixie"
   ```

3. **Create kas overlay**:
   ```yaml
   # kas/machine/my-board.yml
   header:
     version: 14
     includes:
       - ../base.yml

   machine: my-board
   distro: debian-trixie
   target: mc:my-board-trixie:isar-image-base
   ```

4. **Test the build**:
   ```bash
   nix develop
   cd backends/debian
   kas-build kas/base.yml:kas/machine/my-board.yml:kas/image/k3s-server.yml
   ```

## 2. Kernel Development

Kernel customization is a core BSP activity. ISAR provides the `linux-kernel` bbclass for building custom kernels as Debian packages.

### Kernel Configuration Methods

ISAR supports three complementary approaches:

| Method | Use Case | File Location |
|--------|----------|---------------|
| `KERNEL_DEFCONFIG` | Base config selection | In-tree or `recipes-kernel/linux/files/` |
| Configuration fragments (`.cfg`) | Modular tweaks | `recipes-kernel/linux/files/*.cfg` |
| Patches | Source modifications | `recipes-kernel/linux/files/*.patch` |

### Setting Kernel Config in Machine Files

Machine configurations set `KERNEL_NAME` which determines the kernel architecture:

```bash
# meta-n3x/conf/machine/amd-v3c18i.conf
KERNEL_NAME ?= "amd64"    # Uses Debian's linux-image-amd64

# meta-n3x/conf/machine/jetson-orin-nano.conf
KERNEL_NAME ?= "arm64"    # Uses Debian's linux-image-arm64
```

For custom kernels, override `KERNEL_DEFCONFIG` in the machine config or kas overlay:

```yaml
# kas/machine/my-board.yml
local_conf_header:
  kernel: |
    KERNEL_DEFCONFIG:my-board = "my_board_defconfig"
```

### Configuration Fragments

Use `.cfg` files for modular kernel config changes that don't require a full defconfig:

```bash
# recipes-kernel/linux/files/k3s-requirements.cfg
CONFIG_CGROUPS=y
CONFIG_CGROUP_CPUACCT=y
CONFIG_CGROUP_DEVICE=y
CONFIG_CGROUP_FREEZER=y
CONFIG_CGROUP_PIDS=y
CONFIG_NAMESPACES=y
CONFIG_NET_NS=y
CONFIG_PID_NS=y
CONFIG_IPC_NS=y
CONFIG_UTS_NS=y
```

Add fragments to a kernel recipe:

```bitbake
# recipes-kernel/linux/linux-custom.bb
SRC_URI += "file://k3s-requirements.cfg"
```

ISAR automatically applies `.cfg` files and verifies they took effect via `check_fragments_applied()`.

### Adding Kernel Patches

For kernel source modifications:

```bitbake
# recipes-kernel/linux/linux-custom.bb
SRC_URI += "file://0001-fix-driver-issue.patch"
```

Patch naming convention: `0001-short-description.patch` (numbered for ordering).

### Creating a Custom Kernel Recipe

For full kernel customization, create a new recipe:

```bitbake
# recipes-kernel/linux/linux-custom_6.12.bb

inherit linux-kernel

DESCRIPTION = "Custom kernel for my-board"

# Kernel source (tarball or git)
SRC_URI = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.tar.xz"
SRC_URI[sha256sum] = "abc123..."

# Or from git:
# SRC_URI = "git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git;branch=linux-6.12.y;protocol=https"
# SRCREV = "v6.12.1"

# Base configuration
KERNEL_DEFCONFIG = "x86_64_defconfig"

# Add fragments
SRC_URI += "file://k3s-requirements.cfg"
SRC_URI += "file://enable-vfio.cfg"

# Add patches
SRC_URI += "file://0001-my-driver-fix.patch"

# Version extension (shows in uname -r)
LINUX_VERSION_EXTENSION = "-custom"
```

The recipe produces these Debian packages:
- `linux-image-*` - Kernel binary and modules
- `linux-headers-*` - Headers for out-of-tree modules
- `linux-kbuild-*` - Build scripts for modules
- `linux-libc-dev` - Userland headers (optional)

### Building Out-of-Tree Kernel Modules

For kernel modules that build against an existing kernel:

```bitbake
# recipes-kernel/my-driver/my-driver.bb

inherit module

DESCRIPTION = "My out-of-tree kernel module"

SRC_URI = "file://my-driver.c file://Makefile"

# Module will be built against the target's kernel headers
```

The `module` class handles:
- Finding kernel headers from `linux-headers-*` package
- Building with correct `KERNELDIR`
- Installing to `/lib/modules/$(uname -r)/`

### Interactive Kernel Configuration

For `menuconfig` style configuration:

```bash
# Enter ISAR build environment
nix develop
cd backends/debian

# Enter kernel devshell with config applied
kas-shell kas/base.yml:kas/machine/my-board.yml -c "bitbake linux-custom -c devshell"

# Inside devshell:
make menuconfig
# Save changes, exit
make savedefconfig
# Copy to recipe files directory
```

### Firmware Packages

Firmware blobs are typically installed from Debian repositories:

```yaml
# kas/machine/my-board.yml
local_conf_header:
  firmware: |
    IMAGE_PREINSTALL:append = " firmware-linux-free firmware-misc-nonfree"
```

For CPU microcode (security-critical):

```bash
# For AMD:
IMAGE_PREINSTALL:append = " amd64-microcode"

# For Intel:
IMAGE_PREINSTALL:append = " intel-microcode"
```

### Key ISAR Kernel Variables

| Variable | Purpose | Default |
|----------|---------|---------|
| `KERNEL_DEFCONFIG` | Base kernel config | (required) |
| `KERNEL_NAME` | Kernel arch name (for Debian pkg) | From machine config |
| `LINUX_VERSION_EXTENSION` | Append to kernel version string | `""` |
| `KERNEL_FILE` | Kernel binary name | `vmlinuz` |
| `KERNEL_EXTRA_BUILDARGS` | Extra make arguments | `""` |
| `KERNEL_LIBC_DEV_DEPLOY` | Build linux-libc-dev | `"0"` |

### Kernel Debugging Tips

**Check applied config**:
```bash
# In target image or during build:
zcat /proc/config.gz | grep CONFIG_NAME

# Or check build output:
cat build/tmp/work/*/linux-*/*/linux-*/build/.config | grep CONFIG_NAME
```

**Verify fragments applied**:
ISAR logs warnings if `.cfg` entries didn't take effect - check BitBake output.

**Module loading issues**:
```bash
# Check module dependencies:
modinfo my-module.ko
depmod -a
modprobe my-module
dmesg | tail -20
```

### Reference: Existing Kernel Recipes

ISAR provides example recipes in `isar/meta-isar/recipes-kernel/linux/`:

| Recipe | Version | Use Case |
|--------|---------|----------|
| `linux-mainline` | 6.12 | Generic x86_64/arm64 |
| `linux-cip` | 4.4 | Long-term stability |
| `linux-starfive` | 6.6 | StarFive RISC-V boards |

### Kernel Development Workflow

1. **Start with Debian kernel** - Use `KERNEL_NAME` from machine config
2. **Add fragments** - For small config changes (enable features)
3. **Add patches** - For driver fixes or backports
4. **Custom recipe** - Only if fragments/patches aren't enough

Quick test cycle:
```bash
nix develop
cd backends/debian

# Rebuild kernel package only:
kas-shell kas/base.yml:kas/machine/my-board.yml -c "bitbake linux-custom -c clean && bitbake linux-custom"

# Rebuild full image:
kas-build kas/base.yml:kas/machine/my-board.yml:kas/image/k3s-server.yml

# Test boot:
nix build '.#checks.x86_64-linux.debian-vm-boot' -L
```

---

## 3. BSP Recipe Patterns

BSP recipes package vendor-provided binaries or platform-specific software.

### Pattern: dpkg-prebuilt (Vendor Binaries)

Use `dpkg-prebuilt` for vendor packages distributed as `.deb` files.

See: `meta-n3x/recipes-bsp/nvidia-l4t/nvidia-l4t-core_36.4.4.bb`

```bitbake
# Key elements of a dpkg-prebuilt recipe:

inherit dpkg-prebuilt

# Restrict to compatible machines
COMPATIBLE_MACHINE = "jetson-orin-.*"

# Source from vendor repository
SRC_URI = "https://repo.download.nvidia.com/jetson/t234/pool/main/n/nvidia-l4t-core/nvidia-l4t-core_36.4.4-20241219171030_arm64.deb"
SRC_URI[sha256sum] = "04975607d121dd679a9f026939d5c126d5c6b71c01942212ebc2b090..."

# Dependencies
DEPENDS = "nvidia-l4t-init"
```

**Critical points**:
- Always include SHA256 checksum for reproducibility
- Use `COMPATIBLE_MACHINE` to prevent accidental builds on wrong platforms
- Version numbers should match vendor releases (e.g., 36.4.4 = JetPack 6.2)

### Finding Vendor Package URLs

For NVIDIA L4T:
1. Browse: https://repo.download.nvidia.com/jetson/
2. Select SoC family: `t234/` for Orin, `t194/` for Xavier
3. Navigate: `pool/main/{first-letter}/{package-name}/`

For version tracking, cross-reference with:
- `jetpack-nixos` sourceinfo files (maintained hashes)
- NVIDIA JetPack release notes

### Recipe Versioning

Recipe filename format: `{package}_{version}.bb`

When updating L4T version:
1. Update both `nvidia-l4t-core` and `nvidia-l4t-tools` recipes
2. Verify SHA256 checksums
3. Update `COMPATIBLE_MACHINE` if SoC family changes
4. Test with L1 boot test before L3/L4 cluster tests

## 4. Cross-Build Helpers

When building for ARM on x86 (or vice versa), some packages fail due to platform detection that expects to run on the target.

### The Problem

Vendor packages often check `/proc/device-tree/compatible` or run platform-specific commands in their `preinst` scripts. These fail in the cross-build chroot because:
- The chroot doesn't have the target's device tree
- Binaries can't execute natively

### Solution Pattern: Marker Files + Validation

See: `meta-n3x/classes/nvidia-l4t-cross-build.bbclass`

The pattern:
1. **Early hook** (before package install): Create marker file to skip platform checks
2. **Late hook** (after package install): Validate required binaries exist

```bitbake
# Create marker before package installation (weight=100, before pkg install at weight=8000)
rootfs_create_l4t_marker[weight] = "100"
rootfs_create_l4t_marker() {
    mkdir -p "${ROOTFSDIR}/opt/nvidia/l4t-packages"
    touch "${ROOTFSDIR}/opt/nvidia/l4t-packages/.nv-l4t-disable-boot-fw-update-in-preinstall"
}

# Validate after installation
rootfs_validate_l4t_binaries() {
    for binary in nvbootctrl tegrastats jetson_clocks; do
        # Search standard binary locations
        for dir in bin sbin usr/bin usr/sbin; do
            if [ -x "${ROOTFSDIR}/${dir}/${binary}" ]; then
                found=1
                break
            fi
        done
        if [ -z "$found" ]; then
            bbfatal "Required L4T binary not found: ${binary}"
        fi
    done
}
```

### When to Create a bbclass

Create a new `.bbclass` when:
- Multiple recipes need the same cross-build workaround
- Vendor preinst/postinst scripts fail in chroot
- Platform detection prevents package installation

### Adding a New bbclass

1. **Create the class file**:
   ```bash
   # meta-n3x/classes/my-vendor-cross-build.bbclass
   ```

2. **Define hooks with appropriate weights**:
   - Weight < 100: Before most ISAR operations
   - Weight 8000: Package installation happens here
   - Weight > 8000: After package installation

3. **Include in kas overlay**:
   ```yaml
   local_conf_header:
     my-vendor: |
       INHERIT += "my-vendor-cross-build"
   ```

## 5. kas Machine Overlays

kas overlays configure BitBake without modifying recipes.

### Overlay Structure

```yaml
# kas/machine/jetson-orin-nano.yml
header:
  version: 14
  includes:
    - ../base.yml

machine: jetson-orin-nano
distro: debian-trixie
target: mc:jetson-orin-nano-trixie:isar-image-base

local_conf_header:
  jetson-orin-nano: |
    # Cross-compilation enabled by default (ISAR_CROSS_COMPILE ??= "1")
    # Uses host cross-toolchain for kernel and other compiled packages
    # L4T prebuilt .deb packages handled by nvidia-l4t-cross-build marker

    # Add BSP packages
    IMAGE_INSTALL:append = " nvidia-l4t-core nvidia-l4t-tools"

    # Enable cross-build helper class (creates marker to bypass L4T
    # preinst hardware detection during chroot-based builds)
    INHERIT += "nvidia-l4t-cross-build"
```

### Key Variables for BSP

| Variable | Purpose | Example |
|----------|---------|---------|
| `ISAR_CROSS_COMPILE` | Enable/disable cross-compilation | `"1"` (default, recommended) |
| `IMAGE_INSTALL:append` | Add ISAR-built packages | `" nvidia-l4t-core"` |
| `IMAGE_PREINSTALL:append` | Add Debian packages | `" firmware-misc"` |
| `INHERIT` | Include bbclass files | `"nvidia-l4t-cross-build"` |

### Machine vs. Feature Overlays

- **Machine overlays** (`kas/machine/`): Hardware-specific, one per board
- **Feature overlays** (`kas/feature/`): Optional features, composable

Example composition:
```bash
kas-build kas/base.yml:kas/machine/jetson-orin-nano.yml:kas/image/k3s-server.yml:kas/feature/swupdate.yml
```

## 6. BSP Testing

Test BSP changes incrementally from boot to cluster.

### Test Progression

| Layer | Test | What It Validates | Command |
|-------|------|-------------------|---------|
| **L1** | VM Boot | Kernel, rootfs, serial console | `nix build '.#checks.x86_64-linux.debian-vm-boot'` |
| **L2** | Network | NICs, drivers, connectivity | `nix build '.#checks.x86_64-linux.debian-two-vm-network'` |
| **L3** | Service | K3s starts, dependencies met | `nix build '.#checks.x86_64-linux.debian-service'` |
| **L4** | Cluster | Multi-node, HA formation | `nix build '.#checks.x86_64-linux.debian-cluster-simple'` |

### BSP-Specific Validation

For machine config changes:
1. **Verify serial console**: Check `MACHINE_SERIAL` in boot logs
2. **Verify firmware**: Check `/lib/firmware/` contents
3. **Verify bootloader**: Check EFI partition layout

For BSP package changes:
1. **Verify package installed**: `dpkg -l | grep package-name`
2. **Verify binaries present**: Check expected paths
3. **Verify services start**: `systemctl status service-name`

### Quick Iteration Workflow

```bash
# 1. Enter ISAR shell
nix develop
cd backends/debian

# 2. Build image with your changes
kas-build kas/base.yml:kas/machine/my-board.yml:kas/packages/k3s-core.yml:kas/packages/debug.yml:kas/image/k3s-server.yml:kas/boot/grub.yml:kas/network/simple.yml:kas/node/server-1.yml

# 3. Run L1 boot test (fastest feedback)
# Update debian-artifacts.nix with new hash first
nix build '.#checks.x86_64-linux.debian-vm-boot' -L

# 4. If L1 passes, run L3 service test
nix build '.#checks.x86_64-linux.debian-service' -L
```

### Debugging Failed Boots

If L1 fails:
1. Check kernel command line in `kas/boot/*.yml`
2. Verify serial console device matches hardware
3. Check `IMAGE_FSTYPES` and `WKS_FILE` are appropriate

```bash
# Inspect built image
cd build/tmp/deploy/images/{machine}/
file *.wic  # Check image type
fdisk -l *.wic  # Check partition layout
```

## 7. Reference: Key Files

### Machine Configurations
- `meta-n3x/conf/machine/jetson-orin-nano.conf` - Jetson Orin Nano
- `meta-n3x/conf/machine/amd-v3c18i.conf` - AMD V3000 Fox board

### BSP Recipes
- `meta-n3x/recipes-bsp/nvidia-l4t/nvidia-l4t-core_36.4.4.bb` - L4T core
- `meta-n3x/recipes-bsp/nvidia-l4t/nvidia-l4t-tools_36.4.4.bb` - Jetson tools

### Kernel Recipes
- `meta-n3x/recipes-kernel/linux/linux-tegra_6.12.69.bb` - Tegra234 kernel 6.12 LTS
- `meta-n3x/recipes-kernel/linux/files/tegra234-enable.cfg` - Tegra234 Kconfig fragment

### Cross-Build Helpers
- `meta-n3x/classes/nvidia-l4t-cross-build.bbclass` - L4T platform bypass

### kas Overlays
- `kas/machine/jetson-orin-nano.yml` - Jetson build config (includes kernel overlay)
- `kas/kernel/tegra-6.12.yml` - Custom Tegra kernel selection
- `kas/machine/qemu-amd64.yml` - QEMU x86_64 (testing)

### Layer Configuration
- `meta-n3x/conf/layer.conf` - Layer registration and dependencies

## 8. Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| `COMPATIBLE_MACHINE` mismatch | Recipe restricted to different machine | Check regex in recipe, update if needed |
| preinst fails in chroot | Platform detection during cross-build | Create bbclass with marker file pattern |
| Package not found | Missing from `IMAGE_INSTALL` | Add to kas overlay: `IMAGE_INSTALL:append` |
| Wrong serial output | Incorrect `MACHINE_SERIAL` | Check board documentation for UART mapping |
| Image too large | Missing size constraints | Check `WKS_FILE` has appropriate sizes |

## 9. Jetson Orin Nano Flash Workflow

The Jetson Orin Nano uses NVIDIA's L4T flash tools instead of standard GRUB/WIC boot. The ISAR build produces a rootfs tarball that integrates into the L4T BSP flash workflow.

### Build Output

The Jetson machine config sets `IMAGE_FSTYPES = "tar.gz"` (not WIC). The ISAR build produces:

```
build/tmp/deploy/images/jetson-orin-nano/isar-image-*.tar.gz
```

This tarball contains the complete root filesystem including:
- Custom kernel Image and modules (`/boot/`, `/lib/modules/`)
- Device tree blobs (`/boot/dtbs/`)
- L4T BSP packages (nvidia-l4t-core, nvidia-l4t-tools)
- Application packages (k3s, etc.)

### Flash Procedure

Prerequisites: NVIDIA L4T BSP downloaded and extracted (Linux_for_Tegra directory).

```bash
# 1. Extract ISAR rootfs into L4T staging area
sudo tar xf build/tmp/deploy/images/jetson-orin-nano/isar-image-*.tar.gz \
    -C Linux_for_Tegra/rootfs/

# 2. Apply NVIDIA binary overlay (firmware, bootloader configs)
cd Linux_for_Tegra
sudo ./apply_binaries.sh

# 3. Flash device (USB recovery mode required)
# For NVMe SSD:
sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
    jetson-orin-nano-devkit internal

# For SD card:
sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
    jetson-orin-nano-devkit mmcblk0p1
```

### Custom Kernel Integration

When using the linux-tegra 6.12 LTS recipe (via `kas/kernel/tegra-6.12.yml`):

- **Kernel Image**: Installed to rootfs `/boot/Image` by the linux-image Debian package. L4T flash tools pick it up from rootfs during `apply_binaries.sh`.
- **Modules**: Installed to `/lib/modules/6.12.69-tegra/` by the linux-image package.
- **DTB handling**: The upstream mainline DTB (`nvidia/tegra234-p3767-0003-p3768-0000-a0.dtb`) is built from the kernel source. L4T flash tools may overlay or replace with NV-platform DTBs depending on flash configuration. For initial bring-up, the mainline DTB should be used to validate driver support.

### NixOS vs ISAR Flash Comparison

| Aspect | NixOS Backend | ISAR Backend |
|--------|--------------|--------------|
| Kernel source | jetpack-nixos (L4T 5.15) | linux-tegra (mainline 6.12) |
| Flash tool | jetpack-nixos flash scripts | L4T l4t_initrd_flash.sh |
| Image format | NixOS system closure | Debian rootfs tarball |
| Bootloader | L4T UEFI (EDK2) | L4T UEFI (EDK2) |
| DTB source | jetpack-nixos overlay DTBs | Mainline kernel DTBs |

Both backends use the same L4T bootloader chain (MB1 → MB2 → UEFI/EDK2 → kernel). The difference is in rootfs packaging and kernel source.

### Future: Automated Flash

The flash workflow is currently manual. Future automation could:
- Wrap `l4t_initrd_flash.sh` in a kas/Nix task
- Automate USB recovery mode detection
- CI-triggered flash for hardware-in-the-loop testing

This is tracked as out-of-scope for the initial kernel integration.

## See Also

- [README.md](README.md) - General Debian backend documentation
- [packages/README.md](packages/README.md) - Application package development (Level 0)
- [../../tests/README.md](../../tests/README.md) - Test infrastructure documentation
- [../../docs/jetson-orin-nano-kernel6-analysis-revised.md](../../docs/jetson-orin-nano-kernel6-analysis-revised.md) - Kernel 6.12 analysis
