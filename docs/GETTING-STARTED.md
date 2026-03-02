# Getting Started with n3x

n3x supports multiple OS backends — each with its own build tools and workflow. Choose the section that matches what you want to do. If you're unsure which backend to use, start with the one your team already knows.

## Quick Start: Find Your Path

### "I want to add a Debian application package"

**Level 0** — Work in `backends/debian/packages/`

```bash
cp -r backends/debian/packages/template backends/debian/packages/my-app
# Edit debian/control, add your code
nix build '.#packages.x86_64-linux.my-app'
```

**See**: [packages/README.md](../backends/debian/packages/README.md)

**Prerequisites**: Git, basic Debian packaging

---

### "I want to build or modify system images"

**Level 1** — Work in your backend's directory

**Debian backend** (`backends/debian/`) — builds disk images using [kas](https://github.com/siemens/kas)/[ISAR](https://github.com/ilbers/isar):

```bash
nix develop
cd backends/debian
kas-build kas/base.yml:kas/machine/qemu-amd64.yml:kas/image/k3s-server.yml:...
```

Or use the Nix build matrix to build and register all variants:

```bash
nix run '.' -- --list     # Show all 16 build variants
nix run '.' -- --variant server-simple-server-1
```

**See**: [backends/debian/README.md](../backends/debian/README.md), [BSP-GUIDE.md](../backends/debian/BSP-GUIDE.md)

**Prerequisites**: Git, BitBake/kas basics

**NixOS backend** (`backends/nixos/`) — builds host configurations using [Nix](https://nixos.org/learn):

```bash
# Build a host configuration
nix build '.#nixosConfigurations.n100-1.config.system.build.toplevel'

# Deploy to a running host
nixos-rebuild switch --flake '.#n100-1' --target-host root@n100-1
```

**See**: [backends/nixos/README.md](../backends/nixos/README.md)

**Prerequisites**: Git, Nix basics

---

### "I want to run or write tests"

**Level 2** — Look at `tests/`

Both backends use the same test harness (NixOS test driver with QEMU/KVM):

```bash
# Debian backend test
nix build '.#checks.x86_64-linux.debian-cluster-simple' -L

# NixOS backend test
nix build '.#checks.x86_64-linux.k3s-cluster-simple' -L
```

**See**: [tests/README.md](../tests/README.md)

**Prerequisites**: Git, Nix basics, Python basics (for test scripts)

---

### "I want to modify network profiles, K3s topology, or the test framework"

**Level 3** — Work in `lib/` and `tests/lib/`

The shared `lib/` directory defines network profiles, K3s topology, and package requirements once. Each backend consumes them in its native format. Changes here affect both backends.

```
lib/network/profiles/     → Network topology definitions (IPs, VLANs, bonds)
lib/network/              → Config generators (NixOS modules + .network/.netdev files)
lib/k3s/                  → K3s flag generation from cluster topology
lib/debian/               → Debian package mapping + kas verification
tests/lib/                → Shared test builders and phase scripts
```

**See**: [lib/network/README.md](../lib/network/README.md), [lib/k3s/README.md](../lib/k3s/README.md), [tests/README.md](../tests/README.md)

**Prerequisites**: Git, Nix fluency, understanding of the shared abstraction layer

---

## Prerequisites by Level

| Level | Git | Debian Pkg | BitBake/kas | Nix | Python |
|-------|:---:|:----------:|:-----------:|:---:|:------:|
| 0 — Add packages | Yes | Basic | - | - | - |
| 1 — Build images (Debian) | Yes | - | Basic | - | - |
| 1 — Build images (NixOS) | Yes | - | - | Basic | - |
| 2 — Run tests | Yes | - | - | Basic | Basic |
| 3 — Modify shared config | Yes | - | - | Fluent | Basic |

## Repository Structure

```
n3x/
├── backends/
│   ├── debian/packages/  # Level 0: Debian packages (most common starting point)
│   ├── debian/           # Level 1: Debian/ISAR image builds
│   └── nixos/            # Level 1: NixOS host configurations
├── tests/                # Level 2: VM test infrastructure (both backends)
├── lib/                  # Level 3: Shared network/K3s/package abstractions
├── docs/                 # Documentation
└── flake.nix             # Nix flake definition
```

## Next Steps

1. Identify your task from the paths above
2. Read the linked documentation for your level
3. Ask questions if stuck
