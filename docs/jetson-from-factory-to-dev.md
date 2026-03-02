# Jetson Orin Nano: From Factory to Developer

This guide takes a brand-new Jetson Orin Nano 8GB developer kit from factory-sealed box to a productive kernel, firmware, or Debian package development environment using the n3x ISAR/Debian backend.

## What's in the Box

The Jetson Orin Nano 8GB developer kit ships with:

- Jetson Orin Nano 8GB module (P3767-0003) pre-attached to carrier board (P3768)
- Carrier board with M.2 Key-M (NVMe) and M.2 Key-E (WiFi) slots
- Heatsink with fan (pre-assembled)
- 19V DC power supply with regional power cords
- M.2 Key-E wireless module (pre-installed)

**Not included**: No microSD card, no NVMe SSD, no display cable, no USB keyboard/mouse. You must supply an NVMe SSD (recommended) or microSD card for the OS.

**Factory firmware state**: The QSPI-NOR flash on the module ships with firmware from the manufacturing date. Early units (2023) ship with L4T R35.x or older. This firmware is NOT compatible with JetPack 6.x (L4T R36.x). You must update QSPI firmware before running any JetPack 6.x rootfs — including the one built by this project.

## Prerequisites

### Hardware You Need to Provide

- **NVMe SSD** (recommended): The dev kit has two M.2 Key-M slots — one for 2280 (PCIe 3.0 x4) and one for 2230 (PCIe 3.0 x2). An NVMe drive is strongly recommended over microSD for build/development work due to vastly better I/O performance.
- **USB-C cable**: Connects the dev kit's USB-C port to your host machine (required for initial flash).
- **Ethernet cable**: For network connectivity after boot (SSH access, package downloads).
- **Serial console adapter** (optional but strongly recommended): A USB-to-UART adapter connected to the J14 header on the carrier board. The Jetson Orin Nano uses Tegra Combined UART (`ttyTCU0`) at 115200 baud. This gives you kernel boot logs and a login shell independent of network connectivity.

### Host Machine Requirements

This guide assumes your build host is **NixOS on WSL2**. The build process uses ISAR inside a podman container, orchestrated by kas. The Nix development shell provides all required tools.

**WSL2 USB passthrough**: USB device forwarding from Windows to WSL requires [usbipd-win](https://github.com/dorssel/usbipd-win) on the Windows host and USB/IP support in the WSL NixOS configuration.

- **Windows side**: Install usbipd-win if not already present: `winget install usbipd` (from admin PowerShell). This is the only manual Windows-side prerequisite.
- **NixOS side**: The `wsl` module in `nixcfg` provides declarative USB/IP configuration — `usbip.enable` (on by default), `usbip.autoAttach` (host-specific bus IDs), and udev rules for device permissions/symlinks. See `modules/hosts/thinky-nixos/thinky-nixos.nix` in `nixcfg` for a complete example with ESP32 serial devices. Utility scripts (`restart-usb`, `restart-usb-v4.ps1`) for USB reset/re-enumeration are deployed via the Home Manager `system-tools` module.
- **Jetson-specific udev rules**: Add rules for the NVIDIA Recovery Mode device (VID `0955`, PID `7523`) and your USB-to-UART serial adapter to your host's NixOS configuration.

### Install the NVMe SSD

Before powering on the dev kit for the first time:

1. Remove the two screws on the heatsink/fan assembly
2. Carefully lift the heatsink to access the M.2 Key-M slot
3. Insert your NVMe SSD at a ~30° angle and press down
4. Secure with the M.2 standoff screw
5. Replace the heatsink

## Phase 1: Update QSPI Firmware

The QSPI-NOR flash on the Jetson module stores the boot chain: MB1 → MB2 → UEFI/EDK2. Factory firmware must be updated to L4T R36.x before you can boot a JetPack 6.x rootfs.

### Check Current Firmware (if the device already boots)

If the device boots to an existing OS (factory Ubuntu or previous install), check the firmware version:

```bash
# On the Jetson itself:
sudo nvbootctrl dump-slots-info 2>&1 | head -5

# Or check the L4T version:
cat /etc/nv_tegra_release
dpkg -l | grep nvidia-l4t-core
```

If the version shows R36.x (e.g., 36.4.0 or later), skip to Phase 2. If it shows R35.x or you can't determine the version, proceed with the firmware update.

### Option A: SD Card Bootstrap (No Host PC USB Required)

This is a two-stage process that updates QSPI firmware using SD card images.

**Stage 1 — Update to firmware R35.5.0 via JetPack 5.1.3:**

1. Download the JetPack 5.1.3 SD card image from [NVIDIA's Jetson Downloads](https://developer.nvidia.com/embedded/jetpack-archive) (`JP513-orin-nano-sd-card-image_b29.zip` — use the May 2024 updated image)
2. Flash to a microSD card using [Balena Etcher](https://etcher.balena.io/) or `dd`
3. Insert into the Orin Nano, connect power
4. The first boot runs Ubuntu. The `nvidia-l4t-bootloader` package triggers a QSPI firmware update automatically on the next reboot
5. Reboot. Watch serial console for firmware update messages. Verify firmware is now R35.5.0

**Stage 2 — Update QSPI for JetPack 6.x compatibility:**

Still running JetPack 5.1.3 from Stage 1:

```bash
# Install the QSPI updater package
sudo apt-get update
sudo apt-get install nvidia-l4t-jetson-orin-nano-qspi-updater

# Reboot to apply QSPI update
sudo reboot
```

The QSPI update runs during boot (visible on serial console). After completion, the device reboots but will NOT boot from the 5.1.3 SD card — this is expected. The QSPI is now ready for JetPack 6.x.

**Stage 3 — (Optional) Verify with JetPack 6.x SD card image:**

Before building a custom image, you can verify the firmware update worked by booting a stock JetPack 6.x SD card image from [NVIDIA's downloads page](https://developer.nvidia.com/embedded/jetpack/downloads). This step is optional if you plan to flash directly with the n3x ISAR image.

### Option B: SDK Manager (Full GUI, Host PC Required)

NVIDIA SDK Manager handles everything in one pass — firmware, rootfs, and SDK components. This requires an x86_64 Ubuntu 20.04/22.04 host with a GUI (not WSL).

1. Install [NVIDIA SDK Manager](https://developer.nvidia.com/sdk-manager/download)
2. Log in with your NVIDIA Developer account
3. Put the Jetson into USB Recovery Mode (see next section)
4. Connect USB-C cable from Jetson to Ubuntu host
5. Launch SDK Manager, select "Jetson Orin Nano Developer Kit" and JetPack 6.2
6. For Super mode: select `jetson-orin-nano-devkit-super.conf` board configuration
7. Choose NVMe as target storage
8. Flash — SDK Manager downloads BSP, flashes QSPI firmware AND rootfs in one operation

### Option C: Manual L4T Flash (Command Line, Updates Everything)

This is the same tool used by the n3x flash scripts. It updates both QSPI firmware and rootfs in one operation. See Phase 3 below — if your firmware is outdated, the `l4t_initrd_flash.sh` command updates it as part of the flash process.

### USB Recovery Mode Procedure

USB Recovery Mode is required for any host-based flashing (Options B and C). The carrier board's button/jumper header is **J14** — a 12-pin header on the edge of the board near the SD card slot.

**J14 header pinout** (complete 12-pin):

| Pins | Signal | Voltage | Function |
|------|--------|---------|----------|
| 1-2 | PC_LED- / PC_LED+ | 5V | Power LED control |
| 3-4 | UART2_TXD / UART2_RXD | 3.3V | Debug serial console |
| 5-6 | AC_OK / GND | — | Auto-power-on disable |
| 7-8 | SYS_RESET / GND | — | System reset |
| 9-10 | FC_REC / GND | — | Force Recovery mode |
| 11-12 | PWR_BTN / GND | — | Power button |

**Serial console wiring**: Connect your USB-to-UART adapter to pins 3 (TXD — data FROM Jetson), 4 (RXD — data TO Jetson), and any GND pin (6, 8, 10, or 12). Cross-connect: Jetson TXD → adapter RXD, Jetson RXD → adapter TXD.

> **Warning**: The UART pins are **3.3V logic**. Do NOT use a 5V serial adapter — it will damage the Jetson's UART. Use a 3.3V adapter such as an FTDI TTL-232R-3V3 or Silicon Labs CP2102.

**Method 1 — Jumper wire (most common for dev kits):**

1. Power off completely (disconnect DC power)
2. Connect USB-C cable from Jetson to host
3. Place a jumper wire between **pin 9 (FC_REC)** and **pin 10 (GND)** on J14
4. Connect the 19V DC power — the board powers on and enters Recovery Mode
5. Verify on host: `lsusb | grep -i nvidia` → should show `0955:7523 NVIDIA Corp. APX`
6. **Remove the jumper** before proceeding with flash

**Method 2 — With buttons soldered to J14:**

1. Power on the board
2. Hold the RECOVERY button (pins 9-10)
3. While holding RECOVERY, press and release RESET (pins 7-8)
4. Release RECOVERY
5. Verify with `lsusb`

**WSL2 USB passthrough**:

If your NixOS host config includes the Jetson's bus ID in `usbip.autoAttach`, the device attaches automatically when plugged in. Otherwise, attach manually from PowerShell (Administrator):

```powershell
# List USB devices and find the NVIDIA device (0955:7523)
usbipd list

# Bind and attach to WSL
usbipd bind --busid <BUSID>
usbipd attach --wsl --busid <BUSID>
```

If USB devices aren't detected after a sleep/wake cycle or USB bus glitch, use the NixOS-managed `restart-usb` utility (available if your HM config includes the `system-tools` module). It automates the 7-phase USB reset process (stop usbipd, clear cache, reset controllers, restart, re-enumerate, re-attach).

**Note**: If using a USB-to-UART serial adapter for console access, it also needs to be forwarded via `usbipd bind/attach` — the same process as the Jetson Recovery device. Both the Jetson and the serial adapter are separate USB devices on distinct bus IDs.

Verify in WSL:

```bash
lsusb | grep -i nvidia
# Expected: Bus XXX Device YYY: ID 0955:7523 NVIDIA Corp. APX
```

### About "Super" Mode

"Super" is a software/firmware unlock, not a hardware change. Any Orin Nano 8GB can become "Super" by flashing JetPack 6.2+ firmware. The unlock enables higher GPU clocks (625→1020 MHz), higher CPU clocks (1.5→1.7 GHz), increased memory bandwidth (68→102 GB/s), and a new 67 TOPS AI performance mode.

For Super mode, use the `jetson-orin-nano-devkit-super` board configuration when flashing:

```bash
# Flash with Super config (enables MAXN SUPER power mode)
sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
    jetson-orin-nano-devkit-super internal
```

After booting, enable Super performance:

```bash
sudo nvpmodel -m 2    # MAXN SUPER mode
sudo jetson_clocks     # Lock clocks at maximum
```

## Phase 2: Build the ISAR Image

### Enter the Development Shell

```bash
cd /home/tim/src/n3x-hwdev
nix develop
```

This provides `kas-build`, `kas`, `podman`, and all required tools. The shell auto-detects podman and exports `KAS_CONTAINER_ENGINE=podman`.

### Build the Base Image

For initial baseline validation, build the base image with debug packages (SSH access):

```bash
cd backends/debian
kas-build kas/base.yml:kas/machine/jetson-orin-nano.yml:kas/packages/debug.yml:kas/image/base.yml
```

**What this command does**: The kas overlays compose into a single BitBake configuration:

- `base.yml` — ISAR framework, mirrors, parallelism settings, compression
- `machine/jetson-orin-nano.yml` — Jetson machine config. Automatically includes `kernel/tegra-6.12.yml` (custom kernel). The machine conf (`meta-n3x/conf/machine/jetson-orin-nano.conf`) sets `IMAGE_FSTYPES = "tar.gz"` — rootfs tarball, not WIC disk image. The kas overlay also adds `nvidia-l4t-core` and `nvidia-l4t-tools` packages and enables the `nvidia-l4t-cross-build` bbclass for cross-compilation
- `packages/debug.yml` — Adds openssh-server, vim-tiny, less, iputils-ping, and SSH key regeneration service. Required for SSH access after boot
- `image/base.yml` — Selects the `n3x-image-base` recipe (minimal Debian Trixie). Includes `packages/root-login.yml` which sets root password to `root`

**Cross-compilation**: The build runs on your x86_64 host and cross-compiles for arm64 automatically. ISAR's default `ISAR_CROSS_COMPILE = "1"` uses the host's cross-toolchain for compilation-heavy tasks (like the kernel), while prebuilt L4T `.deb` packages install via the `nvidia-l4t-cross-build` marker mechanism.

**Build output**:

```
backends/debian/build/tmp/deploy/images/jetson-orin-nano/n3x-image-base-debian-trixie-jetson-orin-nano.tar.gz
```

This tarball contains the complete root filesystem:

- Custom kernel 6.12.69-tegra (`/boot/Image`, `/lib/modules/6.12.69-tegra/`)
- Device tree blobs (`/boot/dtbs/nvidia/tegra234-*.dtb`)
- L4T BSP packages (`nvbootctrl`, `tegrastats`, `jetson_clocks`)
- Debian Trixie minimal rootfs with openssh-server
- Root login enabled (password: `root`)

**First build**: Expect 30-60+ minutes with no sstate cache. The kernel cross-compile alone takes ~22 minutes. Subsequent builds with cache are much faster.

### (Alternative) Build the Server Image

If you want K3s Kubernetes pre-installed:

```bash
kas-build kas/base.yml:kas/machine/jetson-orin-nano.yml:kas/packages/k3s-core.yml:kas/packages/debug.yml:kas/image/k3s-server.yml
```

This adds K3s, iptables, conntrack, iproute2, and other k3s runtime dependencies. For initial kernel development baseline validation, the base image is sufficient.

### Troubleshooting Build Issues

**Stale `.git-downloads` symlink** (if you've built before):

```bash
rm -f backends/debian/build/tmp/work/debian-trixie-arm64/.git-downloads
```

**Cross-arch download cache collision** (if you previously built x86_64 images):

```bash
rm -f ~/.cache/yocto/downloads/k3s ~/.cache/yocto/downloads/k3s.done
```

**Container engine issues**: The `kas-build` wrapper auto-detects podman or docker. If detection fails, export manually:

```bash
export KAS_CONTAINER_ENGINE=podman
```

## Phase 3: Flash the Image to the Jetson

The Jetson Orin Nano does not use WIC disk images. Instead, ISAR produces a rootfs tarball that integrates into NVIDIA's L4T BSP flash workflow. The L4T flash tools handle partitioning, bootloader installation, and firmware updates.

### Download the L4T BSP (One-Time Setup)

The L4T BSP version must match the L4T packages in the build. This project uses L4T R36.4.4.

```bash
# Create a dedicated directory for BSP files (outside the project tree)
mkdir -p ~/jetson-bsp && cd ~/jetson-bsp

# Download L4T R36.4.4 BSP (update URL if version changes)
# Check backends/debian/versions.nix for the current L4T version
wget https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.4/release/Jetson_Linux_R36.4.4_aarch64.tbz2

# Extract
tar xf Jetson_Linux_R36.4.4_aarch64.tbz2
# Creates: ~/jetson-bsp/Linux_for_Tegra/
```

You do NOT need NVIDIA's sample rootfs — the ISAR build provides the rootfs.

### Prepare the Rootfs

```bash
# Clear any existing rootfs content
sudo rm -rf Linux_for_Tegra/rootfs/*

# Extract the ISAR-built rootfs tarball
sudo tar xf backends/debian/build/tmp/deploy/images/jetson-orin-nano/n3x-image-base-debian-trixie-jetson-orin-nano.tar.gz \
    -C Linux_for_Tegra/rootfs/

# Apply NVIDIA binary overlay (firmware blobs, bootloader configs, nv scripts)
cd Linux_for_Tegra
sudo ./apply_binaries.sh
```

`apply_binaries.sh` copies NVIDIA-proprietary files into the rootfs that are NOT available as `.deb` packages. This step is required even though the ISAR image already includes `nvidia-l4t-core` and `nvidia-l4t-tools` — the debs and the script provide different things with minimal overlap:

| Component | Source | Provides |
|-----------|--------|----------|
| nvidia-l4t-core .deb | ISAR build | Platform detection, nv_boot_control.conf, base L4T config |
| nvidia-l4t-tools .deb | ISAR build | nvbootctrl, tegrastats, jetson_clocks userspace tools |
| apply_binaries.sh | L4T BSP archive | Proprietary GPU drivers, firmware blobs, UEFI config files, device tree overlays, hardware abstraction libraries |

> **Note**: `apply_binaries.sh` may emit warnings on non-Ubuntu rootfs (e.g., Debian Trixie) if expected packages or paths differ. These warnings are generally non-fatal — verify by checking that `/usr/lib/aarch64-linux-gnu/tegra/` is populated after the script runs.

### Flash

Put the Jetson in USB Recovery Mode (see Phase 1), then:

```bash
# For NVMe SSD (most common on dev kit):
sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
    jetson-orin-nano-devkit internal

# For Super mode:
sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
    jetson-orin-nano-devkit-super internal

# For SD card instead of NVMe:
sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
    jetson-orin-nano-devkit mmcblk0p1
```

**What `l4t_initrd_flash.sh` does**: It's a two-stage process. First, it uses the USB Recovery Mode (RCM) protocol to push a minimal Linux kernel + initrd into the Jetson's RAM and boots it. This tiny Linux environment then exposes the Jetson's storage devices (NVMe, SD) back to the host over USB. The host writes partition images directly to the exposed block devices. Both QSPI firmware and external storage are flashed in parallel.

### Verifying Flash Success

**Successful flash**: `l4t_initrd_flash.sh` prints partition write progress for each partition, ending with `Flashing succeeded`. The Jetson reboots automatically.

**Serial console verification**: If you have a serial adapter connected to J14, watch for the boot chain: MB1 → MB2 → UEFI/EDK2 initialization → kernel decompression → systemd targets → login prompt. A successful boot from factory to login prompt confirms both QSPI firmware and rootfs are correctly installed.

**Common failures**:

- **USB disconnect mid-flash**: Re-enter Recovery Mode and re-flash. The Jetson's QSPI is resilient — a partial QSPI write does not brick the device.
- **Wrong board config name**: Verify the exact string matches your board variant (e.g., `jetson-orin-nano-devkit` vs `jetson-orin-nano-devkit-super`). The flash tool lists available configs in `bootloader/generic/cfg/`.
- **Power loss during flash**: Recovery Mode still works — re-enter via J14 jumper and re-flash.
- **"ERROR: might be timeout" during USB expose**: The initrd-based flash requires a stable USB connection. Try a different USB-C cable or port. On WSL, ensure the device stays attached via usbipd throughout the entire flash process.

### Alternative: Nix-Generated Flash Script

The project includes a Nix wrapper that automates the flash process using jetpack-nixos:

```bash
# First, register the build artifact in the nix store
# (from the n3x-hwdev root, not backends/debian)
cd /home/tim/src/n3x-hwdev
nix run '.' -- --variant base --machine jetson-orin-nano --rename-existing
# Valid --machine values: qemuamd64, qemuarm64, jetson-orin-nano, amd-v3c18i
# (defined in lib/debian/build-matrix.nix)

# Build the flash script
nix build '.#jetson-flash-script-base'

# Run it (Jetson must be in USB Recovery Mode)
sudo ./result/bin/flash-jetson
```

This approach packages the entire L4T BSP + rootfs integration into a single reproducible Nix derivation. It requires the rootfs tarball to be registered in the Nix store first (via `isar-build-all`).

## Phase 4: Boot and Connect

After flashing, the Jetson reboots automatically. The boot chain is:

```
QSPI: MB1 → MB2 → UEFI/EDK2 → kernel (6.12.69-tegra) → systemd → login
```

### Serial Console (Recommended)

If you have a USB-to-UART adapter connected to J14 on the carrier board:

```bash
# On your host:
minicom -D /dev/ttyUSB0 -b 115200
# Or:
screen /dev/ttyUSB0 115200
# Or:
picocom -b 115200 /dev/ttyUSB0
```

The Jetson's serial console is on `ttyTCU0` (Tegra Combined UART). You should see the full boot sequence and a login prompt.

> **Note**: `minicom`, `screen`, and `picocom` are not included in the project's `nix develop` shell. Install ad-hoc with `nix shell nixpkgs#picocom` or add to your NixOS/Home Manager configuration for permanent use.

**Login**: `root` / `root`

### SSH Access

Connect the Jetson to your LAN via Ethernet, then find its IP:

**From serial console:**

```bash
ip addr show
```

**From your host (network scan):**

```bash
# Jetson Ethernet MAC OUI is 00:04:4B (registered to NVIDIA) — grep for that, not "nvidia"
arp-scan -l 2>/dev/null | grep "00:04:4b"
# Or use nmap:
nmap -sn 192.168.1.0/24 | grep -B2 "00:04:4B"
# Or check your router's DHCP lease table for the MAC starting with 00:04:4B
```

**Connect:**

```bash
ssh root@<jetson-ip>
# Password: root
```

For key-based access (recommended for development), copy your SSH key:

```bash
ssh-copy-id root@<jetson-ip>
```

## Phase 5: Validate the Baseline

Once logged in, verify the system is correctly configured.

### Kernel Version

```bash
uname -r
# Expected: 6.12.69-tegra

uname -a
# Expected: Linux <hostname> 6.12.69-tegra #1 SMP PREEMPT ... aarch64 GNU/Linux
```

### Debian Version

```bash
cat /etc/os-release | head -4
# Expected:
# PRETTY_NAME="Debian GNU/Linux trixie/sid"
# NAME="Debian GNU/Linux"
# VERSION_CODENAME=trixie

cat /etc/debian_version
# Expected: trixie/sid
```

### L4T BSP Tools

```bash
# Boot slot management (A/B OTA):
nvbootctrl --help
nvbootctrl dump-slots-info

# Real-time SoC monitoring (Ctrl-C to stop):
tegrastats

# CPU/GPU/EMC clock status:
jetson_clocks --show
```

### Tegra234 Kernel Configuration

```bash
# Verify Tegra234 SoC support:
zcat /proc/config.gz | grep CONFIG_ARCH_TEGRA_234_SOC
# Expected: CONFIG_ARCH_TEGRA_234_SOC=y

# Verify BPMP (critical for boot — clocks, power, thermal):
zcat /proc/config.gz | grep CONFIG_TEGRA_BPMP
# Expected: CONFIG_TEGRA_BPMP=y

# Check device tree:
cat /proc/device-tree/compatible | tr '\0' '\n'
# Expected to include: nvidia,p3767-0003 (Orin Nano 8GB module)
```

### Peripheral Verification

```bash
# PCIe (NVMe SSD should appear):
lspci

# USB devices:
lsusb

# Network interfaces:
ip link show

# Storage layout:
lsblk
df -h

# Loaded Tegra modules:
lsmod | grep tegra

# System services:
systemctl --failed          # Should be empty or minimal
systemctl status sshd       # SSH server should be active
```

### Kernel Module Verification

The `tegra234-enable.cfg` fragment enables a comprehensive set of SoC drivers. Verify key subsystems:

```bash
# Check dmesg for Tegra driver initialization:
dmesg | grep -i tegra | head -20

# Verify specific drivers:
dmesg | grep -i bpmp          # BPMP firmware communication
dmesg | grep -i xhci          # USB host controller
dmesg | grep -i pcie          # PCIe (NVMe access)
dmesg | grep -i stmmac        # MGBE Ethernet (if present on carrier)
dmesg | grep -i sdhci         # SD/MMC controller
```

## Kernel Development Workflow

With the baseline validated, here is the iterative workflow for kernel customization.

### Project Structure for Kernel Work

```
backends/debian/
├── meta-n3x/recipes-kernel/linux/
│   ├── linux-tegra_6.12.69.bb          # Kernel recipe
│   └── files/
│       └── tegra234-enable.cfg         # Kconfig fragment
├── kas/kernel/
│   └── tegra-6.12.yml                  # Kas overlay selecting tegra kernel
└── kas/machine/
    └── jetson-orin-nano.yml            # Machine config (includes tegra-6.12.yml)
```

### Adding Kernel Config Fragments

To enable additional kernel features, add a new `.cfg` file:

```bash
# Create your config fragment
cat > backends/debian/meta-n3x/recipes-kernel/linux/files/my-feature.cfg << 'EOF'
# Enable my feature
CONFIG_MY_FEATURE=y
CONFIG_MY_FEATURE_OPTION=m
EOF
```

Then add it to the kernel recipe's `SRC_URI`:

```bitbake
# In linux-tegra_6.12.69.bb, add to SRC_URI:
SRC_URI += "file://my-feature.cfg"
```

ISAR automatically merges `.cfg` fragments on top of the base `defconfig` and warns if any entries didn't take effect.

### Adding Kernel Patches

```bash
# Place patches in the files directory
cp 0001-my-driver-fix.patch backends/debian/meta-n3x/recipes-kernel/linux/files/
```

Add to the recipe:

```bitbake
# In linux-tegra_6.12.69.bb:
SRC_URI += "file://0001-my-driver-fix.patch"
```

Patches are applied in alphabetical/numerical order before kernel compilation.

### Rebuild and Re-flash Cycle

```bash
# Enter dev shell (if not already in one)
cd /home/tim/src/n3x-hwdev
nix develop
cd backends/debian

# Rebuild the image (sstate cache makes this faster after first build)
kas-build kas/base.yml:kas/machine/jetson-orin-nano.yml:kas/packages/debug.yml:kas/image/base.yml

# Re-flash (requires USB Recovery Mode each time)
cd ~/jetson-bsp/Linux_for_Tegra
sudo rm -rf rootfs/*
sudo tar xf /home/tim/src/n3x-hwdev/backends/debian/build/tmp/deploy/images/jetson-orin-nano/n3x-image-base-debian-trixie-jetson-orin-nano.tar.gz -C rootfs/
sudo ./apply_binaries.sh
sudo ./tools/kernel_flash/l4t_initrd_flash.sh jetson-orin-nano-devkit internal
```

### Rebuild Kernel Only (Faster Iteration)

To rebuild just the kernel without a full image rebuild:

> **`kas-build` vs `kas-shell`**: `kas-build` (used above) is the project's wrapper for full automated builds — it handles WSL-specific mount safety and cache configuration. `kas-shell` below is the upstream kas command that drops you into an interactive BitBake shell for manual recipe operations (cleaning, rebuilding individual recipes, devshell).

```bash
# Clean and rebuild just the kernel recipe
nix develop
cd backends/debian
kas-shell kas/base.yml:kas/machine/jetson-orin-nano.yml -c \
    "bitbake linux-tegra -c clean && bitbake linux-tegra"

# Then rebuild the image (picks up the new kernel)
kas-build kas/base.yml:kas/machine/jetson-orin-nano.yml:kas/packages/debug.yml:kas/image/base.yml
```

### Interactive Kernel Configuration

For `menuconfig`-style exploration:

```bash
nix develop
cd backends/debian
kas-shell kas/base.yml:kas/machine/jetson-orin-nano.yml -c "bitbake linux-tegra -c devshell"

# Inside the devshell:
make menuconfig
# Navigate, enable/disable options, save
make savedefconfig
# Copy the resulting defconfig or extract changed options as a .cfg fragment
```

### Verifying Config Changes on Target

After flashing a new image with config changes:

```bash
# On the Jetson:
zcat /proc/config.gz | grep CONFIG_MY_FEATURE
# Should show: CONFIG_MY_FEATURE=y
```

## Debian Package Development Workflow

For adding or modifying Debian packages baked into the image.

### Package Locations

Application packages (k3s, system config) are in `backends/debian/packages/`. BSP packages (NVIDIA L4T) are in `backends/debian/meta-n3x/recipes-bsp/`. See `backends/debian/BSP-GUIDE.md` for details on recipe patterns.

### Adding a Custom Package

1. Create a recipe in `meta-n3x/recipes-*/`:

   ```bitbake
   # meta-n3x/recipes-support/my-tool/my-tool_1.0.bb
   inherit dpkg-raw
   DESCRIPTION = "My custom tool"
   SRC_URI = "file://my-tool.sh"
   do_install() {
       install -d ${D}/usr/local/bin
       install -m 0755 ${WORKDIR}/my-tool.sh ${D}/usr/local/bin/my-tool
   }
   ```

2. Add to image via a kas overlay or directly in the machine config:

   ```yaml
   # In a kas overlay:
   local_conf_header:
     my-packages: |
       IMAGE_INSTALL:append = " my-tool"
   ```

3. Rebuild and re-flash as described above.

## Bypassing USB: Network-Based OTA Updates

The workflow described above requires USB Recovery Mode for every re-flash. This is the only option for the initial flash (QSPI firmware + first rootfs), but once a device is running, you can use OTA updates for iterative development -- no USB cable required.

There are two approaches:

- **NVIDIA native (`nv_update_engine`)**: Built into L4T R36. Flash with `ROOTFS_AB=1` to create dual rootfs partitions, then use `nvbootctrl` for A/B slot management. Simplest path for single-device development -- no additional software needed.

- **SWUpdate**: Third-party OTA framework with fleet management (hawkBit/Suricatta), signed update bundles, and a web UI. More setup, but required for production fleet management. Currently validated on QEMU x86_64 in this project; Jetson integration (custom `nvbootctrl` handler or GRUB chain-loading) is in progress.

Once either approach is working, the development cycle becomes: build a new image on your host, push the update over the network, and reboot into the new rootfs. If it fails, automatic rollback restores the previous working slot.

See [docs/jetson-swupdate-and-ota.md](jetson-swupdate-and-ota.md) for the full OTA guide -- architecture, comparison table, build instructions, bundle creation, and Jetson integration requirements.

## Reference: Key Files

### Machine Configuration
- `backends/debian/meta-n3x/conf/machine/jetson-orin-nano.conf` — Hardware properties
- `backends/debian/meta-n3x/conf/multiconfig/jetson-orin-nano-trixie.conf` — Multiconfig target
- `backends/debian/kas/machine/jetson-orin-nano.yml` — Kas build overlay

### Kernel
- `backends/debian/meta-n3x/recipes-kernel/linux/linux-tegra_6.12.69.bb` — Kernel recipe
- `backends/debian/meta-n3x/recipes-kernel/linux/files/tegra234-enable.cfg` — Kconfig fragment
- `backends/debian/kas/kernel/tegra-6.12.yml` — Kernel selection overlay

### BSP Packages
- `backends/debian/meta-n3x/recipes-bsp/nvidia-l4t/nvidia-l4t-core_36.4.4.bb` — L4T core
- `backends/debian/meta-n3x/recipes-bsp/nvidia-l4t/nvidia-l4t-tools_36.4.4.bb` — Jetson tools
- `backends/debian/meta-n3x/classes/nvidia-l4t-cross-build.bbclass` — Cross-build helper

### SWUpdate / OTA
- `docs/jetson-swupdate-and-ota.md` — Consolidated OTA guide (SWUpdate + nv_update_engine)

### Build Infrastructure
- `lib/debian/build-matrix.nix` — Build variant definitions
- `lib/debian/artifact-hashes.nix` — Artifact SHA256 hashes
- `backends/debian/versions.nix` — Version pins (L4T, kernel, k3s)
- `backends/debian/BSP-GUIDE.md` — Detailed BSP development reference

### Flash
- `flake.nix` — `mkJetsonFlashScript` helper and `jetson-flash-script-{base,server}` packages

### Documentation
- `docs/jetson-orin-nano-kernel6-analysis-revised.md` — Kernel 6.12 strategy analysis
- `docs/jetson-swupdate-and-ota.md` — OTA update architecture guide (SWUpdate + nv_update_engine)
