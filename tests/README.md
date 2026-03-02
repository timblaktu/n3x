# n3x Testing Framework

This directory contains the testing infrastructure for validating the n3x k3s cluster configuration.

## Overview

The testing framework uses NixOS `nixosTest` for automated integration tests. Each test boots real VMs, configures services, and verifies functionality automatically.

**Key Design Decision**: Tests use nixosTest multi-node approach where each "node" IS a k3s cluster node - no nested virtualization required. This works on all platforms (WSL2, Darwin, Cloud).

### Dual Backend Architecture (Plan 012)

n3x supports two build backends with unified test infrastructure.

#### What a Cluster Test Looks Like

```mermaid
flowchart TD
    subgraph DRIVER["Test Driver · Python Script"]
        direction LR
        PH["Phase 0-2: Boot + Network"]
        PK["Phase 3-8: K3s Cluster"]
        PH --> PK
    end

    subgraph VMS["3 QEMU/KVM VMs"]
        direction LR
        S1["server-1\n2 vCPUs · 2GB"]
        S2["server-2\n2 vCPUs · 2GB"]
        A1["agent-1\n2 vCPUs · 1.5GB"]
    end

    subgraph NET["VDE Virtual Switch"]
        direction LR
        SIMPLE["simple\neth1 flat"]
        VLANS["vlans\neth1.100 + eth1.200"]
        BOND["bonding-vlans\nbond0.100 + bond0.200"]
    end

    DRIVER --> VMS
    VMS --- NET
```

Each test selects one network profile variant. The same 3-node cluster topology runs across all profiles and both backends:

| Backend | Build System | Test Framework | Use Case |
|---------|--------------|----------------|----------|
| **NixOS** | nixpkgs | nixosTest | Primary development, VM testing |
| **Debian** | BitBake/kas (ISAR) | nixosTest + QEMU | Debian-based embedded systems |

Both backends share:
- **Network profiles** (`lib/network/profiles/`) - Pure data, no functions
- **Network config generators** (`lib/network/mk-network-config.nix`, `mk-systemd-networkd.nix`)
- **K3s flag generator** (`lib/k3s/mk-k3s-flags.nix`)
- **Test script utilities** (`tests/lib/test-scripts/`)

## Quick Start

```bash
# Run all flake checks (includes formatting and all tests)
nix flake check

# Run a specific k3s test
nix build '.#checks.x86_64-linux.k3s-cluster-formation' --print-build-logs
nix build '.#checks.x86_64-linux.k3s-storage' --print-build-logs
nix build '.#checks.x86_64-linux.k3s-network' --print-build-logs
nix build '.#checks.x86_64-linux.k3s-network-constraints' --print-build-logs

# Interactive debugging (opens Python REPL for test control)
nix build '.#checks.x86_64-linux.k3s-cluster-formation.driverInteractive'
./result/bin/nixos-test-driver
```

## Test Layer Hierarchy

Tests are organized by layer, with higher layers depending on lower layers passing:

```mermaid
flowchart LR
    L1["L1: Boot\n15-30s"]
    L2["L2: Network\n30-60s"]
    L3["L3: K3s Service\n60-90s"]
    L4["L4: Cluster\n2-5 min"]
    L4P["L4+: Advanced\n5-15 min"]

    L1 --> L2 --> L3 --> L4 --> L4P

    style L1 fill:#e8f5e9
    style L2 fill:#e3f2fd
    style L3 fill:#fff3e0
    style L4 fill:#fce4ec
    style L4P fill:#f3e5f5
```

| Layer | Name | What It Tests | Pass Criteria |
|-------|------|---------------|---------------|
| **L1** | VM Boot | Can QEMU/KVM boot a VM? | Backdoor shell connects |
| **L2** | Two-VM Network | Can VMs communicate via virtual network? | Ping succeeds between VMs |
| **L3** | K3s Service | Does k3s binary/service start? | `k3s --version` works, service starts |
| **L4** | Cluster Formation | Can nodes form a cluster? | All nodes show "Ready" |
| **L4+** | Advanced | Workloads, storage, HA | Varies by test |

### Layer Coverage by Backend

| Layer | NixOS Tests | Debian Tests |
|-------|-------------|------------|
| L1 | `nixos-smoke-vm-boot` | `debian-vm-boot` |
| L2 | `nixos-smoke-two-vm-network` | `debian-two-vm-network` |
| L3 | `nixos-smoke-k3s-service-starts` | `debian-server-boot`, `debian-service` |
| L4 | 8 tests (4 profiles × 2 boot modes) | 8 tests (4 profiles × 2 boot modes) |

### L4 Cluster Test Parity Matrix (Plan 020 Phase G)

Full test parity: 4 network profiles × 2 boot modes × 2 backends = 16 tests

| Network Profile | NixOS Direct | NixOS UEFI | Debian Firmware | Debian Direct |
|-----------------|:------------:|:----------:|:-------------:|:-----------:|
| simple          | ✓ | ✓ | ✓ | ✓ |
| vlans           | ✓ | ✓ | ✓ | ✓ |
| bonding-vlans   | ✓ | ✓ | ✓ | ✓ |
| dhcp-simple     | ✓ | ✓ | ✓ | ✓ |

**Boot Modes:**
- **NixOS Direct**: Direct kernel boot via QEMU `-kernel`/`-initrd` (default, fastest)
- **NixOS UEFI**: UEFI firmware → systemd-boot → kernel (validates bootloader)
- **Debian Firmware**: UEFI → GRUB/systemd-boot from `.wic` image (default, production-like)
- **Debian Direct**: Direct kernel boot via `-kernel`/`-initrd` (faster, bypasses bootloader)

---

## Test Execution Phases

Every cluster test follows the same phase sequence, defined in `tests/lib/test-scripts/`. Profile-specific phases activate based on the selected network profile:

```mermaid
flowchart TD
    P0["Phase 0: Start DHCP Server\n(dhcp-* profiles only)"]
    P1["Phase 1: Boot All Nodes\nwait_for_unit multi-user.target"]
    P15["Phase 1.5: Verify DHCP Leases\n(dhcp-* profiles only)"]
    P2["Phase 2: Verify Interfaces + IPs\nall profiles"]
    P25["Phase 2.5: VLAN Tag Verification\n(vlans / bonding-vlans only)"]
    P26["Phase 2.6: Storage Network Ping\n(vlans / bonding-vlans only)"]
    P27["Phase 2.7: Cross-VLAN Isolation\n(vlans / bonding-vlans only)"]
    P3["Phase 3: Start Primary Server\nk3s cluster-init"]
    P4["Phase 4: Primary Ready\nkubectl get nodes → Ready"]
    P5["Phase 5: Join Secondary Server\netcd HA quorum"]
    P6["Phase 6: Secondary Ready"]
    P7["Phase 7: Join Agent\nworker node"]
    P8["Phase 8: All Nodes Ready\n3/3 Ready — PASS"]

    P0 -.-> P1
    P1 --> P15
    P15 -.-> P2
    P1 --> P2
    P2 --> P25
    P25 -.-> P26 -.-> P27
    P2 --> P3
    P27 -.-> P3
    P3 --> P4 --> P5 --> P6 --> P7 --> P8

    style P0 fill:#e8f5e9,stroke-dasharray: 5 5
    style P15 fill:#e8f5e9,stroke-dasharray: 5 5
    style P25 fill:#e3f2fd,stroke-dasharray: 5 5
    style P26 fill:#e3f2fd,stroke-dasharray: 5 5
    style P27 fill:#e3f2fd,stroke-dasharray: 5 5
```

Dashed boxes are conditional — they execute only for the indicated profiles. Solid boxes run for every cluster test.

---

## Canonical Test Patterns

### Adding a New NixOS Test (Parameterized)

For K3s cluster tests, use the parameterized test builder:

```nix
# In flake.nix checks section:
k3s-cluster-myprofile = pkgs.callPackage ./tests/lib/mk-k3s-cluster-test.nix {
  inherit pkgs lib;
  networkProfile = "myprofile";  # References lib/network/profiles/myprofile.nix
};
```

The builder automatically:
- Loads the network profile preset (pure data)
- Transforms data → NixOS modules via `mkNixOSConfig`
- Transforms data → k3s flags via `mkK3sFlags.mkExtraFlags`
- Uses shared test scripts from `tests/lib/test-scripts/`

### Adding a New Network Profile

Network profiles are pure data - they export parameter presets, not functions:

```nix
# lib/network/profiles/myprofile.nix
{ lib }:
{
  # Per-node IPs keyed by network role
  ipAddresses = {
    "server-1" = { cluster = "192.168.1.1"; storage = "10.0.0.1"; };
    "server-2" = { cluster = "192.168.1.2"; storage = "10.0.0.2"; };
    "agent-1"  = { cluster = "192.168.1.3"; storage = "10.0.0.3"; };
  };

  # Interface names (include VLAN suffix for tagged networks)
  interfaces = {
    cluster = "eth1";        # Or "eth1.200" for VLANs, "bond0.200" for bonding
    storage = "eth1";        # Or "eth1.100" for VLANs, "bond0.100" for bonding
    trunk = "eth1";          # Or "bond0" for bonding
  };

  # Optional: VLAN IDs (omit for flat network)
  vlanIds = {
    cluster = 200;
    storage = 100;
  };

  # Optional: Bond configuration (omit for single-NIC)
  bondConfig = {
    members = [ "eth1" "eth2" ];
    mode = "active-backup";
    miimon = 100;
    primary = "eth1";
  };

  # K3s API endpoint
  serverApi = "https://192.168.1.1:6443";

  # K3s network CIDRs
  clusterCidr = "10.42.0.0/16";
  serviceCidr = "10.43.0.0/16";
}
```

The profile is transformed by:
- `mkNixOSConfig` → NixOS `systemd.network` modules
- `mkSystemdNetworkdFiles` → Debian backend `.network`/`.netdev` files
- `mkK3sFlags.mkExtraFlags` → K3s command-line flags

### Adding a New Debian Backend Test

Debian backend tests use the `mkDebianTest` wrapper with pre-built `.wic` images:

```nix
# tests/debian/my-test.nix
{ pkgs, lib, ... }:

let
  mkDebianTest = import ../lib/debian/mk-debian-test.nix { inherit pkgs lib; };
  artifacts = import ../../backends/debian/debian-artifacts.nix;
in
mkDebianTest {
  name = "my-test";

  # Define nodes with Debian backend images
  nodes = {
    server = {
      image = artifacts.images."qemuamd64/server" or null;
      memory = 2048;
      vcpus = 2;
    };
  };

  # Python test script (nixos-test-driver API)
  testScript = ''
    server.start()
    server.wait_for_unit("multi-user.target")
    server.succeed("my-command")
  '';
}
```

Wire into flake.nix:
```nix
# In checks.x86_64-linux:
debian-my-test = pkgs.callPackage ./tests/debian/my-test.nix {
  inherit pkgs lib;
};
```

### Adding a Simple Smoke Test

For non-parameterized tests, use `pkgs.testers.runNixOSTest` directly:

```nix
# tests/nixos/smoke/my-smoke-test.nix
{ pkgs, lib, ... }:

pkgs.testers.runNixOSTest {
  name = "my-smoke-test";

  nodes.machine = { config, pkgs, ... }: {
    # NixOS configuration
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("default.target")
    machine.succeed("echo 'Test passed'")
  '';
}
```

---

## Available Tests

### NixOS L4 K3s Cluster Tests (Parameterized)

These are the primary L4 cluster tests using parameterized network profiles. All tests validate 2-server HA control plane formation.

#### Direct Kernel Boot (default, fastest)

| Test | Network Profile | Description | Run Command |
|------|-----------------|-------------|-------------|
| `k3s-cluster-simple` | simple | Flat network | `nix build '.#checks.x86_64-linux.k3s-cluster-simple'` |
| `k3s-cluster-vlans` | vlans | 802.1Q VLAN tagging | `nix build '.#checks.x86_64-linux.k3s-cluster-vlans'` |
| `k3s-cluster-bonding-vlans` | bonding-vlans | Active-backup bonding + VLANs | `nix build '.#checks.x86_64-linux.k3s-cluster-bonding-vlans'` |
| `k3s-cluster-dhcp-simple` | dhcp-simple | DHCP addressing via dedicated server | `nix build '.#checks.x86_64-linux.k3s-cluster-dhcp-simple'` |

#### UEFI/systemd-boot (Plan 020 Phase G3)

| Test | Network Profile | Description | Run Command |
|------|-----------------|-------------|-------------|
| `k3s-cluster-simple-systemd-boot` | simple | UEFI firmware, systemd-boot | `nix build '.#checks.x86_64-linux.k3s-cluster-simple-systemd-boot'` |
| `k3s-cluster-vlans-systemd-boot` | vlans | UEFI + 802.1Q VLANs | `nix build '.#checks.x86_64-linux.k3s-cluster-vlans-systemd-boot'` |
| `k3s-cluster-bonding-vlans-systemd-boot` | bonding-vlans | UEFI + bonding + VLANs | `nix build '.#checks.x86_64-linux.k3s-cluster-bonding-vlans-systemd-boot'` |
| `k3s-cluster-dhcp-simple-systemd-boot` | dhcp-simple | UEFI + DHCP addressing | `nix build '.#checks.x86_64-linux.k3s-cluster-dhcp-simple-systemd-boot'` |

### NixOS Specialized Tests

These tests validate specific scenarios beyond basic cluster formation.

| Test | Description | Run Command |
|------|-------------|-------------|
| `k3s-cluster-formation` | Legacy 2 servers + 1 agent formation (deprecated, use k3s-cluster-simple) | `nix build '.#checks.x86_64-linux.k3s-cluster-formation'` |
| `k3s-storage` | Storage prerequisites, local-path PVC provisioning, StatefulSet volumes | `nix build '.#checks.x86_64-linux.k3s-storage'` |
| `k3s-network` | CoreDNS, flannel VXLAN, service discovery, pod network connectivity | `nix build '.#checks.x86_64-linux.k3s-network'` |
| `k3s-network-constraints` | Cluster behavior under degraded network (latency, loss, bandwidth limits) | `nix build '.#checks.x86_64-linux.k3s-network-constraints'` |
| `k3s-bond-failover` | Bond active-backup failover/failback while k3s remains operational | `nix build '.#checks.x86_64-linux.k3s-bond-failover'` |
| `k3s-vlan-negative` | Validates VLAN misconfiguration causes expected failures | `nix build '.#checks.x86_64-linux.k3s-vlan-negative'` |

### Debian Backend Tests (ISAR-based Embedded Systems)

These tests validate the Debian backend using pre-built `.wic` images.

**Test Infrastructure Design**: Debian backend tests use NixOS VMs for test infrastructure (DHCP servers, routers, traffic shapers) alongside Debian VMs for cluster nodes. This is intentional:
- The test framework is NixOS-based (nixosTest, test-driver, backdoor protocol)
- NixOS declarative config enables fast iteration for test utilities
- Debian backend images represent production; infrastructure VMs are test harness
- No need to build/maintain Debian backend images for test scaffolding

| Test | Layer | Description | Run Command |
|------|-------|-------------|-------------|
| `debian-vm-boot` | L1 | Single VM boots with backdoor shell | `nix build '.#checks.x86_64-linux.debian-vm-boot'` |
| `debian-two-vm-network` | L2 | Two VMs communicate via VDE network | `nix build '.#checks.x86_64-linux.debian-two-vm-network'` |
| `debian-server-boot` | L3 | K3s binary present and service ready | `nix build '.#checks.x86_64-linux.debian-server-boot'` |
| `debian-service` | L3 | K3s service starts successfully | `nix build '.#checks.x86_64-linux.debian-service'` |
| `debian-network-simple` | L3+ | Simple network profile test | `nix build '.#checks.x86_64-linux.debian-network-simple'` |
| `debian-network-vlans` | L3+ | VLAN network profile test | `nix build '.#checks.x86_64-linux.debian-network-vlans'` |
| `debian-network-bonding` | L3+ | Bonding+VLAN network profile test | `nix build '.#checks.x86_64-linux.debian-network-bonding'` |

#### Debian L4 Cluster Tests - Firmware Boot (default, production-like)

| Test | Network Profile | Description | Run Command |
|------|-----------------|-------------|-------------|
| `debian-cluster-simple` | simple | 2-server HA, flat network | `nix build '.#checks.x86_64-linux.debian-cluster-simple'` |
| `debian-cluster-vlans` | vlans | 2-server HA with 802.1Q VLANs | `nix build '.#checks.x86_64-linux.debian-cluster-vlans'` |
| `debian-cluster-bonding-vlans` | bonding-vlans | 2-server HA with bonding+VLANs | `nix build '.#checks.x86_64-linux.debian-cluster-bonding-vlans'` |
| `debian-cluster-dhcp-simple` | dhcp-simple | 2-server HA with DHCP | `nix build '.#checks.x86_64-linux.debian-cluster-dhcp-simple'` |

#### Debian L4 Cluster Tests - Direct Kernel Boot (Plan 020 Phase G4)

| Test | Network Profile | Description | Run Command |
|------|-----------------|-------------|-------------|
| `debian-cluster-simple-direct` | simple | Direct boot, flat network | `nix build '.#checks.x86_64-linux.debian-cluster-simple-direct'` |
| `debian-cluster-vlans-direct` | vlans | Direct boot with VLANs | `nix build '.#checks.x86_64-linux.debian-cluster-vlans-direct'` |
| `debian-cluster-bonding-vlans-direct` | bonding-vlans | Direct boot with bonding+VLANs | `nix build '.#checks.x86_64-linux.debian-cluster-bonding-vlans-direct'` |
| `debian-cluster-dhcp-simple-direct` | dhcp-simple | Direct boot with DHCP | `nix build '.#checks.x86_64-linux.debian-cluster-dhcp-simple-direct'` |

#### SWUpdate Tests (A/B OTA)

| Test | Description | Run Command |
|------|-------------|-------------|
| `debian-swupdate-apply` | Apply .swu bundle to inactive partition | `nix build '.#checks.x86_64-linux.debian-swupdate-apply'` |
| `debian-swupdate-boot-switch` | Reboot between A/B partitions | `nix build '.#checks.x86_64-linux.debian-swupdate-boot-switch'` |
| `debian-swupdate-bundle-validation` | Validate .swu structure and CMS signatures | `nix build '.#checks.x86_64-linux.debian-swupdate-bundle-validation'` |
| `debian-swupdate-network-ota` | Two-VM OTA with HTTP server | `nix build '.#checks.x86_64-linux.debian-swupdate-network-ota'` |

**NOTE**: Debian backend tests require pre-built images registered in the Nix store. Build and register with:
```bash
nix run '.'                              # Build and register ALL variants
nix run '.' -- --machine qemuamd64       # Build all variants for one machine
nix run '.' -- --variant base            # Build one specific variant
nix run '.' -- --list                    # Show all 16 variants
```

### Emulation Tests (vsim - Nested Virtualization)

These tests use nested virtualization for complex scenarios. They require native Linux with KVM.

| Test | Description | Run Command |
|------|-------------|-------------|
| `emulation-vm-boots` | Outer VM with libvirtd, OVS, dnsmasq, inner VM definitions | `nix build '.#checks.x86_64-linux.emulation-vm-boots'` |
| `network-resilience` | TC profile infrastructure for network constraint scenarios | `nix build '.#checks.x86_64-linux.network-resilience'` |
| `vsim-k3s-cluster` | Full cluster formation with pre-installed inner VM images | `nix build '.#checks.x86_64-linux.vsim-k3s-cluster'` |

### Validation Checks

| Check | Description | Run Command |
|-------|-------------|-------------|
| `lint-nixpkgs-fmt` | Nix code formatting validation | `nix build '.#checks.x86_64-linux.lint-nixpkgs-fmt'` |
| `build-all` | Validates all configurations build | `nix build '.#checks.x86_64-linux.build-all'` |
| `lint-debian-package-parity` | Debian backend package mapping verification | `nix flake check --no-build` |

### Debian Backend Package Parity Verification (Plan 016)

The `lint-debian-package-parity` check verifies that kas overlay YAML files contain all packages required for Debian backend images. This catches missing packages at **Nix evaluation time** rather than during Debian backend test runtime.

#### How It Works

```
lib/debian/package-mapping.nix    →    Defines required packages per group
        ↓
lib/debian/verify-kas-packages.nix →    Verifies packages exist in kas YAMLs
        ↓
nix flake check --no-build         →    Fails immediately if packages missing
```

**Key design**: Uses `lib.seq` to force verification at eval time:
```nix
# Verification happens during nix flake check (eval phase), not build phase
lib.seq verified (pkgs.runCommand "debian-package-parity" {} ''...'')
```

#### Package Groups

| Group | Kas File | Packages |
|-------|----------|----------|
| `k3s-core` | `kas/packages/k3s-core.yml` | ca-certificates, curl, iptables, conntrack, iproute2, ipvsadm, bridge-utils, procps, util-linux, k3s-system-config |
| `debug` | `kas/packages/debug.yml` | openssh-server, vim-tiny, less, iputils-ping, sshd-regen-keys |
| `test` | `kas/test-k3s-overlay.yml` | nixos-test-backdoor |

#### Adding New Packages

1. Add package to `lib/debian/package-mapping.nix` with proper group assignment
2. Add package to corresponding `kas/packages/*.yml` file
3. Run `nix flake check --no-build` to verify

If you add to `package-mapping.nix` but forget the kas file, you'll get:

```
error: Debian Backend Package Parity Verification Failed (Plan 016)
  - packages/debug.yml: missing iputils-ping

Fix: Add the missing packages to IMAGE_PREINSTALL:append or IMAGE_INSTALL:append
```

#### Why This Matters

Before Plan 016, Debian backend test failures with `exit code 127` (command not found) required bisecting which package was missing. Now the verification catches missing packages during `nix flake check`.

### ARM64/aarch64 Validation (Jetson)

Build validation tests for Jetson (aarch64-linux) configurations. These ensure ARM64 configs build correctly without runtime testing.

| Check | Description | Run Command |
|-------|-------------|-------------|
| `jetson-1-build` | Builds jetson-1 NixOS system derivation | `nix build '.#checks.aarch64-linux.jetson-1-build'` |
| `jetson-2-build` | Builds jetson-2 NixOS system derivation | `nix build '.#checks.aarch64-linux.jetson-2-build'` |

**NOTE**: Building these checks requires an aarch64 builder:
- Native aarch64 hardware (Jetson, ARM server, Apple Silicon Mac with Lima)
- Remote aarch64 builder (see [Nix Remote Builders](https://nixos.wiki/wiki/Distributed_build))
- binfmt-misc emulation (very slow, not recommended for full builds)

```bash
# On x86_64 with configured aarch64 remote builder:
nix build '.#checks.aarch64-linux.jetson-1-build' --builders 'ssh://aarch64-builder'

# Verify config evaluates without building (no builder required):
nix eval '.#nixosConfigurations.jetson-1.config.system.build.toplevel' --no-build
```

## Network Profiles

The test framework supports multiple network configurations via **parameterized test builders**. This allows testing different network topologies without code duplication.

### Available Profiles

Located in `lib/network/profiles/` (unified location for both backends):

| Profile | Description | Use Case | VLANs | Bonding |
|---------|-------------|----------|-------|---------|
| **simple** | Single flat network via eth1 | Baseline testing, CI/CD quick validation | No | No |
| **vlans** | 802.1Q VLAN tagging on eth1 trunk | VLAN validation before hardware deployment | Yes (100, 200) | No |
| **bonding-vlans** | Bonding + VLAN tagging | Full production parity testing | Yes (100, 200) | Yes |

### Network Profile Tests

Tests using parameterized builder (`tests/lib/mk-k3s-cluster-test.nix`):

```bash
# Simple profile (baseline)
nix build '.#checks.x86_64-linux.k3s-cluster-simple'

# VLAN tagging (production parity)
nix build '.#checks.x86_64-linux.k3s-cluster-vlans'

# Bonding + VLANs (complete production simulation)
nix build '.#checks.x86_64-linux.k3s-cluster-bonding-vlans'
```

### VLAN Configuration Details

The **vlans** and **bonding-vlans** profiles configure:

- **VLAN 200** (Cluster Network)
  - IP range: 192.168.200.0/24
  - Used by: k3s API, flannel VXLAN, cluster communication
  - Interface: `eth1.200` (vlans) or `bond0.200` (bonding-vlans)

- **VLAN 100** (Storage Network)
  - IP range: 192.168.100.0/24
  - Used by: Longhorn, iSCSI, storage replication
  - Interface: `eth1.100` (vlans) or `bond0.100` (bonding-vlans)

### Adding Custom Network Profiles

See the ["Adding a New Network Profile"](#adding-a-new-network-profile) section above for the canonical data-only profile format.

**Key Points** (Plan 012 Architecture):
- Profiles export **pure data** - no `nodeConfig` or `k3sExtraFlags` functions
- Data is transformed by `mkNixOSConfig` → NixOS modules, `mkSystemdNetworkdFiles` → Debian backend files
- K3s flags generated by `mkK3sFlags.mkExtraFlags` from the same profile data

### Why Parameterized Tests?

**Benefits**:
- **No code duplication** - Test logic defined once, network configs separate
- **DRY across backends** - Same profiles work for NixOS and Debian
- **Easy extension** - Add new profiles without touching test code
- **Production parity** - VLAN tests match future hardware deployment
- **Maintainability** - Changes to test logic apply to all profiles

**Architecture**:
```
Profile Data (lib/network/profiles/)
    │
    ├─→ mkNixOSConfig()          → NixOS systemd.network modules
    ├─→ mkSystemdNetworkdFiles() → Debian backend .network/.netdev files
    └─→ mkK3sFlags.mkExtraFlags() → K3s command-line flags
```

### Specialized Tests

#### Bond Failover Test (`k3s-bond-failover`)

Tests that bonding active-backup mode correctly handles NIC failures while k3s remains operational.

**Test Scenarios**:
1. Verify initial bond state (eth1 as primary/active)
2. Simulate primary NIC failure (`ip link set eth1 down`)
3. Verify automatic failover to backup (eth2 becomes active)
4. Verify k3s API remains accessible during failover
5. Restore primary NIC (`ip link set eth1 up`)
6. Verify failback to primary (eth1 becomes active again with `PrimaryReselectPolicy=always`)
7. Verify all 3 nodes remain Ready throughout the cycle

**Configuration**:
- Uses `bonding-vlans` network profile
- Bond mode: `active-backup`
- miimon: 100ms, UpDelaySec/DownDelaySec: 200ms

```bash
nix build '.#checks.x86_64-linux.k3s-bond-failover'
```

#### VLAN Negative Test (`k3s-vlan-negative`)

Validates that VLAN misconfigurations cause expected failures. This is a "negative test" - it proves assertions work by expecting failure.

**Scenario**:
- n100-1: VLAN 200 (correct)
- n100-2: VLAN 201 (wrong)
- n100-3: VLAN 202 (wrong)

All nodes use the same IP range (192.168.200.x) but different VLAN tags.

**Expected Behavior**:
1. All nodes boot successfully
2. n100-1 initializes k3s and becomes Ready
3. n100-2 and n100-3 fail to join cluster (connection refused/timeout)
4. Test passes by verifying cluster formation fails as expected

**nixosTest Limitation Note**: In nixosTest's virtual network, VLAN tags are applied but may not enforce true L2 isolation (no switch enforcement). The test documents this and validates configuration correctness rather than traffic isolation.

```bash
nix build '.#checks.x86_64-linux.k3s-vlan-negative'
```

### Profile-Specific Assertions

The parameterized test builder (`mk-k3s-cluster-test.nix`) includes profile-aware assertions that verify network configuration correctness.

#### PHASE 2: Interface and IP Assertions

| Profile | Verified Interfaces | Verified IPs |
|---------|---------------------|--------------|
| `simple` | `eth1` | `192.168.1.x` |
| `vlans` | `eth1.200`, `eth1.100` | `192.168.200.x`, `192.168.100.x` |
| `bonding-vlans` | `bond0`, `bond0.200`, `bond0.100` | `192.168.200.x`, `192.168.100.x` |

#### PHASE 2.5: VLAN Tag Verification

For `vlans` and `bonding-vlans` profiles:
- Verifies `ip -d link show` contains `vlan id 200` for cluster VLAN
- Verifies `ip -d link show` contains `vlan id 100` for storage VLAN

#### PHASE 2.6: Storage Network Validation

For `vlans` and `bonding-vlans` profiles:
- Verifies each node has correct storage IP (192.168.100.1-3)
- Tests ping connectivity from each node to all other nodes on storage network

#### PHASE 2.7: Cross-VLAN Isolation Check

For `vlans` and `bonding-vlans` profiles (best-effort in nixosTest):
1. **ARP table inspection** - Verifies ARP entries learned on correct interfaces
2. **Routing table verification** - Asserts cluster network routes via `.200` interface, storage via `.100`
3. **IP cross-contamination check** - Verifies cluster VLAN has no storage IPs and vice versa

**Note**: True L2 isolation testing requires OVS emulation or physical hardware.

### Test Coverage Matrix

| Validation | simple | vlans | bonding-vlans | bond-failover | vlan-negative |
|------------|--------|-------|---------------|---------------|---------------|
| Interface exists | ✓ | ✓ | ✓ | ✓ | ✓ |
| IP assignment | ✓ | ✓ | ✓ | ✓ | ✓ |
| VLAN ID verification | - | ✓ | ✓ | ✓ | ✓ |
| Storage network ping | - | ✓ | ✓ | ✓ | - |
| Routing table segregation | - | ✓ | ✓ | ✓ | - |
| IP cross-contamination | - | ✓ | ✓ | ✓ | - |
| K3s cluster formation | ✓ | ✓ | ✓ | ✓ | partial |
| Bond failover/failback | - | - | - | ✓ | - |
| VLAN misconfiguration detection | - | - | - | - | ✓ |

## Platform Compatibility

### Platform Support Matrix

| Platform | nixosTest Multi-Node | vsim (Nested Virt) | aarch64 Build | Notes |
|----------|---------------------|-------------------|---------------|-------|
| Native Linux (x86_64) | YES | YES | Requires builder | Full support |
| Native Linux (aarch64) | YES | YES | YES | ARM servers, Jetson |
| WSL2 (Windows 11) | YES | NO | Requires builder | Hyper-V limits to 2 nesting levels |
| Darwin (macOS arm64) | YES* | NO | YES (native) | Requires Lima/UTM VM host |
| Darwin (macOS x86_64) | YES* | NO | Requires builder | Requires Lima/UTM VM host |
| AWS/Cloud | YES | Varies | Graviton instances | Requires KVM-enabled instances |

*Requires running inside a Linux VM (Lima or UTM)

#### aarch64 Builder Options

To build ARM64 (Jetson) configurations from x86_64 hosts:

1. **Remote aarch64 builder** (recommended for CI/CD):
   ```bash
   # Configure in /etc/nix/machines or nix.conf
   # Example: ssh://builder@aarch64-host x86_64-linux,aarch64-linux
   nix build '.#checks.aarch64-linux.jetson-1-build'
   ```

2. **Apple Silicon Mac with Lima** (cross-compile):
   ```bash
   # Lima runs native aarch64-linux, can serve as builder
   lima nix build '.#checks.aarch64-linux.jetson-1-build'
   ```

3. **AWS Graviton instance**:
   ```bash
   # Launch aarch64 NixOS AMI on Graviton
   # Run builds natively
   ```

4. **binfmt-misc emulation** (very slow, last resort):
   ```bash
   # Enable binfmt in NixOS configuration
   boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
   # Warning: Full system builds may take hours
   ```

### WSL2 (Windows 11)

WSL2 works with nixosTest multi-node tests out of the box:

```bash
# Verify KVM is available
ls -la /dev/kvm

# Run tests
nix build '.#checks.x86_64-linux.k3s-cluster-formation' --print-build-logs
```

**Limitation**: Triple-nested virtualization (vsim tests) does NOT work on WSL2 due to Hyper-V Enlightened VMCS limiting virtualization to 2 levels. See `docs/hyper-v-enlightened-vmcs-caps-nested-virt-at-2-levels.md`.

### Darwin (macOS arm64/x86_64)

macOS requires a Linux VM to run nixosTest. Options:

#### Option 1: Lima (Recommended for arm64)

```bash
# Install Lima
brew install lima

# Create NixOS VM with KVM support
lima create --arch=aarch64 --vm-type=vz nixos.yaml

# Shell into Lima VM
lima

# Inside Lima VM, run tests
cd /path/to/n3x
nix build '.#checks.x86_64-linux.k3s-cluster-formation' --print-build-logs
```

Example `nixos.yaml` for Lima:
```yaml
arch: aarch64
vmType: vz
rosetta:
  enabled: true
images:
- location: "https://hydra.nixos.org/build/XXXXX/download/1/nixos-minimal-YY.YY-aarch64-linux.iso"
  arch: aarch64
mounts:
- location: "~"
  writable: true
```

#### Option 2: UTM

1. Download NixOS ARM64 ISO from hydra.nixos.org
2. Create new VM in UTM with virtualization enabled
3. Install NixOS, enable nix flakes
4. Clone n3x and run tests

#### Cross-Compilation Note

For arm64 Macs testing x86_64 configurations:
- Native arm64 tests work directly
- x86_64 tests require Rosetta 2 or cross-compilation setup
- Consider using `aarch64-linux` checks when available

### AWS/Cloud

For cloud CI/CD, use instances with KVM support:

#### AWS
- Use `.metal` instances (e.g., `c5.metal`, `m5.metal`) for bare-metal KVM
- Or use Nitro instances with `/dev/kvm` access (e.g., `c5.xlarge` with nested virt enabled)

#### NixOS AMI Setup

```bash
# Launch NixOS AMI (community AMIs available)
# Or build custom AMI with:
nix build '.#packages.x86_64-linux.amazon-image'

# After launch, ensure KVM module is loaded
sudo modprobe kvm_intel  # or kvm_amd
ls -la /dev/kvm
```

#### Self-Hosted GitLab Runner on NixOS

```nix
# configuration.nix for GitLab runner
{ config, pkgs, ... }:
{
  # Enable KVM
  boot.kernelModules = [ "kvm-intel" ];  # or kvm-amd

  # GitLab runner
  services.gitlab-runner = {
    enable = true;
    services.default = {
      registrationConfigFile = "/etc/gitlab-runner/token";
      executor = "shell";
      tagList = [ "kvm" "nix" ];
    };
  };

  # Nix configuration
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
  };

  # User permissions for KVM
  users.users.gitlab-runner.extraGroups = [ "kvm" ];
}
```

## CI/CD Integration

### GitLab CI

The repository includes `.gitlab-ci.yml` with:
- Validation stage: flake check, formatting
- Test stage: individual k3s tests (cluster-formation, storage, network, constraints)
- Integration stage: emulation tests, full test suite

Runner requirements:
- Nix with flakes enabled
- `/dev/kvm` access
- Tag: `kvm`

### GitHub Actions

```yaml
name: n3x Tests
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v24
        with:
          extra_nix_config: |
            experimental-features = nix-command flakes
      - name: Run k3s cluster formation test
        run: nix build '.#checks.x86_64-linux.k3s-cluster-formation' --print-build-logs
```

Note: GitHub-hosted runners may not have KVM. Use self-hosted runners for full test suite.

## Directory Structure

```
n3x/
├── lib/                              # Shared library functions
│   ├── network/                      # Network configuration
│   │   ├── mk-network-config.nix     # mkNixOSConfig(), mkSystemdNetworkdFiles()
│   │   ├── mk-systemd-networkd.nix   # Debian backend file generation (internal)
│   │   └── profiles/                 # Network profile presets (pure data)
│   │       ├── simple.nix            # Single flat network
│   │       ├── vlans.nix             # 802.1Q VLAN tagging
│   │       ├── bonding-vlans.nix     # Bonding + VLANs
│   │       └── vlans-broken.nix      # Intentionally broken (negative test)
│   └── k3s/
│       └── mk-k3s-flags.nix          # K3s flag generation from profile data
│
├── tests/
│   ├── nixos/                        # NixOS backend tests
│   │   ├── smoke/                    # L1-L3 baseline tests
│   │   │   ├── vm-boot.nix           # L1: VM boots
│   │   │   ├── two-vm-network.nix    # L2: VMs can ping
│   │   │   └── k3s-service-starts.nix # L3: K3s service starts
│   │   ├── k3s-cluster-formation.nix # L4: Cluster forms (legacy)
│   │   ├── k3s-bond-failover.nix     # Bond failover test
│   │   └── k3s-vlan-negative.nix     # VLAN misconfiguration test
│   ├── debian/                       # Debian backend tests
│   │   ├── single-vm-boot.nix        # L1: Debian VM boots
│   │   ├── two-vm-network.nix        # L2: Debian VMs can ping
│   │   ├── k3s-server-boot.nix       # L3: K3s binary present
│   │   ├── k3s-network-*.nix         # Network profile tests
│   │   └── swupdate-*.nix            # A/B OTA tests
│   ├── lib/                          # Test support libraries
│   │   ├── mk-k3s-cluster-test.nix   # Parameterized NixOS cluster test
│   │   ├── machine-roles.nix         # Server/agent role definitions
│   │   ├── test-scripts/             # Shared Python test snippets
│   │   │   ├── default.nix           # mkDefaultClusterTestScript
│   │   │   ├── utils.nix             # tlog(), log_banner()
│   │   │   └── phases/               # Boot, network, K3s phases
│   │   └── debian/                   # Debian backend test support
│   │       ├── mk-debian-test.nix    # Debian backend test wrapper
│   │       ├── mk-debian-vm-script.nix # QEMU command generator
│   │       └── mk-network-config.nix # Debian backend network setup
│   ├── emulation/                    # vsim nested virtualization
│   └── README.md                     # This file
│
└── backends/
    └── debian/
        ├── debian-artifacts.nix      # Pre-built image hashes
        ├── kas/                      # BitBake/kas configs
        └── meta-n3x/            # ISAR layer (recipes)
```

## Interactive Debugging

The nixos-test-driver provides powerful debugging facilities for investigating test failures.

### Starting Interactive Mode

```bash
# Build and run the interactive test driver
nix build '.#checks.x86_64-linux.k3s-cluster-formation.driverInteractive'
./result/bin/nixos-test-driver

# Or pass --interactive flag directly
./result/bin/nixos-test-driver --interactive
```

This opens a Python REPL (ptpython/ipython) with all test symbols available.

### Available Symbols in Interactive Mode

When the driver starts, it prints available symbols:

```python
# Machine objects (named by node config)
n100_1, n100_2, n100_3    # Direct access to VMs by name
machine                    # Available when there's exactly one VM

# Driver functions
start_all()               # Start all VMs
join_all()                # Wait for all VMs to shut down
test_script()             # Run the test script
run_tests()               # Run tests with timeout

# Utilities
retry(fn, timeout=900)    # Retry function until True or timeout
subtest("name")           # Context manager for grouped logging
log                       # Logger instance
driver                    # Driver instance
```

### Interactive Session Example

```python
>>> start_all()
>>> n100_1.wait_for_unit("multi-user.target")
>>> n100_1.succeed("k3s kubectl get nodes")
'NAME     STATUS   ROLES                  AGE   VERSION\n...'

# Check what's running
>>> n100_1.succeed("systemctl status k3s")

# Inspect network
>>> n100_1.succeed("ip addr show")

# Drop into interactive shell
>>> n100_1.shell_interact()
$ hostname
n100-1
$ journalctl -u k3s -n 50
...
$ exit  # or Ctrl-D to return to Python REPL
```

### Keeping VM State Between Runs (`--keep-vm-state`)

By default, VM state is cleared on each run. Use `--keep-vm-state` to preserve it:

```bash
# Keep VM state for iterative debugging
./result/bin/nixos-test-driver --keep-vm-state --interactive
```

**How it works:**
- VM state stored in: `/tmp/vm-state-<machine-name>/`
- Without flag: State directory deleted before each run
- With flag: State persists across runs (disk images, sockets, etc.)

**Use cases:**
- Debugging boot issues (examine VM disk after failure)
- Testing reboot behavior (state survives `machine.shutdown()` + `machine.start()`)
- Iterative development (avoid slow boot on each change)

**Cleaning stale state manually:**
```bash
rm -rf /tmp/vm-state-*
```

### Using Breakpoints

#### Python Built-in Breakpoint

Add `breakpoint()` in your test script to pause execution:

```python
# In testScript
start_all()
n100_1.wait_for_unit("k3s.service")
breakpoint()  # Execution stops here, drops into pdb
n100_1.succeed("k3s kubectl get nodes")
```

When running non-interactively, this requires a terminal. For sandboxed builds, use the debug hook instead.

#### Debug Hook (Sandboxed Builds)

For Nix sandboxed builds, enable the debug hook:

```nix
# In test definition
pkgs.testers.runNixOSTest {
  name = "my-test";
  # ... nodes ...
  enableDebugHook = true;  # Enable remote debugging
  testScript = ''
    start_all()
    debug.breakpoint()  # Remote pdb on TCP port 4444
  '';
}
```

When `debug.breakpoint()` is called:
1. Test pauses and logs: `Breakpoint reached, run 'sudo attach-command <pattern>'`
2. Opens RemotePdb on `127.0.0.1:4444`
3. Connect with: `telnet 127.0.0.1 4444` or similar

**Note:** The driver automatically calls `debug.breakpoint()` on assertion failures, allowing post-mortem inspection.

### Machine Debugging Methods

#### `machine.shell_interact()`

Drop into an interactive shell on the VM:

```python
>>> n100_1.shell_interact()
# Now in VM shell, run any commands
$ cat /etc/os-release
$ journalctl -xe
$ ip route show
# Ctrl-D or Ctrl-C to exit
```

#### `machine.console_interact()`

Interact directly with QEMU's serial console (lower level than shell):

```python
>>> n100_1.console_interact()
# Direct QEMU stdin/stdout, useful for boot issues
# Ctrl-C kills QEMU, Ctrl-D returns to Python
```

#### `machine.screenshot(filename)`

Capture VM display state:

```python
>>> n100_1.screenshot("debug-state.png")
# Saved to output directory
```

#### `machine.get_screen_text()`

OCR the VM screen (requires Tesseract):

```python
>>> text = n100_1.get_screen_text()
>>> print(text)
# Useful for debugging GUI or boot splash issues
```

#### `machine.send_key(key)` / `machine.send_chars(string)`

Send keyboard input to VM:

```python
>>> n100_1.send_key("ctrl-alt-f2")  # Switch to tty2
>>> n100_1.send_chars("root\n")      # Type login
```

### Inspecting Test Execution

#### Serial Console Output

Enable serial logging during test:

```python
>>> serial_stdout_on()   # Print serial output to terminal
>>> n100_1.start()       # Now see boot messages
>>> serial_stdout_off()  # Disable when done
```

#### Checking Command Results

```python
# succeed() returns stdout, raises on failure
>>> output = n100_1.succeed("k3s kubectl get nodes")

# execute() returns (exit_code, stdout) - doesn't raise
>>> code, output = n100_1.execute("k3s kubectl get nodes")
>>> if code != 0:
...     print(f"Command failed: {output}")
```

#### Subtest Grouping

Group related operations in logs:

```python
with subtest("Verify cluster formation"):
    n100_1.wait_for_unit("k3s.service")
    n100_2.wait_for_unit("k3s.service")
    # If any step fails, logs show it was in "Verify cluster formation"
```

### Debian Backend Tests Interactive Mode

Debian backend tests also support interactive mode:

```bash
# Build Debian backend test
nix build '.#checks.x86_64-linux.debian-cluster-simple'

# Run interactively
./result/bin/run-test-interactive

# Or build driverInteractive
nix build '.#checks.x86_64-linux.debian-cluster-simple.driverInteractive'
./result/bin/nixos-test-driver --interactive
```

### Common Debugging Workflows

#### 1. Test Fails Intermittently

```bash
# Run with kept state to preserve failure evidence
./result/bin/nixos-test-driver --keep-vm-state --interactive

>>> start_all()
>>> # Run test steps manually, observing behavior
>>> n100_1.execute("journalctl -u k3s --no-pager")
```

#### 2. Network Connectivity Issues

```python
>>> n100_1.succeed("ip addr show")
>>> n100_1.succeed("ip route show")
>>> n100_1.succeed("ping -c 3 192.168.1.2")
>>> n100_2.succeed("ss -tlnp")  # What's listening?
>>> n100_1.succeed("nc -zv 192.168.1.2 6443")  # Can connect?
```

#### 3. Service Won't Start

```python
>>> code, out = n100_1.execute("systemctl status k3s")
>>> print(out)
>>> n100_1.succeed("journalctl -u k3s -n 100 --no-pager")
>>> n100_1.succeed("systemctl cat k3s")  # Check unit file
```

#### 4. Post-Mortem After Failure

When a test fails, the driver pauses if debug hook is enabled:

```
Test failed with: command `kubectl get nodes` failed
Breakpoint reached, run 'sudo /nix/store/.../attach 1234567'
```

Connect and inspect:
```python
>>> n100_1.succeed("dmesg | tail -50")
>>> n100_1.succeed("free -h")
>>> n100_1.succeed("df -h")
```

### Environment Variables

| Variable | Description |
|----------|-------------|
| `TMPDIR` | Override temp directory for VM state |
| `XDG_RUNTIME_DIR` | Alternative temp directory location |
| `LOGFILE` | Enable XML logging to specified file |

### Tips

1. **History file**: Interactive sessions save history to `.nixos-test-history` in current directory
2. **Multiple sessions**: Each `shell_interact()` is independent; exit one to return to Python
3. **Timeouts**: Interactive mode has no global timeout (unlike automated runs)
4. **Screenshots**: Useful for GUI tests or when OCR text doesn't capture issue
5. **VM names**: Use `pythonize_name()` rules - dashes become underscores (`n100-1` → `n100_1`)

## Troubleshooting

### KVM Not Available

```bash
# Check if KVM module is loaded
lsmod | grep kvm

# Load KVM module
sudo modprobe kvm_intel  # Intel
sudo modprobe kvm_amd    # AMD

# Check permissions
ls -la /dev/kvm
# Add user to kvm group if needed
sudo usermod -aG kvm $USER
```

### Test Timeouts

Tests have default timeouts. For slow systems:

```bash
# Increase test timeout
NIX_TEST_TIMEOUT=3600 nix build '.#checks.x86_64-linux.k3s-cluster-formation'
```

### Out of Memory

Reduce parallel builds or increase VM memory:

```bash
# Build with less parallelism
nix build '.#checks.x86_64-linux.k3s-storage' --max-jobs 1
```

### WSL2 Nested Virtualization Failure

vsim tests (emulation-vm-boots, network-resilience) will fail on WSL2. Use nixosTest multi-node tests instead.

### Bond Failover Test Failures

If `k3s-bond-failover` fails:

1. **"Expected eth1 as active slave"** - Check bond configuration:
   ```bash
   # In test driver
   n100_1.succeed("cat /proc/net/bonding/bond0")
   ```
   Verify `eth1` is listed as primary and active-backup mode is enabled.

2. **"Failover to eth2 did not occur"** - Check miimon timing:
   ```bash
   n100_1.succeed("cat /proc/net/bonding/bond0 | grep -i mii")
   ```
   The `DownDelaySec` (200ms) may need adjustment for slower systems.

3. **"k3s API inaccessible after failover"** - Cluster may need more time to stabilize. Check etcd health:
   ```bash
   n100_1.succeed("k3s kubectl get endpoints kubernetes")
   ```

### VLAN Negative Test Behavior

The `k3s-vlan-negative` test may pass even when nodes appear to communicate. This is expected in nixosTest:

- **nixosTest shares a virtual network bridge** - VLANs are tagged but not isolated at L2
- The test verifies configuration correctness (VLAN IDs are applied)
- For true isolation testing, use OVS emulation or physical hardware

### Profile-Specific Assertion Failures

If PHASE 2.x assertions fail:

1. **Missing interface** (e.g., "Missing eth1.200"):
   ```bash
   # Check systemd-networkd status
   n100_1.succeed("networkctl status")
   n100_1.succeed("journalctl -u systemd-networkd -n 50")
   ```

2. **Missing IP** (e.g., "Missing 192.168.200.x"):
   ```bash
   # Check if DHCP or static config applied
   n100_1.succeed("ip addr show")
   n100_1.succeed("networkctl status eth1.200")
   ```

3. **Routing table mismatch**:
   ```bash
   n100_1.succeed("ip route show")
   # Expected: 192.168.200.0/24 dev eth1.200 (or bond0.200)
   ```

### etcd Election Timing

K3s HA clusters use etcd which requires leader election. Timing variance is normal:

- Cluster formation typically takes 60-120 seconds
- Tests have generous timeouts (300s for node ready)
- If tests timeout, check etcd logs:
  ```bash
  n100_1.succeed("journalctl -u k3s -n 100 | grep -i etcd")
  ```

### Test Caching Behavior

`nix build` uses caching. Tests that previously passed may not re-execute:

| Indicator | Cached (not run) | Actually ran |
|-----------|------------------|--------------|
| Duration | 6-10 seconds | 2-15 minutes |
| VM boot logs | None | `systemd[1]: Initializing...` |
| Test commands | None | `must succeed:`, `wait_for` |

To force test re-execution:
```bash
# Force rebuild (ignores cache)
nix build '.#checks.x86_64-linux.k3s-cluster-vlans' --rebuild
```

## Additional Resources

- [NixOS Testing Library](https://nixos.wiki/wiki/NixOS_Testing_library)
- [nix.dev Integration Testing](https://nix.dev/tutorials/nixos/integration-testing-using-virtual-machines.html)
- [Hyper-V Nested Virtualization Analysis](../docs/hyper-v-enlightened-vmcs-caps-nested-virt-at-2-levels.md)
- [n3x Main README](../README.md)

## See Also

- [Test Library Reference](lib/README.md) — Test builder internals, machine roles, Debian backend test wrappers
- [Network Schema](lib/NETWORK-SCHEMA.md) — Network profile data format and validation
- [Emulation Utilities](emulation/README.md) — vsim nested virtualization infrastructure
- [Test Coverage Matrix](TEST-COVERAGE.md) — Coverage tracking across backends and profiles
