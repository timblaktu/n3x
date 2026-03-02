# NixOS Backend for n3x

This directory contains the NixOS backend for the n3x K3s cluster platform. NixOS provides declarative, reproducible system configurations using composable modules.

## Architecture

![NixOS Backend Architecture](../../docs/diagrams/n3x-nixos-backend.drawio.svg)

*Module composition, network integration, test infrastructure, deployment paths, and flake inputs.
See also: [System Architecture](../../docs/diagrams/n3x-architecture.drawio.svg) | [Debian Backend](../../docs/diagrams/n3x-debian-backend.drawio.svg) | [CI Pipeline](../../docs/diagrams/ci-pipeline.drawio.svg)*

## Directory Structure

```
backends/nixos/
├── disko/                        # Disk partitioning layouts
│   ├── n100-standard.nix        #   Standard ext4 (EFI + boot + swap + root)
│   ├── n100-zfs.nix             #   ZFS-backed layout
│   └── vm-test.nix              #   Minimal VM test layout
│
├── hosts/                        # Per-node configurations
│   ├── n100-1/                  #   K3s server (cluster init)
│   ├── n100-2/                  #   K3s server
│   ├── n100-3/                  #   K3s agent
│   ├── jetson-1/                #   K3s agent (aarch64)
│   └── jetson-2/                #   K3s agent (aarch64)
│
├── modules/                      # Composable NixOS modules
│   ├── common/                  #   base, networking, nix-settings
│   ├── hardware/                #   n100, jetson-orin-nano
│   ├── kubernetes/              #   k3s-storage, longhorn, kyverno
│   ├── network/                 #   bonding, vlans, multus
│   ├── roles/                   #   k3s-server, k3s-agent (+secure variants)
│   └── security/                #   secrets (SOPS)
│
└── vms/                          # VM test configurations
    ├── default.nix              #   Base VM config (UEFI, KVM, port forwarding)
    ├── k3s-server-vm.nix        #   Server VM
    ├── k3s-agent-vm.nix         #   Agent VM
    └── multi-node-cluster.nix   #   Multi-node test cluster
```

## Host Configurations

| Host | Arch | Role | Hardware | Key Modules |
|------|------|------|----------|-------------|
| n100-1 | x86_64 | K3s server (init) | Intel N100 | hardware/n100, roles/k3s-server, network/bonding |
| n100-2 | x86_64 | K3s server | Intel N100 | hardware/n100, roles/k3s-server, network/bonding |
| n100-3 | x86_64 | K3s agent | Intel N100 | hardware/n100, roles/k3s-agent, network/bonding |
| jetson-1 | aarch64 | K3s agent | Orin Nano | hardware/jetson-orin-nano, roles/k3s-agent, network/bonding |
| jetson-2 | aarch64 | K3s agent | Orin Nano | hardware/jetson-orin-nano, roles/k3s-agent, network/bonding |

## Module Composition

The `flake.nix` defines `mkSystem` and `mkVMSystem` helpers that compose modules into full configurations:

```
mkSystem { hostname, system, modules }
    → common/base.nix + common/nix-settings.nix + common/networking.nix
    → hosts/<hostname>/configuration.nix
    → ...additional modules (hardware, roles, network)
```

Each host selects its hardware module, k3s role, and network module. The composition is visible in `flake.nix` under `nixosConfigurations`.

## Usage

```bash
# Build a host configuration
nix build '.#nixosConfigurations.n100-1.config.system.build.toplevel'

# Deploy to a running host
nixos-rebuild switch --flake '.#n100-1' --target-host root@n100-1

# Provision a new bare-metal host (first install)
nixos-anywhere --flake '.#n100-1' root@<ip>

# Build a VM for local testing
nix build '.#nixosConfigurations.vm-k3s-server.config.system.build.vm'
```

## Relationship to Shared Libraries

Network profiles in `lib/network/profiles/` are the single source of truth for both backends:

- **NixOS**: `lib/network/mk-network-config.nix` transforms profiles into NixOS `systemd.network` module options
- **Debian**: `lib/network/mk-systemd-networkd.nix` transforms profiles into `.network`/`.netdev` config files
- **K3s flags**: `lib/k3s/mk-k3s-flags.nix` generates CLI flags from profile data for both backends

## See Also

- [`backends/debian/README.md`](../debian/README.md) -- Debian backend (parallel implementation)
- [`tests/README.md`](../../tests/README.md) -- Test framework (uses NixOS modules for VM test nodes)
- [`lib/network/README.md`](../../lib/network/README.md) -- Network profiles and generators
- [`lib/k3s/README.md`](../../lib/k3s/README.md) -- K3s flag generation
