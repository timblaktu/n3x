# CLAUDE.md - Project Memory and Rules

This file provides project-specific rules and essential context for Claude Code when working with the n3x repository.

## Critical Rules

### Git Commit Practices
1. **COMMIT FREQUENTLY** - Don't accumulate changes across multiple files before committing. Commit each logical change as you make it. Small, frequent commits are better than large batches. This also serves as implicit flake verification (see rule 3).
2. **Committing IS your flake check** - The Nix-managed pre-commit hook (`core.hooksPath`) runs `nix flake check --no-build` automatically. Do NOT run `nix flake check` manually before committing — just commit and let the hook verify. If the commit succeeds, the flake is valid. If the hook fails, fix and re-commit. The hook also auto-formats `.nix` files with `nixpkgs-fmt` and re-stages them. The hook args are not immutable — if a better approach is found, update the hook in nixcfg. **For doc-only commits**, skip the hook with `SKIP_FLAKE_CHECK=1 git commit -m "message"` to avoid the ~2min eval time.
3. **NEVER include AI/Claude attributions in commits** - No "Co-Authored-By: Claude", no "Generated with Claude", no Anthropic mentions.
4. **Do NOT commit temporary files** - Never stage files created for temporary purposes.

### Task Completion Standards
5. **Test tasks require PASS to be COMPLETE** - A task to "run test X" is NOT complete if the test fails. Documenting a failure is progress, but the task stays `IN_PROGRESS` until the test passes. Do NOT move to the next task until the current test-based task passes.
6. **NEVER mark failed tests as "complete with documentation"** - This creates tech debt breadcrumbs. Fix issues before moving on.

### Backend Parity Requirements
7. **NEVER defer tests for perceived redundancy** - This project establishes a parameterized embedded Linux build matrix. Every test that exists for one backend MUST be run for all backends. Do NOT make judgment calls about "overlapping" tests or "same code path" - run ALL tests to verify actual parity. The goal is identical test coverage across NixOS and Debian backends.
8. **Test parity is non-negotiable** - If NixOS has a test (simple, vlans, bonding-vlans, dhcp-simple), the Debian backend must have and pass the same test. No exceptions.

### Container Image Pinning
9. **Use `tag@digest` syntax for container images** - Provides determinism (digest) + visibility (tag):
   ```yaml
   # CORRECT: tag for humans, digest for machines
   image: ghcr.io/siemens/kas/kas-isar:5.1@sha256:c60d32d7d6943e114affad0f8a0e9ec6d4c163e636c84da2dd8bde7a39f2a9bd

   # WRONG: mutable tag only
   image: ghcr.io/siemens/kas/kas-isar:5.1
   ```
   - Digest is authoritative for pulling (reproducibility)
   - Tag is documentation for humans (version visibility)
   - Get digest: `docker images --digests <image>`

### NixOS Test Driver & QEMU Process Management
10. **Orphaned nix build cleanup** - Prefer SIGTERM over SIGKILL (WSL mount safety):
   ```bash
   sudo kill -TERM <pid>; sleep 5; sudo kill -INT <pid>  # SIGKILL only as last resort
   ```
   If mounts break: `nix run '.#wsl-remount'` or `wsl --shutdown`

11. **PROACTIVE log monitoring** - Use `-L` flag, check BashOutput frequently, kill early on failure patterns.

12. **VM test parallelism limits** - Each VM uses 1-4 vCPUs + 1-4GB RAM. Limit concurrent VMs to avoid CPU saturation:
   - **Single-VM tests** (L1-L3: vm-boot, server-boot, service, network-*, swupdate-*): Up to 4 tests in parallel
   - **Two-VM tests** (L2: two-vm-network): Up to 2 tests in parallel
   - **Cluster tests** (L4: cluster-*): Run at most 2 in parallel (4 VMs total), prefer sequential
   - **Bonding cluster tests**: Run ONE at a time (each VM has bond + VLANs, heavy on CPU)
   - Evidence: cluster-bonding-vlans-direct took 86s solo vs 326s when 3 cluster tests ran simultaneously

13. **Session cleanup** - Verify no orphaned processes before new tests:
   ```bash
   pgrep -a qemu 2>/dev/null || echo "No QEMU"; pgrep -a nixos-test-driver 2>/dev/null || echo "No drivers"
   ```

## Build Quick Reference

```bash
# Flake verification (pre-commit hook runs this automatically)
nix flake check --no-build

# NixOS VM tests (L4 cluster, 4 profiles × 2 boot modes)
nix build '.#checks.x86_64-linux.k3s-cluster-simple' -L
nix build '.#checks.x86_64-linux.debian-cluster-simple' -L

# ISAR image builds (preferred workflow)
nix run '.'                              # Build ALL 16 variants
nix run '.' -- --variant base            # Build one variant
nix run '.' -- --list                    # Show all variants

# Interactive test debugging
nix build '.#checks.x86_64-linux.k3s-cluster-simple.driverInteractive'
./result/bin/nixos-test-driver --interactive
```

**Detailed procedures**: `.ai/skills/isar-build.md` (ISAR builds), `.ai/skills/image-testing.md` (VM tests)

## Project Status

- **Release**: 0.0.3 (tagged, published with release notes)
- **Test Infrastructure**: Fully integrated NixOS + Debian backends, 16-test parity matrix
- **BitBake Limits**: BB_NUMBER_THREADS=dynamic (min(CPUs, (RAM_GB-4)/3)), BB_PRESSURE_MAX_MEMORY=10000
- **ISAR Build Matrix**: 42 artifacts across 4 machines (qemuamd64, amd-v3c18i, qemuarm64, jetson-orin-nano)
  - All hashes tracked in `lib/debian/artifact-hashes.nix`
  - VM test results: 18 PASS, 1 EXCLUDED (swupdate-boot-switch)
  - `nix run '.'` is the default app (`isar-build-all`)

### Architecture

**GitHub Actions CI** (current, `.github/workflows/ci.yml`):
- Tiered pipeline: eval/lint → deb packages → NixOS VM tests → ISAR builds → Debian VM tests
- x86_64 on `ubuntu-latest`, aarch64 on `ubuntu-24.04-arm` (Cobalt 100)
- KVM-accelerated VM tests on GitHub-hosted runners
- `magic-nix-cache-action` for Nix store caching

### AI Agent Architecture (2026-02-26)

**Design principle**: Project provides context and procedures, users provide tools and credentials.

**Cross-tool compatibility**:
- `CLAUDE.md` is the universal project instructions file (Claude Code reads natively, OpenCode reads as fallback)
- `.ai/skills/` is the single source of truth for shared procedures, with symlinks from `.claude/skills/` and `.opencode/agents/`
- `.claude/rules/` and `.opencode/rules/` are extension points for the internal fork to add context without modifying public files

**Internal fork additive pattern**: The fork ONLY adds files — never modifies public repo files. Extension directories (`.claude/rules/`, `.opencode/rules/`) are empty on the public repo and populated on the fork with `internal-context.md`. The fork's `opencode.json` is the one intentional divergence (model endpoint configuration).

### ISAR Package Parity

Package requirements are verified at **Nix eval time**. Missing packages fail `nix flake check --no-build` immediately.

```
lib/debian/package-mapping.nix  →  Defines required packages (Nix→Debian mapping)
        ↓
lib/debian/verify-kas-packages.nix  →  Verifies kas YAMLs contain packages
        ↓
nix flake check --no-build  →  Fails if packages missing from kas overlays
```

See: [tests/README.md](tests/README.md#debian-backend-package-parity-verification-plan-016) for details.

### Key Architecture
- **Profiles** export data only (ipAddresses, interfaces, vlanIds)
- **mkNixOSConfig** transforms data → NixOS systemd.network modules
- **mkSystemdNetworkdFiles** transforms data → ISAR .network/.netdev files
- **mkK3sFlags.mkExtraFlags** transforms data → k3s CLI flags

### Test Commands
```bash
# NixOS tests
nix build '.#checks.x86_64-linux.k3s-cluster-simple'
nix build '.#checks.x86_64-linux.k3s-cluster-vlans'
nix build '.#checks.x86_64-linux.k3s-cluster-bonding-vlans'

# Debian backend tests
nix build '.#checks.x86_64-linux.debian-cluster-simple' -L
nix build '.#checks.x86_64-linux.debian-network-debug' -L
```

## Technical Learnings

### Nix Eval-Time Verification with lib.seq

**Problem**: `passthru` attributes on derivations aren't evaluated during `nix flake check` unless explicitly accessed. A verification that uses `passthru.verified = throw "error"` will silently pass.

**Solution**: Use `lib.seq` to force evaluation before derivation instantiation:
```nix
# WRONG: passthru.verified not evaluated during flake check
pkgs.runCommand "check" {} '' ... '' // { passthru.verified = verified; }

# RIGHT: lib.seq forces 'verified' to evaluate, throw fires at eval time
lib.seq verified (pkgs.runCommand "check" {} '' ... '')
```

**Use case**: Static verification checks that must fail during `nix flake check --no-build` rather than during the build phase.

### ISAR Test Framework
- Use NixOS VM Test Driver with ISAR-built .wic images (NOT Avocado)
- Test images need `nixos-test-backdoor` package via `kas/test-k3s-overlay.yml`
- VM derivation names must NOT use `run-<name>-vm` pattern

### ISAR Builds - CRITICAL

**Claude Code CAN and SHOULD run ISAR builds** using `nix develop -c`:

```bash
# CORRECT - Claude Code can run this directly
nix develop -c bash -c "cd backends/debian && kas-build kas/base.yml:kas/machine/qemu-amd64.yml:kas/packages/k3s-core.yml:kas/packages/debug.yml:kas/image/k3s-server.yml:kas/test-k3s-overlay.yml:kas/network/simple.yml:kas/node/server-1.yml"

# ALSO CORRECT - interactive shell then kas-build
nix develop
cd backends/debian
kas-build kas/base.yml:...

# WRONG - direct docker/podman bypasses kas-container, causes git safe.directory errors
docker run ... ghcr.io/siemens/kas/kas-isar:5.1 build ...
```

**The constraint is about DIRECT docker/podman invocation, NOT about Claude's ability to run builds.**

**Why kas-build wrapper is required**: The wrapper calls `kas-container --isar build`, which:
1. Handles user namespace mapping (prevents git safe.directory errors)
2. Manages WSL 9p filesystem unmounting (prevents sgdisk sync() hang)
3. Sets `KAS_CONTAINER_ENGINE=podman` and correct image version

**Build command structure**:
```
kas-build kas/base.yml:kas/machine/<machine>.yml:kas/packages/k3s-core.yml:kas/packages/debug.yml:kas/image/<role>.yml:kas/boot/grub.yml:kas/test-k3s-overlay.yml:kas/network/<profile>.yml:kas/node/<node>.yml
```

**CRITICAL**: Include `kas/boot/grub.yml` for correct GRUB bootloader with:
- `net.ifnames=0 biosdevname=0` - Legacy eth* naming for NixOS test driver
- `quiet loglevel=1` - Clean hvc0 for backdoor shell protocol
- `extra-space 512M` - Space for k3s runtime extraction

**Additional rules**:
- **ASK before rebuilds** - prefer test-level fixes over image changes
- **See `.claude/skills/isar-build.md`** for detailed procedures

### ISAR Build Matrix and `isar-build-all` (THE Primary Workflow)

**`nix run '.'`** is the default app and the command everyone should use. It orchestrates the
entire ISAR build matrix: build → rename → hash → register in nix store → update hashes file.

```bash
# Primary workflow commands:
nix run '.' -- --list                    # Show all 16 build variants
nix run '.' -- --variant base            # Build one variant
nix run '.' -- --machine qemuamd64       # Build all variants for one machine
nix run '.'                              # Build ALL 16 variants

# Post-build registration (skip kas-build, just register existing outputs):
nix run '.' -- --variant base-swupdate --rename-existing   # Rename + hash + register
nix run '.' -- --variant base-swupdate --hash-only         # Hash + register only

# Also accessible as:
nix run '.#isar-build-all' -- --help
```

**Three-file architecture** (critical to understand):
1. **`lib/debian/build-matrix.nix`** - Single source of truth for 16 variants.
   Defines machines, roles, boot modes, naming functions (`mkVariantId`, `mkArtifactName`,
   `mkIsarOutputName`, `mkAttrPath`, `mkKasCommand`).
2. **`lib/debian/artifact-hashes.nix`** - Mutable state: SHA256 hashes for all 42 artifacts.
   Updated by `isar-build-all` via sed after each build.
3. **`lib/debian/mk-artifact-registry.nix`** - Generator combining build-matrix + hashes
   into a `requireFile` attrset. Powers `isarArtifacts.qemuamd64.server.wic` etc.

**Why this matters**: Every ISAR VM test depends on artifacts being in the nix store.
`requireFile` fails at build time if the artifact is missing. `isar-build-all` is the ONLY
workflow that ensures artifacts are properly named, hashed, and registered.

**Key detail**: `base` and `base-swupdate` variants produce the SAME ISAR output filename
(`n3x-image-base-debian-trixie-qemuamd64.wic`) because they share `role = "base"`.
The `--rename-existing` flag copies to unique names to avoid collisions.

### ISAR VM Interface Naming

**QEMU NIC ordering**: net0 (user, restricted) is added first, then vlan1 (VDE switch).
- **With `net.ifnames=0`** (server/agent images via boot overlay): `eth0` (user), `eth1` (VDE)
- **Without `net.ifnames=0`** (base/swupdate images): `enp0s2` (user), `enp0s3` (VDE)
- The VDE switch is ALWAYS the second NIC device.
- Tests that use swupdate images must use `enp0s3` for cluster networking.
- Tests that use server/agent images use `eth1` for cluster networking.

### ISAR Recipe Cleaning and Build State Management

**NEVER manually delete build state files** (stamps, work dirs, sstate). Use kas-container's built-in cleaning commands:

```bash
# Clean specific recipe's build artifacts (keeps sstate and downloads)
# Use this when a recipe fails and needs rebuild
nix develop -c bash -c "cd backends/debian && kas-container --isar clean kas/machine/<machine>.yml:..."

# Clean build artifacts + sstate cache (keeps downloads)
# Use this for deeper clean - forces rebuild of all recipes
nix develop -c bash -c "cd backends/debian && kas-container --isar cleansstate kas/machine/<machine>.yml:..."

# Clean everything including downloads
# Nuclear option - full rebuild from scratch
nix develop -c bash -c "cd backends/debian && kas-container --isar cleanall kas/machine/<machine>.yml:..."
```

**Stale `.git-downloads` symlink** (common issue):
- Each kas-container session creates a new tmpdir (`/tmp/tmpXXXXXX`); `.git-downloads` symlink in the build work dir points to the previous session's tmpdir
- **Fix**: Remove before EVERY new build after a container session change:
  ```bash
  rm -f backends/debian/build/tmp/work/debian-trixie-arm64/.git-downloads
  rm -f backends/debian/build/tmp/work/debian-trixie-amd64/.git-downloads
  ```

**Download cache collision** (multi-arch):
- k3s recipe uses `downloadfilename=k3s` for BOTH architectures — x86_64 and arm64 binaries share the same cache key
- If switching architectures (e.g., qemuamd64 → jetson-orin-nano), the cached `k3s` binary is the wrong architecture
- **Fix**: Delete the cached binary AND its fetch stamps:
  ```bash
  rm -f ~/.cache/yocto/downloads/k3s ~/.cache/yocto/downloads/k3s.done
  rm -f backends/debian/build/tmp/stamps/debian-trixie-arm64/k3s-server/1.32.0-r0.do_fetch*
  rm -f backends/debian/build/tmp/stamps/debian-trixie-arm64/k3s-agent/1.32.0-r0.do_fetch*
  ```
- TODO: Fix k3s recipe to use arch-specific `downloadfilename` (e.g., `k3s-arm64` or `k3s-amd64`)

### ISAR Build Cache
- Shared cache: `DL_DIR="${HOME}/.cache/yocto/downloads"`, `SSTATE_DIR="${HOME}/.cache/yocto/sstate"`
- kas-container mounts these host paths at `/downloads` and `/sstate` inside the container
- base.yml hardcodes `DL_DIR = "/downloads"` and `SSTATE_DIR = "/sstate"` (the stable mount points)
- **WARNING**: Do NOT use `${HOME}` in kas `local_conf_header` — inside the container, kas overrides HOME to an ephemeral tmpdir (`/tmp/tmpXXXXXX`), so any path referencing `${HOME}` is destroyed on exit (siemens/kas#148)
- CI sets its own `DL_DIR`/`SSTATE_DIR` values which the wrapper respects via `${VAR:-default}` pattern

### Test Timing Patterns

**"It works sometimes" = Timing Bug**. Diagnose with:
- ICMP works but TCP fails? → TCP establishment latency (add warm-up loop)
- Works on retry? → Missing readiness check (use `wait_until_succeeds`)
- Fails under load? → Fixed delay too short (replace `time.sleep` with polling)

**Avoid**: `time.sleep(N)` for service/network readiness
**Prefer**: Poll for expected condition with timeout

**Reference fix** (bonding-vlans TCP latency):
```python
# WRONG: Assume network ready after fixed delay
time.sleep(2)
server_2.succeed("systemctl start k3s-server.service")

# RIGHT: Warm up TCP connection before starting service
for attempt in range(3):
    code, out = server_2.execute("timeout 15 curl -sk https://server-1:6443/cacerts")
    if code == 0 or "cacerts" in out.lower():
        break
    time.sleep(2)
server_2.succeed("systemctl start k3s-server.service")
```

**Resolved latent issues**:
- Bond state verification via `/proc/net/bonding/bond0`
- Replaced `time.sleep(2)` with `wait_until_succeeds` IP polling

### SWUpdate Apply Test Flakiness (2026-02-27)

**Symptom**: `debian-test-swupdate-apply` fails intermittently in CI at Test 6 — `swupdate -v -k cert.pem -i update-bundle.swu` exits with code 1. Passes on retry and on concurrent workflow runs for the same commit.

**Root cause**: Race between grubenv creation and swupdate invocation. SWUpdate's GRUB handler opens `/boot/grub/grubenv` immediately on startup. Under I/O contention on GitHub-hosted runners, the file may not be fully flushed to disk when swupdate reads it, causing an exit code 1.

**Fix applied** (all 3 swupdate tests):
1. Extracted `run_with_retry()` utility into `tests/lib/test-scripts/utils.nix` — shared across all tests
2. Added `sync` to grubenv creation command chains
3. Uses `machine.execute()` (not `succeed()`) to preserve diagnostic output on failure
4. 3-attempt retry with 2s delay, 1s settle time for filesystem sync before first attempt
5. Applied consistently to: `swupdate-apply.nix`, `swupdate-boot-switch.nix`, `swupdate-network-ota.nix`

**First observed**: PR #13 CI run `22493486475`, job `65161686503`. Passed on retry (same run) and on parallel run `22493473680`.

### WIC Generation Hang (WSL2)
- Cause: `sgdisk` sync() hangs on 9p mounts
- Solution: `kas-build` wrapper handles mount/unmount automatically

### Platform Support
| Platform | nixosTest Multi-Node |
|----------|---------------------|
| Native Linux | YES |
| WSL2 | YES |
| Darwin | YES* |

### ISAR Kernel Selection Mechanism

**ISAR does NOT use Yocto's `PREFERRED_PROVIDER_virtual/kernel`.**

ISAR kernel selection uses `KERNEL_NAME`:
- `image.bbclass` sets `KERNEL_IMAGE_PKG = "linux-image-${KERNEL_NAME}"`
- `linux-kernel.bbclass` extracts `KERNEL_NAME_PROVIDED` from recipe name (e.g., `linux-tegra` → `tegra`)
- Machine conf sets `KERNEL_NAME ?= "arm64"` (default = stock Debian)
- To override: `KERNEL_NAME = "tegra"` in kas overlay `local_conf_header`

### QEMU User-Mode for ISAR aarch64 Builds

**WSL2 NixOS can build ISAR aarch64 images via QEMU user-mode emulation.**

- User's WSL kernel: Custom, based on NixOS-WSL project
- Requires binfmt_misc registration with F (fix binary) and C (credentials) flags
- Static QEMU binary from `nixpkgs#pkgsStatic.qemu-user`
- First build (stock Debian kernel, no kernel compile): ~14 minutes
- Kernel compile under QEMU TCG emulation: KILLED after 2h49m, still on do_dpkg_build
  - All 20 vCPUs pegged at 100%, 8 parallel qemu-aarch64 gcc processes
  - CPU-bound (4.5G/27.4G RAM used), no I/O bottleneck
  - TCG overhead ~10-20x vs native for compiler workloads
- **Cross-compilation fix committed (f3011b8)**: Removed ISAR_CROSS_COMPILE="0" from
  jetson-orin-nano.yml. ISAR default (="1") uses host cross-toolchain.
- **Cross-compile VALIDATED (2026-02-11)**: Kernel cross-compile succeeded in ~22 minutes
  - `CROSS_COMPILE=aarch64-linux-gnu-` confirmed in build log
  - `tegra234-enable.cfg` config fragment merged successfully
  - `linux-image-tegra` (6.12.69+r0) in image manifest
  - nvidia-l4t-core + nvidia-l4t-tools (36.4.4) installed
  - vmlinux: 40MB (tegra) vs 37MB (stock Debian arm64)
  - Full build with sstate: ~30 minutes total
  - Improvement: 22min vs 2h49m+ (killed) under TCG emulation
- Persistent binfmt config: VALIDATED (2026-02-12) — nixcfg WSL module (`binfmt.enable = true`) produces
  correct `systemd-binfmt.service` registration with POCF flags at boot. No manual registration needed.
  See `docs/binfmt-requirements.md` for details.

### Flake Input Management

- **nixos-generators**: Archived 2026-01-30, upstreamed to nixpkgs 25.05.
  **Removed as flake input** (2026-02-16): initially replaced with manual
  `system.build.amazonImage` via builder module import. **Migrated to native
  `system.build.images.amazon` API** (2026-02-16): the 25.11 image framework
  (`nixos/modules/image/images.nix`) auto-imports all 26 image builders.
  AMI-only config (e.g., `first-boot-format`) is injected via `image.modules.amazon`
  deferred module — lives only in the image variant, not the base nixosConfiguration.
- **ALWAYS use native NixOS 25.11 image APIs** (`system.build.images.*`) — not manual
  builder module imports from `maintainers/scripts/ec2/`. The `image.modules.*`
  deferred module pattern cleanly separates image-specific config from base config.
- **nixos-anywhere**: Not needed as a flake input — run from upstream flake directly.
  Was adding 14 transitive lock entries including a separate nixpkgs tree.

### NixOS 25.11 Migration Workarounds

**Migration date**: 2026-02-16. Migrated from nixpkgs master (main) to 25.11.

1. **`services.resolved.settings` → individual options** (commit `ffbedba`)
   - `services.resolved.settings.Resolve` is a master-only freeform attrset API, not on 25.11
   - File: `backends/nixos/modules/common/networking.nix:168`
   - Fix: `dnssec`, `dnsovertls`, `fallbackDns` as individual options; `DNSStubListener`,
     `ReadEtcHosts`, `Cache`, `CacheFromLocalhost` via `extraConfig`
   - WORKAROUND: When nixpkgs upstreams `services.resolved.settings` to stable, revert to
     structured attrset form. Check 26.05 release notes.

2. **ISAR test driver API: `python3Packages` as attrset** (commit `dd30372`)
   - On master, test driver accepts individual Python packages as args. On 25.11, it takes
     `python3Packages` as a single attrset.
   - File: `tests/lib/debian/mk-debian-test.nix:153-154`
   - API-ADAPTATION: Not a workaround — 25.11 API is the canonical form. Master's destructured
     args are the newer (unreleased) pattern.

3. **nixpkgs fork still required** — `virtualisation.bootDiskAdditionalSpace` not upstreamed
   - Fork: `timblaktu/nixpkgs/vm-bootloader-disk-size` rebased onto `nixos-25.11`
   - TODO: Submit upstream PR to nixpkgs, then drop fork

### README Documentation and Diagram Conventions (2026-03-01)

**Messaging priorities** (from user directive):
- Don't assume team familiarity with prior projects — the docs are fresh onboarding
- Diagrams should send clear conceptual messages WITHOUT the viewer reading prose
- Primary message: this framework automatically tests your images in virtual networks
- The "BYO" concept is central: users bring their BSP/OS backend, n3x provides testing infra

**Diagram format**: ALWAYS use DrawIO `.drawio.svg` format, NEVER Mermaid:
- Mermaid multiline text is unreliable, layout is non-deterministic, feedback loop too slow
- DrawIO gives deterministic layout; `drawio-svg-sync` renders SVG that Claude can visually verify
- After rendering, always read the SVG to catch label overlaps and positioning issues

**Full-stack emulation diagram concept** (user directive, 2026-03-01):
- The diagram must depict building a **local virtual private cloud** using open-source hyper-converged infrastructure techniques — this framing resonates with the team
- Show EXACTLY ONE test scenario (corresponding to one "high-level nix derivation")
- Multiple VMs exist WITHIN the SDN (software-defined network), like cloud VPS/VPC instances
- The network is an **environment-level** concept, not a cluster-level concept
- The single-VM layer stack (firmware→kernel→userspace→k3s→k8s) should be present but **compact** — not dominating the diagram
- Show the virtual network as you would in any cloud architecture diagram
- Cross-layer interactions (SWUpdate firmware↔userspace, GPIO power-cycling) are annotations

**Firmware layer terminology**:
- Say "UEFI/EDK2" not "BIOS/UEFI"
- Say "u-boot / GRUB / systemd-boot" not "GRUB2"
- Layer title: "Firmware" not "Firmware / Bootloader"

**DrawIO rounded rectangle labels**: Per the diagram skill (Section 18), ALWAYS calculate
the corner offset using `offset = max(0.15 * min(w, h) * 0.35, 15)` and position container
title labels inside this offset to avoid overlapping the rounded edge.

### DrawIO `.drawio.svg` Workflow for Claude Code (2026-03-01)

**Primary workflow**: Use `drawio_gen.py` (deployed to skills/diagram/) to generate diagrams
from compact JSON specs instead of constructing mxGraphModel XML inline. This reduces output
token usage by ~87% per diagram.

```bash
# Generate from JSON spec (pipe or --input)
echo '{"page":{...},"cells":[...]}' | python3 "$SKILL_DIR/drawio_gen.py" generate --output diagram.drawio.svg --render

# Utility subcommands
python3 "$SKILL_DIR/drawio_gen.py" extract diagram.drawio.svg    # decode content attr
python3 "$SKILL_DIR/drawio_gen.py" verify diagram.drawio.svg     # check integrity
python3 "$SKILL_DIR/drawio_gen.py" presets                       # list style presets
```

Where `$SKILL_DIR` is the deployed skill directory (e.g., `~/.claude-max/skills/diagram/`).
The `--render` flag runs drawio-svg-sync, re-injects content if stripped, and verifies.
See diagram skill Section 31 for JSON spec format, cell types, and preset reference.

**Rendering command** (manual): `nix run 'github:timblaktu/drawio-svg-sync' -- docs/diagrams/DIAGRAM.drawio.svg`

**Project-specific orphan status** (as of 2026-03-01): Both `n3x-full-stack-emulation.drawio.svg` and `n3x-overview.drawio.svg` have been rebuilt with `content` attributes (commits bd489e4 and 8aec68b respectively). All 8 diagrams now have embedded source. Both hero diagrams have uncommitted refinements (color-scheme fix, text/edge styling) awaiting further user feedback.

### Overview Diagram Revision Status (2026-03-01)

**User feedback on T13 (commit 9f35253)**: The "Test Scenario" tier and "n3x / shared layer" are the same concept and should be merged into a single "Nix Derivations" block at the top. The diagram must show:
1. Nix derivation outputs and which backends consume them
2. Backend-specific outputs (systemd.network modules for NixOS, .network/.netdev files for Debian)
3. Generic outputs (k3s CLI flags for both, backend-agnostic test runners)
4. The parity message: define once in Nix → produce backend-specific outputs → converge at tests

**README first section (user-revised text, 2026-03-01)**: The heading and first two
paragraphs were manually revised by the user — do not overwrite. Key changes:
- Heading: "Develop K3s Clusters on Custom Hardware with BYO BSP + OS"
- Inline links to `./backends`, `./backends/debian`, `./backends/nixos`
- Specific tool links: kas, ISAR, NixOS

### Key Files
- `lib/network/mk-network-config.nix` - Unified NixOS module generator
- `lib/k3s/mk-k3s-flags.nix` - Shared K3s flag generator
- `tests/lib/mk-k3s-cluster-test.nix` - Parameterized test builder
- `secrets/.sops.yaml` - SOPS configuration with public keys

## References
- [tests/README.md](tests/README.md) - Testing framework
- [docs/SECRETS-SETUP.md](docs/SECRETS-SETUP.md) - Secrets management
- [docs/ISAR-L4-TEST-ARCHITECTURE.md](docs/ISAR-L4-TEST-ARCHITECTURE.md) - ISAR L4 cluster test design
- [docs/binfmt-requirements.md](docs/binfmt-requirements.md) - Cross-architecture binfmt_misc requirements
- [docs/nix-binary-cache-architecture-decision.md](docs/nix-binary-cache-architecture-decision.md) - Binary cache ADR
- ALWAYS ask before adding packages to ISAR images
