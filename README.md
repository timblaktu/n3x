# n3x — Develop K3s Clusters on Custom Hardware with BYO BSP + OS

n3x is a toolkit for developing multi-arch, multi-node k3s clusters for custom embedded systems. Users can bring their own BSP and OS [`backends`](./backends), enabling them to use preferred tools to build firmware, kernel, drivers, packages and rootfs images for their preferred target platforms. Currently supported are [`backends/debian`](./backends/debian) which uses [kas](https://github.com/siemens/kas)/[ISAR](https://github.com/ilbers/isar) to build Debian-based systems and [`backends/nixos`](./backends/nixos) which uses [nix to build NixOS systems](https://nixos.org/learn).

n3x supports standard bare-metal deployment using backend-provided tools, and fully-automated, full-stack system testing in emulated environments for when you don't have hardware. E2e system tests are defined in high-level nix derivations which use nixpkgs' VM test driver for test orchestration and whose capabilities are limited only by the locally-installed linux virtualization stack. There exist analogous nix derivations for the detailed cluster/network/storage configurations needed by the backends to implement each specific system test.

![n3x Overview](docs/diagrams/n3x-overview.drawio.svg)

This enables full-stack embedded system development, from early firmware stages to kernel loading and the full linux boot process, to k3s cluster formation and bootstrapping, to k8s workload deployment and validation, _without hardware_. Since all of this is done with the standard linux virtualization stack (qemu, kvm, libvirt, et al), system emulation and test coverage can be expanded by writing custom emulators and software mocking layers using standard tools designed for this purpose.

![Full-Stack System Emulation](docs/diagrams/n3x-full-stack-emulation.drawio.svg)

## Getting Started

Choose your entry point based on what you want to do:

| Goal | Start Here |
|------|------------|
| Add a Debian application package | [`backends/debian/packages/README.md`](backends/debian/packages/README.md) |
| Build Debian disk images | [`backends/debian/README.md`](backends/debian/README.md) |
| Build or deploy NixOS configurations | [`backends/nixos/README.md`](backends/nixos/README.md) |
| Run VM tests | [`tests/README.md`](tests/README.md) |
| Modify network profiles, K3s topology, or test framework | [`docs/GETTING-STARTED.md`](docs/GETTING-STARTED.md) |

For a guided walkthrough covering all paths, see [`docs/GETTING-STARTED.md`](docs/GETTING-STARTED.md).

## Building

### Debian Backend

The build matrix has 16 variants across 4 machines (42 total artifacts). The primary workflow builds images and registers them in the Nix store:

```bash
# Build and register ALL 16 variants
nix run '.'

# List all variants in the build matrix
nix run '.' -- --list

# Build one specific variant
nix run '.' -- --variant server-simple-server-1

# Build all variants for one machine
nix run '.' -- --machine qemuamd64

# Preview what would be built
nix run '.' -- --dry-run
```

Each variant is assembled from stacked kas overlays:

| Overlay          | Purpose                    | Examples                        |
|------------------|----------------------------|---------------------------------|
| `machine/`       | Target hardware            | `qemu-amd64`, `qemu-arm64`     |
| `packages/`      | Package sets               | `k3s-core`, `debug`            |
| `image/`         | Cluster role               | `k3s-server`, `k3s-agent`      |
| `network/`       | Network topology           | `simple`, `vlans`, `bonding`   |
| `node/`          | Per-node identity (IP, ID) | `server-1`, `agent-1`          |

For lower-level builds without Nix store registration:

```bash
nix develop
cd backends/debian
kas-build kas/base.yml:kas/machine/qemu-amd64.yml:kas/packages/k3s-core.yml:kas/packages/debug.yml:kas/image/k3s-server.yml:kas/network/simple.yml:kas/node/server-1.yml
```

See [`backends/debian/README.md`](backends/debian/README.md) for the full Debian build guide.

### NixOS Backend

NixOS host configurations are built and deployed using standard Nix tooling:

```bash
# Build a host configuration
nix build '.#nixosConfigurations.n100-1.config.system.build.toplevel'

# Deploy to a running host
nixos-rebuild switch --flake '.#n100-1' --target-host root@n100-1
```

See [`backends/nixos/README.md`](backends/nixos/README.md) for module composition and deployment.

## Testing

Both backends converge at the same test harness — the NixOS test driver — which orchestrates QEMU/KVM multi-node topologies via Python test scripts (see the [overview diagram](#n3x--develop-k3s-clusters-on-custom-hardware-with-byo-bsp--os) above). Tests run identically on developer laptops and CI, requiring only KVM. No physical hardware or cloud dependencies needed.

```bash
# Run ALL Debian tests (18 tests)
nix build '.#checks.x86_64-linux.debian-all'

# Run a single Debian test
nix build '.#checks.x86_64-linux.debian-cluster-simple' -L

# Run a NixOS backend test
nix build '.#checks.x86_64-linux.k3s-cluster-simple'

# Validate all artifact hashes without running tests
nix build '.#checks.x86_64-linux.debian-artifact-validation'
```

### Cluster Test Parity Matrix

| Network Profile | NixOS | Debian |
|-----------------|-------|--------|
| Simple (flat) | `k3s-cluster-simple` | `debian-cluster-simple` |
| 802.1Q VLANs | `k3s-cluster-vlans` | `debian-cluster-vlans` |
| Bonding + VLANs | `k3s-cluster-bonding-vlans` | `debian-cluster-bonding-vlans` |
| DHCP | `k3s-cluster-dhcp-simple` | `debian-cluster-dhcp-simple` |

Additional backend-specific tests cover boot validation, service startup, network debugging, OTA updates (Debian), and storage/failover scenarios (NixOS). See [`tests/README.md`](tests/README.md) for the full 45-check test catalog.

## Architecture

![System Architecture](docs/diagrams/n3x-architecture.drawio.svg)

The `lib/` directory is the architectural center: it defines network profiles, K3s topology, and package requirements once, then each backend consumes them in its native format. Both backends converge at the test infrastructure, where identical test scenarios validate cluster formation across network profiles.

| Abstraction | NixOS Backend | Debian Backend |
|-------------|---------------|----------------|
| **Machine** | `system` + `hardware/<machine>.nix` | `MACHINE` + `recipes-bsp/` |
| **Role** | `modules/roles/k3s-server.nix` | `classes/k3s-server.bbclass` |
| **System** | `nixosConfigurations.<name>` | `kas/<overlays>.yml` + image recipe |
| **Network** | NixOS systemd-networkd module | `.network`/`.netdev` config files |
| **K3s Binary** | nixpkgs `k3s` package | Static binary from GitHub releases |
| **Test Harness** | nixosTest (native) | nixosTest (with .wic images) |

Shared configuration libraries ([`lib/network/`](lib/network/README.md), [`lib/k3s/`](lib/k3s/README.md)) transform profile data for both backends. See [`docs/diagrams/n3x-architecture.md`](docs/diagrams/n3x-architecture.md) for detailed architecture diagrams.

## Repository Structure

```
n3x/
├── backends/
│   ├── debian/                  # ← MOST DEVELOPERS WORK HERE
│   │   ├── packages/            #   ← ADD PACKAGES HERE
│   │   │   ├── k3s/             #     K3s binary + systemd service
│   │   │   └── k3s-system-config/ #   K3s cluster configuration
│   │   ├── kas/                 #   kas configuration overlays
│   │   │   ├── base.yml         #     Base ISAR config
│   │   │   ├── machine/         #     Target hardware definitions
│   │   │   ├── image/           #     Image roles (server, agent)
│   │   │   ├── network/         #     Network profiles
│   │   │   └── node/            #     Per-node identity
│   │   └── meta-n3x/            #   BitBake layer (recipes, WIC templates)
│   │
│   └── nixos/                   # NixOS backend — reference implementation
│       └── ...                  #   (hosts, modules, disko, vms)
│
├── lib/                         # Shared abstraction layer
│   ├── network/                 #   Network config generation (NixOS + Debian)
│   ├── k3s/                     #   K3s flag generation from topology profiles
│   └── debian/                  #   Package mapping + kas verification
│
├── tests/                       # ← VALIDATES YOUR IMAGES
│   ├── nixos/                   #   NixOS backend tests (cluster, smoke, network)
│   ├── debian/                  #   Debian backend tests (cluster, boot, swupdate)
│   └── lib/                     #   Shared test builders and phase scripts
│
├── infra/                       # CI/CD infrastructure
│   ├── nixos-runner/            #   NixOS runner configurations
│   └── pulumi/                  #   AWS EC2 provisioning
│
├── manifests/                   # Kubernetes manifests
├── secrets/                     # Encrypted secrets (SOPS)
└── docs/                        # Documentation
```

## Target Hardware

| Platform           | Architecture | Use Case               |
|--------------------|-------------|------------------------|
| AMD V3000          | x86_64      | Industrial edge gateway |
| Jetson Orin Nano   | aarch64     | Edge AI/ML workloads   |
| Intel N100 miniPCs | x86_64      | Development / prototype |
| QEMU VMs           | x86_64      | Testing (no hardware)  |

## CI/CD Pipeline

GitHub Actions runs 22 jobs on every push and pull request. All jobs start simultaneously — no cross-tier dependencies.

![CI Pipeline](docs/diagrams/ci-pipeline.drawio.svg)

- **Tier 1**: Fast Nix-only checks — evaluation, formatting, semver, package parity
- **Tier 2**: Nix builds `.deb` packages for both architectures
- **Tier 3**: NixOS VM tests — single `nix build` per test (KVM-accelerated)
- **Tier 4**: ISAR image builds for all 4 target machines via `kas-container`
- **Tier 5**: Debian VM tests — ISAR build + Nix store registration + NixOS test driver

Nix store caching uses [`magic-nix-cache-action`](https://github.com/DeterminateSystems/magic-nix-cache-action) backed by GitHub Actions cache. See [`docs/ci.md`](docs/ci.md) for the full pipeline reference.

## Documentation

> **[Full Documentation Map](docs/README.md)** — Navigable index of every document, diagram, and guide in this project.

Key entry points:

- [`docs/GETTING-STARTED.md`](docs/GETTING-STARTED.md) — Guided walkthrough for all developer paths
- [`backends/debian/README.md`](backends/debian/README.md) — Debian backend build guide
- [`backends/nixos/README.md`](backends/nixos/README.md) — NixOS backend build and deployment guide
- [`tests/README.md`](tests/README.md) — Test framework and full test catalog
- [`infra/README.md`](infra/README.md) — CI/CD infrastructure (AWS + NixOS runners)
- [`docs/SECRETS-SETUP.md`](docs/SECRETS-SETUP.md) — SOPS/age secrets management
- [`RELEASE.md`](RELEASE.md) — Versioning and release process
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — Contribution guidelines and commit conventions
