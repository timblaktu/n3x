# n3x System Architecture

Architecture diagrams for the n3x declarative K3s cluster framework.
Rich editing version: [`n3x-architecture.drawio.svg`](n3x-architecture.drawio.svg) (open in DrawIO desktop).

## System Architecture

The Nix flake is the outermost evaluation boundary. Everything — both backends,
all tests, all verification — is instantiated by `nix flake check` / `nix build`.

```mermaid
flowchart TB
    subgraph FLAKE["NIX FLAKE — Evaluation Boundary"]
        direction TB

        subgraph DATA["SHARED DATA LAYER"]
            direction LR
            PROFILES["Network Profiles\nlib/network/profiles/\nsimple | vlans | bonding-vlans | dhcp-simple"]
            NETGEN["mk-network-config.nix\nProfile → NixOS modules\nProfile → .network files"]
            K3SGEN["mk-k3s-flags.nix\nProfile → K3s CLI flags"]
            PKGMAP["package-mapping.nix\nNix pkg ↔ Debian .deb"]
            VERIFY["verify-kas-packages.nix\nEval-time: lib.seq + throw"]

            PROFILES --> NETGEN
            PROFILES --> K3SGEN
            PKGMAP --> VERIFY
        end

        subgraph NIXOS["NixOS BACKEND"]
            direction LR
            NIXMOD["NixOS Modules\nsystemd.network, K3s units\nKyverno, Longhorn, Flannel"]
            NIXCFG["nixosConfigurations\nmkNixOSConfig per node\nbuild+test = 1 derivation"]
            NIXOUT["Outputs\nqcow2/raw, AMI images\nnixos-rebuild"]
            NIXINFRA["Deployment Tools\ndisko, sops-nix\nnixos-anywhere\njetpack-nixos"]
            NIXDEB["Nix-built .deb\nk3s, k3s-system-config"]

            NIXMOD --> NIXCFG --> NIXOUT
        end

        subgraph ISAR["DEBIAN BACKEND"]
            direction LR
            KAS["kas YAML Overlays\nbase × machine × packages\n× image × boot × network × node"]
            KASCTR["kas-container\nPodman/Docker\nBitBake + Debian Trixie"]
            WIC[".wic Images\nGPT + GRUB + rootfs\nPer machine × role"]
            ISARNET["Pre-generated configs\n.network/.netdev files"]
            SWU["SWUpdate\nA/B OTA updates"]

            KAS --> KASCTR --> WIC
        end

        subgraph TESTS["TEST INFRASTRUCTURE — both backends converge here"]
            direction LR
            DRIVER["NixOS Test Driver\nPython scripts\nQEMU/KVM multi-VM"]
            ARTIFACTS["debian-artifacts.nix\n.wic hash registry"]
            MATRIX["Test Matrix\nProfile(4) × Backend(2)\n= 16+ cluster tests"]
            PARITY["Package Parity\nNix ↔ Debian\neval-time enforcement"]
            K3S["K3s Cluster\nServer + Agent\nKyverno, Longhorn\nFlannel, systemd-networkd"]
        end

        subgraph HW["HARDWARE TARGETS"]
            direction LR
            N100["Intel N100\nx86_64 (NixOS)"]
            V3000["AMD V3000\nx86_64 (Debian)"]
            JETSON["Jetson Orin Nano\nARM64 (Debian)"]
            QEMU["QEMU VMs\nx86/ARM (both)"]
            EC2["EC2 Instances\nx86 + Graviton"]
        end

        DATA --> NIXOS
        DATA --> ISAR
        NIXOS --> TESTS
        ISAR --> TESTS
        TESTS --> HW
    end

    NIXDEB -. ".deb packages" .-> KAS
    NETGEN -. ".network files" .-> ISARNET
    WIC -. "hash registry" .-> ARTIFACTS
```

## Test Layer Progression

```mermaid
flowchart LR
    L1["L1: Boot\n15-30s"] --> L2["L2: Network\n30-60s"]
    L2 --> L3["L3: K3s Service\n60-90s"]
    L3 --> L4["L4: Cluster\n2-5min"]
    L4 --> L4P["L4+: Advanced\n5-15min"]

    subgraph INFRA["Both backends use same test driver"]
        NIXTEST["nixosTest\nVM Framework"]
        QEMUTEST["QEMU/KVM\nMulti-VM topology"]
        BACKDOOR["nixos-test-backdoor\nSerial console control"]
    end
```

## Cross-Backend Artifact Flow

Invisible in most diagrams but architecturally critical:

```mermaid
flowchart LR
    subgraph NIX_BUILDS["Built by Nix"]
        DEB[".deb packages\nk3s, k3s-system-config"]
        NETFILES[".network/.netdev files\nfrom mk-network-config.nix"]
    end

    subgraph ISAR_CONSUMES["Consumed by Debian Backend"]
        RECIPES["BitBake recipes\ninstall .deb into rootfs"]
        OVERLAY["kas network overlay\ncopies .network files"]
    end

    subgraph ISAR_PRODUCES["Debian Backend produces"]
        WICIMG[".wic disk images"]
    end

    subgraph NIX_TESTS["Consumed by Nix tests"]
        REGISTRY["debian-artifacts.nix\nhash registry"]
        TESTDRV["Test derivations\nQEMU boot + verify"]
    end

    DEB --> RECIPES
    NETFILES --> OVERLAY
    RECIPES --> WICIMG
    OVERLAY --> WICIMG
    WICIMG --> REGISTRY --> TESTDRV
```

## Eval-Time Verification

`nix flake check --no-build` catches errors before any build:

| Check | Mechanism | Catches |
|-------|-----------|---------|
| Package parity | `lib.seq` + `throw` | Missing Debian packages in kas overlays |
| Module types | NixOS module system | Invalid config values, missing options |
| Derivation inputs | Nix evaluator | Missing files, broken references |

This is a fundamental Nix property, not CI-specific. Works identically
on a developer laptop and in a CI pipeline.

## Component Responsibilities

| Layer | Component | Responsibility |
|-------|-----------|----------------|
| **Shared Data** | Network Profiles | Pure data: IPs, interfaces, VLANs, bonds |
| **Shared Data** | mk-network-config.nix | Profile → NixOS modules or .network files |
| **Shared Data** | mk-k3s-flags.nix | Profile → K3s server/agent CLI flags |
| **Shared Data** | package-mapping.nix | Nix ↔ Debian package name mapping |
| **Shared Data** | verify-kas-packages.nix | Eval-time parity enforcement |
| **NixOS** | NixOS Modules | Declarative host config (network, K3s, add-ons) |
| **NixOS** | nixosConfigurations | Per-node configs, build+test = 1 derivation |
| **NixOS** | Deployment tools | disko, sops-nix, nixos-anywhere, jetpack-nixos |
| **NixOS** | Nix-built .deb | k3s binary + system config as Debian packages |
| **Debian** | kas YAML overlays | Compositional build parameterization |
| **Debian** | kas-container | Containerized BitBake execution |
| **Debian** | .wic images | Bootable disk images per machine × role |
| **Debian** | SWUpdate | A/B partition OTA updates |
| **Test** | NixOS Test Driver | Python-scripted multi-VM integration tests |
| **Test** | debian-artifacts.nix | .wic hash registry for Debian test derivations |
| **Test** | Package Parity | Nix ↔ Debian equivalence verification |
| **Hardware** | Intel N100 | x86_64 cluster nodes (NixOS) |
| **Hardware** | AMD V3000 | x86_64 edge compute (Debian) |
| **Hardware** | Jetson Orin Nano | ARM64 edge compute (Debian) |
| **Hardware** | EC2 Instances | x86 + Graviton CI runners (NixOS) |

## Key Design Principles

1. **Nix Flake as Container**: The flake evaluation boundary encompasses all builds, tests, and verification
2. **Shared Data Layer**: Both backends consume the same profiles through the same transformation functions
3. **Dual Backend Architecture**: NixOS and Debian (ISAR) as parallel backends — same abstractions, different build systems
4. **Cross-Backend Artifacts**: Nix builds .deb packages and generates network configs consumed by the Debian backend
5. **Test Convergence**: Both backends are VM-tested using the same NixOS test driver and QEMU/KVM
6. **Eval-Time Verification**: `nix flake check --no-build` catches configuration errors before any build starts
7. **Declarative Everything**: Network, disk, K3s config all generated from pure data profiles

## Related Diagrams

- **Debian Backend**: [`n3x-debian-backend.drawio.svg`](n3x-debian-backend.drawio.svg) — kas overlay composition, build stack, configuration hierarchy
- **NixOS Backend**: [`n3x-nixos-backend.drawio.svg`](n3x-nixos-backend.drawio.svg) — module composition, deployment paths, flake inputs
- **CI Pipeline**: [`ci-pipeline.drawio.svg`](ci-pipeline.drawio.svg) — GitLab stages, runner infrastructure, cache mesh
- **Build & Caching**: [`build-caching.drawio.svg`](build-caching.drawio.svg) — build pipeline, cache topology, Harmonia
